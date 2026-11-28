import AegisCore
import AegisStorage
import CryptoKit
import Foundation
@preconcurrency import Network
import Observation

/// Runs while the app has an active, unlocked, opted-in vault. The owner must call `stop`
/// before releasing or replacing that session. Keys and callbacks live only until `stop`.
@MainActor @Observable
public final class LANSyncService {
    public enum State: Equatable, Sendable { case idle, waiting, syncing, permissionDenied, failed }
    public private(set) var state: State = .idle
    public private(set) var lastSuccess: Date?

    @ObservationIgnored private var instance = UUID()
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var snapshot: LANSyncRound.Snapshot?
    @ObservationIgnored private var apply: LANSyncRound.Apply?
    // A replayed discovery tag can advertise a peer's ID from another host, so keep every endpoint.
    @ObservationIgnored private var peers: [UUID: [NWEndpoint]] = [:]
    @ObservationIgnored private var endpointFailures: [NWEndpoint: Int] = [:]
    @ObservationIgnored private var nextAttempt: [UUID: (at: ContinuousClock.Instant, failures: Int)] = [:]
    @ObservationIgnored private var changedDuringRound = false
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var transfer: Task<Void, Never>?
    @ObservationIgnored private var active: LocalTransferConnection?
    /// Inbound connections still proving the sync key, oldest first. They do not hold the round slot,
    /// so a host that connects and never authenticates cannot starve legitimate peers.
    @ObservationIgnored private var pendingHandshakes: [(id: ObjectIdentifier, socket: LocalTransferConnection)] = []
    @ObservationIgnored private var blocked = Set<Source>()

    private enum Source: Hashable { case listener, browser }

    public init() {}

