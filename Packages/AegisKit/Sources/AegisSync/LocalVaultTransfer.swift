import AegisCore
import Foundation
@preconcurrency import Network
import Observation

/// Explicit, foreground-only transfer of one encrypted snapshot. Never opens a database or a keychain.
@MainActor @Observable
public final class LocalVaultTransfer {
    public enum State: Equatable { case idle, starting, searching, offering, transferring, received, sent, failed }
    public struct Peer: Identifiable {
        public let id: String
        public let name: String
        fileprivate let endpoint: NWEndpoint
    }

    public private(set) var state: State = .idle
    public private(set) var peers: [Peer] = []
    public private(set) var offerName = ""
    public private(set) var pairingCode = ""
    public private(set) var receivedData: Data?
    public private(set) var error: String?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var active: LocalTransferConnection?
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var offeredData: Data?
    @ObservationIgnored private var failedAttempts = 0

    public init() {}

    private static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    public func search() {
        stop()
        let token = generation
        let browser = NWBrowser(for: .bonjour(type: LocalTransferProtocol.serviceType, domain: "local."), using: Self.parameters())
        self.browser = browser
        state = .searching
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if case .failed(let error) = state { self.fail(error) }
                if case .waiting(let error) = state { self.fail(error) }
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

    public func offer(_ data: Data, code: String) throws {
        stop()
        pairingCode = try LocalTransferProtocol.normalizeCode(code)
        _ = try LocalTransferProtocol.lengthBytes(data.count)
        let listener = try NWListener(using: Self.parameters())
        self.listener = listener
        offeredData = data
        offerName = "Aegis-" + UUID().uuidString.prefix(8)
        listener.service = NWListener.Service(name: offerName, type: LocalTransferProtocol.serviceType)
        let token = generation
        state = .starting
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                switch state {
                case .ready: self.state = .offering
                case .failed(let error), .waiting(let error): self.fail(error)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == token, self.active == nil else { connection.cancel(); return }
                self.serve(connection, token: token)
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(LocalTransferProtocol.offerLifetime)) } catch { return }
            guard let self, self.generation == token else { return }
            self.fail(LocalTransferError.expired)
        }
    }

    private func serve(_ connection: NWConnection, token: UUID) {
        guard let data = offeredData else { connection.cancel(); return }
        let code = pairingCode
        let socket = LocalTransferConnection(connection)
        active = socket
        state = .transferring
        transferTask = Task { [weak self] in
            let deadline = Self.deadline(socket, seconds: 60)
            defer { deadline.cancel(); socket.cancel() }
            do {
                try await socket.start()
                let challenge = try SecureRandom.bytes(count: LocalTransferProtocol.challengeLength)
                try await socket.send(LocalTransferProtocol.magic + challenge)
                let proof = try await socket.read(LocalTransferProtocol.proofLength)
                guard try LocalTransferProtocol.verify(proof, code: code, challenge: challenge) else {
                    throw LocalTransferError.authenticationFailed
                }
                try Task.checkCancellation()
                try await socket.send(LocalTransferProtocol.magic + LocalTransferProtocol.lengthBytes(data.count))
                try await socket.send(data)
                let receipt = try await socket.read(LocalTransferProtocol.proofLength)
                guard try LocalTransferProtocol.verify(receipt, code: code, challenge: challenge, receivedFile: data) else {
                    throw LocalTransferError.authenticationFailed
                }
                guard let self, self.generation == token else { return }
                self.stop(); self.state = .sent
            } catch {
                guard let self, self.generation == token else { return }
                self.active = nil; self.transferTask = nil
                self.failedAttempts += 1
                if self.failedAttempts >= 3 { self.fail(LocalTransferError.authenticationFailed) }
                else { self.state = .offering }
            }
        }
    }

    public func receive(from peer: Peer, code input: String) throws {
        let code = try LocalTransferProtocol.normalizeCode(input)
        stop()
        pairingCode = code
        let token = generation
        let socket = LocalTransferConnection(NWConnection(to: peer.endpoint, using: Self.parameters()))
        active = socket
        state = .transferring
        transferTask = Task { [weak self] in
            let deadline = Self.deadline(socket, seconds: 60)
            defer { deadline.cancel(); socket.cancel() }
            do {
                try await socket.start()
                guard try await socket.read(8) == LocalTransferProtocol.magic else { throw LocalTransferError.invalidMessage }
                let challenge = try await socket.read(LocalTransferProtocol.challengeLength)
                try await socket.send(LocalTransferProtocol.proof(code: code, challenge: challenge))
                guard try await socket.read(8) == LocalTransferProtocol.magic else { throw LocalTransferError.connectionLost }
                let count = try await LocalTransferProtocol.fileLength(socket.read(4))
                let data = try await socket.read(count)
                _ = try BackupContainer.parse(data)
                try await socket.send(LocalTransferProtocol.proof(code: code, challenge: challenge, receivedFile: data))
                guard let self, self.generation == token else { return }
                self.active = nil; self.transferTask = nil
                self.receivedData = data; self.state = .received
            } catch {
                guard let self, self.generation == token else { return }
                self.fail(LocalTransferError.connectionLost)
            }
        }
    }

    public func discardReceivedBytes() { receivedData = nil; pairingCode = "" }

    public func stop() {
        generation = UUID()
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        active?.cancel(); active = nil
        transferTask?.cancel(); transferTask = nil
        expiryTask?.cancel(); expiryTask = nil
        offeredData = nil; receivedData = nil; pairingCode = ""; offerName = ""
        peers = []; failedAttempts = 0; error = nil; state = .idle
    }

    private func fail(_ error: Error) {
        stop()
        self.error = error.localizedDescription
        state = .failed
    }

    private static func deadline(_ socket: LocalTransferConnection, seconds: Int) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            socket.cancel()
        }
    }
}

/// One ordered read and write at a time, with bounded chunks and cancellation of pending I/O.
@MainActor
private final class LocalTransferConnection {
    private let connection: NWConnection
    private var ready: CheckedContinuation<Void, Error>?

    init(_ connection: NWConnection) { self.connection = connection }
    func cancel() { connection.cancel() }

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
                        case .failed(let error): self.ready = nil; pending.resume(throwing: error)
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
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: { connection.cancel() }
    }

    func read(_ count: Int) async throws -> Data {
        guard count > 0, count <= BackupLimits.maxFileLength else { throw LocalTransferError.invalidMessage }
        let connection = connection
        return try await withTaskCancellationHandler {
            var data = Data()
            while data.count < count {
                try Task.checkCancellation()
                let remaining = min(count - data.count, 65_536)
                let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { bytes, _, _, error in
                        if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                        else { continuation.resume(throwing: error.map { $0 as Error } ?? LocalTransferError.connectionLost) }
                    }
                }
                data.append(chunk)
            }
            return data
        } onCancel: { connection.cancel() }
    }
}
