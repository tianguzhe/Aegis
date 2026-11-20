import AegisCore
import Foundation
@preconcurrency import Network
import Observation

/// Explicit, foreground-only transfer of one encrypted snapshot. Never opens a database or a keychain.
@MainActor @Observable
public final class LocalVaultTransfer {
    public enum State: Equatable { case idle, starting, searching, offering, connecting, comparing, awaitingPeer, transferring, received, sent, failed }
    public struct Peer: Identifiable {
        public let id: String
        public let name: String
        fileprivate let endpoint: NWEndpoint
    }

    public private(set) var state: State = .idle
    public private(set) var peers: [Peer] = []
    public private(set) var offerName = ""
    @ObservationIgnored private var receivedSnapshot: (data: Data, credential: String)?
    public private(set) var error: String?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var active: LocalTransferConnection?
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var interruption: LocalTransferError?
    @ObservationIgnored private var failedAttempts = 0
    public private(set) var comparisonCode = ""
    public private(set) var comparisonID: UUID?
    @ObservationIgnored private var approval: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var pairingExport: (@MainActor (String) async throws -> Data)?

    public init() {}

    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    /// Starts discovery for new-device invitations, discarding any prior round.
    public func search() {
        stop()
        let token = generation
        let browser = NWBrowser(for: .bonjour(type: LANPairingHandshake.serviceType, domain: "local."), using: Self.parameters())
        self.browser = browser
        state = .searching
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if case let .failed(error) = state {
                    self.fail(error)
                }
                if case let .waiting(error) = state {
                    self.fail(error)
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                var found: [String: Peer] = [:]
                for result in results {
                    if case let .service(name, type, domain, _) = result.endpoint {
                        let id = "\(name)|\(type)|\(domain)"
                        found[id] = Peer(id: id, name: name, endpoint: result.endpoint)
                    }
                }
                self.peers = found.values.sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
    }

    /// Starts an invitation. `export` runs with the ABB credential after both peers approve.
    /// Listener setup errors propagate and end the invitation.
    public func offerPairing(export: @escaping @MainActor (String) async throws -> Data) throws {
        stop()
        pairingExport = export
        do { try listen() }
        catch { stop(); throw error }
    }

    private func listen() throws {
        let listener = try NWListener(using: Self.parameters())
        self.listener = listener
        offerName = "Aegis-" + UUID().uuidString.prefix(8)
        listener.service = NWListener.Service(name: offerName, type: LANPairingHandshake.serviceType)
        let token = generation
        state = .starting
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                switch state {
                case .ready:
                    if self.state == .starting {
                        self.state = .offering
                    }
                case let .failed(error), let .waiting(error): self.fail(error)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == token, self.active == nil else { connection.cancel(); return }
                self.runPairing(connection, role: .sender)
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            guard let self, generation == token else { return }
            fail(LocalTransferError.expired)
        }
    }

    /// Connects to a discovered invitation. The caller must compare the displayed number on both devices.
    public func receivePairing(from peer: Peer) {
        stop()
        runPairing(NWConnection(to: peer.endpoint, using: Self.parameters()), role: .receiver)
    }

    /// Accepts only the comparison currently displayed for this connection.
    public func approvePairing(_ id: UUID?) {
        guard let id, id == comparisonID, let pending = approval else { return }
        approval = nil
        state = .awaitingPeer
        pending.resume()
    }

    /// Rejects the displayed comparison and closes the connection without exporting.
    public func rejectPairing(_ id: UUID?) {
        guard let id, id == comparisonID else { return }
        interruptPairing(.comparisonRejected)
    }

    private func interruptPairing(_ reason: LocalTransferError) {
        // Record the local reason before cancellation wakes the concurrent read or approval wait.
        interruption = reason
        active?.cancel()
        transferTask?.cancel()
        let pending = approval
        approval = nil
        pending?.resume(throwing: reason)
    }

    private func runPairing(_ connection: NWConnection, role: LANPairingHandshake.Role) {
        let socket = LocalTransferConnection(connection, maxRead: LANPairingRound.maxFrameLength)
        let token = generation
        let id = UUID()
        active = socket
        interruption = nil
        error = nil
        state = .connecting
        transferTask = Task { [weak self] in
            guard let self else { socket.cancel(); return }
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                guard let self, active === socket else { return }
                interruptPairing(.expired)
            }
            defer { deadline.cancel(); socket.cancel() }
            do {
                try await socket.start()
                var round = try await LANPairingRound.handshake(on: socket, role: role)
                try Task.checkCancellation()
                guard generation == token else { return }
                let code = round.comparisonCode
                try await round.exchangeApproval { [weak self] in
                    guard let self, generation == token else { throw CancellationError() }
                    try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                            approval = pending
                            comparisonID = id
                            comparisonCode = code
                            state = .comparing
                        }
                    } onCancel: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, comparisonID == id, let pending = approval else { return }
                            approval = nil
                            pending.resume(throwing: CancellationError())
                        }
                    }
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                comparisonCode = ""; comparisonID = nil
                state = .transferring
                if role == .sender, let export = pairingExport {
                    try await round.export(using: export)
                    guard generation == token else { return }
                    stop(); state = .sent
                } else if role == .receiver {
                    let (file, credential) = try await round.importSnapshot()
                    guard generation == token else { return }
                    stop()
                    receivedSnapshot = (file, credential)
                    state = .received
                }
            } catch {
                guard generation == token else { return }
                active = nil; transferTask = nil
                comparisonCode = ""; comparisonID = nil
                failedAttempts += 1
                let pairingError = interruption ?? (error as? LocalTransferError) ?? .connectionLost
                if role == .sender, failedAttempts < 3 {
                    self.error = error is CancellationError && interruption == nil ? nil : pairingError.localizedDescription
                    state = .offering
                } else if role == .sender {
                    fail(LocalTransferError.authenticationFailed)
                } else {
                    fail(pairingError)
                }
            }
        }
    }

    /// Hands validated container bytes and their session credential to the caller once for decryption and preview.
    /// Returns nil before receipt, after consumption, or after the transfer stops.
    public func takeReceivedSnapshot() -> (data: Data, credential: String)? {
        defer { receivedSnapshot = nil }
        return receivedSnapshot
    }

    public func stop() {
        generation = UUID()
        let pending = approval
        approval = nil
        pending?.resume(throwing: CancellationError())
        comparisonCode = ""; comparisonID = nil
        pairingExport = nil
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        active?.cancel(); active = nil
        transferTask?.cancel(); transferTask = nil
        expiryTask?.cancel(); expiryTask = nil
        interruption = nil; receivedSnapshot = nil; offerName = ""
        peers = []; failedAttempts = 0; error = nil; state = .idle
    }

    private func fail(_ error: Error) {
        stop()
        self.error = error.localizedDescription
        state = .failed
    }
}