    /// Advertises the vault and exchanges authenticated revisions. `snapshot` must read a strictly
    /// authenticated store cut. `apply` receives only non-empty batches and must validate and
    /// transactionally commit them against that cut.
    /// Synchronous listener creation errors propagate. Asynchronous failures appear in `state`.
    public func start(key: SymmetricKey, snapshot: @escaping @Sendable () async throws -> VaultSnapshot,
                      apply: @escaping @Sendable (VaultSnapshot, [EncryptedRevision]) async throws -> Void) throws
    {
        stop()
        let listener = try NWListener(using: LocalVaultTransfer.parameters())
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LANSyncHandshake.serviceType, domain: "local."),
                                using: LocalVaultTransfer.parameters())
        let token = instance
        self.key = key
        self.snapshot = snapshot
        self.apply = apply
        self.listener = listener
        self.browser = browser
        state = .waiting
        let tag = LANSyncHandshake.announcement(instance, key: key).base64EncodedString()
        listener.service = NWListener.Service(name: "Aegis-" + instance.uuidString.prefix(8), type: LANSyncHandshake.serviceType,
                                              txtRecord: NWTXTRecord(["t": tag]))
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, instance == token, blocked.isEmpty else { connection.cancel(); return }
                accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, instance == token else { return }
                switch status {
                case .ready: recovered(.listener)
                case let .waiting(error): waiting(error, source: .listener)
                case let .failed(error): failed(error)
                default: break
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, instance == token else { return }
                switch status {
                case .ready: recovered(.browser)
                case let .waiting(error): waiting(error, source: .browser)
                case let .failed(error): failed(error)
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, instance == token, let key = self.key else { return }
                var found: [UUID: [NWEndpoint]] = [:]
                for result in results {
                    guard case let .bonjour(record) = result.metadata,
                          let text = record.dictionary["t"], let tag = Data(base64Encoded: text),
                          let id = LANSyncHandshake.discover(tag, key: key), token.uuidString < id.uuidString else { continue }
                    found[id, default: []].append(result.endpoint)
                }
                peers = found
                nextAttempt = nextAttempt.filter { found[$0.key] != nil }
                let present = Set(found.values.joined())
                endpointFailures = endpointFailures.filter { present.contains($0.key) }
                requestSync()
            }
        }
        listener.start(queue: .global(qos: .utility))
        browser.start(queue: .global(qos: .utility))
    }

    /// Coalesces foreground changes and resumes periodic reconciliation of discovered peers.
    public func requestSync() {
        guard scheduler == nil, !peers.isEmpty, blocked.isEmpty else { return }
        let token = instance
        scheduler = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                while let self, instance == token, !peers.isEmpty, blocked.isEmpty {
                    dialIfReady()
                    try await Task.sleep(for: .seconds(2))
                }
            } catch is CancellationError {
                return
            } catch {
                self?.state = .failed
            }
            if let self, instance == token {
                scheduler = nil
            }
        }
    }

    /// Advances the next reconciliation after a local save without bypassing failure backoff.
    public func localDataChanged() {
        changedDuringRound = active != nil
        nextAttempt = nextAttempt.filter { $0.value.failures > 0 }
        requestSync()
    }

    /// Cancels discovery, the current round, and any unused keys and callbacks.
    public func stop() {
        instance = UUID()
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        active?.cancel(); active = nil
        transfer?.cancel(); transfer = nil
        cancelPendingHandshakes()
        scheduler?.cancel(); scheduler = nil
        key = nil; snapshot = nil; apply = nil
        peers = [:]; endpointFailures = [:]; nextAttempt = [:]; blocked = []
        changedDuringRound = false
        lastSuccess = nil
        state = .idle
    }

    nonisolated static let maxEndpointFailures = 3
    /// Concurrent unauthenticated inbound handshakes. A new connection evicts the oldest instead of
    /// being refused: refusing would let a host that keeps the pool full block every real peer, while
    /// eviction forces it to keep reconnecting faster than a real handshake completes (tens of ms).
    nonisolated static let maxPendingHandshakes = 4

    /// The endpoint with the fewest consecutive failures, keeping discovery order on ties, so an
    /// endpoint that succeeded stays preferred over replayed ones. Nil once every endpoint is paused.
    nonisolated static func preferredEndpoint<Endpoint: Hashable>(_ endpoints: [Endpoint], failures: [Endpoint: Int]) -> Endpoint? {
        endpoints.filter { failures[$0, default: 0] < maxEndpointFailures }.min { failures[$0, default: 0] < failures[$1, default: 0] }
    }

    private func dialIfReady() {
        guard active == nil else { return }
        let now = ContinuousClock.now
        let eligible = peers.compactMap { id, endpoints -> (id: UUID, endpoint: NWEndpoint)? in
            guard nextAttempt[id].map({ $0.at <= now }) ?? true,
                  let endpoint = Self.preferredEndpoint(endpoints, failures: endpointFailures) else { return nil }
            return (id, endpoint)
        }
        guard let peer = eligible.min(by: { (nextAttempt[$0.id]?.at ?? now - .seconds(1)) < (nextAttempt[$1.id]?.at ?? now - .seconds(1)) }) else { return }
        exchange(NWConnection(to: peer.endpoint, using: LocalVaultTransfer.parameters()), expectedPeer: peer.id, endpoint: peer.endpoint)
    }

    /// Authenticates an inbound connection outside the round slot, which it claims only afterwards.
    private func accept(_ connection: NWConnection) {
        guard let key else { connection.cancel(); return }
        while pendingHandshakes.count >= Self.maxPendingHandshakes {
            pendingHandshakes.removeFirst().socket.cancel()
        }
        let token = instance
        let socket = LocalTransferConnection(connection, maxRead: LANSyncFrames.maxLength)
        let id = ObjectIdentifier(socket)
        pendingHandshakes.append((id, socket))
        Task { [weak self] in
            // `authenticate` bounds the handshake itself; this also bounds a connection that never starts.
            let deadline = Task {
                do { try await Task.sleep(for: LANSyncRound.handshakeTimeout + .seconds(2)) } catch { return }
                socket.cancel()
            }
            defer { deadline.cancel() }
            let round: LANSyncRound
            do {
                try await socket.start()
                round = try await LANSyncRound.authenticate(socket: socket, instance: token, expectedPeer: nil, key: key)
            } catch {
                socket.cancel()
                if let self, instance == token {
                    pendingHandshakes.removeAll { $0.id == id }
                }
                return
            }
            // An evicted connection may still have finished authenticating; only a tracked one may take the slot.
            guard let self, instance == token, pendingHandshakes.contains(where: { $0.id == id }) else {
                socket.cancel(); return
            }
            pendingHandshakes.removeAll { $0.id == id }
            guard active == nil, blocked.isEmpty else { socket.cancel(); return }
            begin(socket, expectedPeer: nil, endpoint: nil) { round }
        }
    }

    private func cancelPendingHandshakes() {
        for pending in pendingHandshakes {
            pending.socket.cancel()
        }
        pendingHandshakes = []
    }

    private func exchange(_ connection: NWConnection, expectedPeer: UUID, endpoint: NWEndpoint) {
        guard let key else { connection.cancel(); return }
        let token = instance
        let socket = LocalTransferConnection(connection, maxRead: LANSyncFrames.maxLength)
        begin(socket, expectedPeer: expectedPeer, endpoint: endpoint) {
            try await socket.start()
            return try await LANSyncRound.authenticate(socket: socket, instance: token, expectedPeer: expectedPeer, key: key)
        }
    }

    /// Runs one round in the single slot. `prepare` returns an authenticated round on `socket`.
    private func begin(_ socket: LocalTransferConnection, expectedPeer: UUID?, endpoint: NWEndpoint?,
                       prepare: @escaping @Sendable () async throws -> LANSyncRound)
    {
        guard let snapshot, let apply else { socket.cancel(); return }
        let token = instance
        active = socket
        state = .syncing
        transfer = Task { [weak self] in
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, instance == token, active === socket else { return }
                transfer?.cancel()
                socket.cancel()
            }
            defer { deadline.cancel(); socket.cancel() }
            do {
                var round = try await prepare()
                try await round.run(snapshot: snapshot, apply: apply)
                guard let self, instance == token else { return }
                lastSuccess = Date()
                finish(expectedPeer, endpoint: endpoint, succeeded: true)
            } catch {
                guard let self, instance == token else { return }
                finish(expectedPeer, endpoint: endpoint, succeeded: false)
            }
        }
    }

    private func finish(_ peer: UUID?, endpoint: NWEndpoint?, succeeded: Bool) {
        active = nil; transfer = nil
        if let peer, let endpoint {
            endpointFailures[endpoint] = succeeded ? 0 : endpointFailures[endpoint, default: 0] + 1
            // Fail over to an untried endpoint at once; otherwise back off.
            let untried = Self.preferredEndpoint(peers[peer] ?? [], failures: endpointFailures)
                .map { endpointFailures[$0, default: 0] == 0 } ?? false
            let delay = succeeded ? (changedDuringRound ? 1 : 15) : (untried ? 1 : 30)
            let failures = succeeded ? 0 : (nextAttempt[peer]?.failures ?? 0) + 1
            nextAttempt[peer] = (at: .now + .seconds(delay), failures: failures)
        }
        changedDuringRound = false
        state = blocked.isEmpty ? (succeeded ? .waiting : .failed) : .permissionDenied
    }

    private func recovered(_ source: Source) {
        blocked.remove(source)
        if blocked.isEmpty, active == nil {
            state = .waiting; requestSync()
        }
    }

    private func waiting(_ error: NWError, source: Source) {
        // DNS-SD's PolicyDenied distinguishes a denied local-network permission from a transient wait.
        if error == .dns(-65570) {
            blocked.insert(source)
            state = .permissionDenied
            active?.cancel(); transfer?.cancel()
            cancelPendingHandshakes()
        }
    }

    private func failed(_ error: NWError) {
        stop()
        state = error == .dns(-65570) ? .permissionDenied : .failed
    }
}