/// One ordered read and write at a time, with bounded chunks and cancellation of pending I/O.
@MainActor
final class LocalTransferConnection: LANSyncSocket {
    private let connection: NWConnection
    private let maxRead: Int
    private var ready: CheckedContinuation<Void, Error>?

    init(_ connection: NWConnection, maxRead: Int = BackupLimits.maxFileLength) {
        self.connection = connection
        self.maxRead = maxRead
    }

    func cancel() {
        connection.cancel()
    }

    func start() async throws {
        let connection = connection
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, let pending = self.ready else { return }
                        switch state {
                        case .ready: self.ready = nil; pending.resume()
                        case let .failed(error): self.ready = nil; pending.resume(throwing: error)
                        case .cancelled: self.ready = nil; pending.resume(throwing: CancellationError())
                        default: break
                        }
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: { connection.cancel() }
    }

    func send(_ data: Data) async throws {
        let connection = connection
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: { connection.cancel() }
    }

    func read(_ count: Int) async throws -> Data {
        guard count > 0, count <= maxRead else { throw LocalTransferError.invalidMessage }
        let connection = connection
        return try await withTaskCancellationHandler {
            var data = Data()
            while data.count < count {
                try Task.checkCancellation()
                let remaining = min(count - data.count, 65536)
                let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { bytes, _, _, error in
                        if let bytes, !bytes.isEmpty {
                            continuation.resume(returning: bytes)
                        } else {
                            continuation.resume(throwing: error.map { $0 as Error } ?? LocalTransferError.connectionLost)
                        }
                    }
                }
                data.append(chunk)
            }
            return data
        } onCancel: { connection.cancel() }
    }
}
