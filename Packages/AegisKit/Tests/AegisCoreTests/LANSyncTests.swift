import AegisCore
@testable import AegisStorage
@testable import AegisSync
import CryptoKit
import Foundation
import Testing

struct LANSyncTests {
    @Test func authenticationBindsBothRolesAndInstances() throws {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let otherKey = SymmetricKey(data: Data(repeating: 8, count: 32))
        let initiator = try LANSyncHandshake(instance: UUID())
        let responder = try LANSyncHandshake(instance: UUID())
        let request = try initiator.exchange(with: responder.hello, initiating: true, key: key)
        let reply = try responder.exchange(with: initiator.hello, initiating: false, key: key)
        #expect(request.proof == reply.expectedProof)
        #expect(reply.proof == request.expectedProof)
        #expect(request.proof != request.expectedProof)
        #expect(request.peer == responder.instance)
        let different = try responder.exchange(with: initiator.hello, initiating: false, key: otherKey)
        #expect(request.proof != different.expectedProof)
        #expect(throws: LANSyncError.invalidMessage) {
            try initiator.exchange(with: responder.hello.dropLast(), initiating: true, key: key)
        }
    }

    @Test func framesRejectReplayTamperingAndReflection() throws {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let initiator = try LANSyncHandshake(instance: UUID())
        let responder = try LANSyncHandshake(instance: UUID())
        var left = try initiator.exchange(with: responder.hello, initiating: true, key: key).frames
        var right = try responder.exchange(with: initiator.hello, initiating: false, key: key).frames
        let original = try left.seal(Data([1, 2, 3]))
        var tampered = original
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        #expect(throws: LANSyncError.invalidMessage) { try left.open(original) }
        #expect(throws: LANSyncError.invalidMessage) { try right.open(tampered) }
        #expect(try right.open(original) == Data([1, 2, 3]))
        #expect(throws: LANSyncError.invalidMessage) { try right.open(original) }
        #expect(throws: LANSyncError.limitExceeded) {
            try left.seal(Data(count: LANSyncFrames.maxLength + 1))
        }
    }

    @Test func discoveryAndContentFingerprintsCoverIdentity() throws {
        let key = SymmetricKey(data: Data(repeating: 9, count: 32))
        let instance = try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        let announcement = LANSyncHandshake.announcement(instance, key: key)
        // Independent Python HMAC-SHA256 vector for the published instance and domain.
        #expect(announcement.map { String(format: "%02x", $0) }.joined() ==
            "00112233445566778899aabbccddeeff3a34cf6c14b2943d012e4620f1e495afd49626024b6f6723c6162fc2413ee877")
        #expect(LANSyncHandshake.discover(announcement, key: key) == instance)
        #expect(LANSyncHandshake.discover(announcement, key: SymmetricKey(size: .bits256)) == nil)
        let id = UUID(), vault = UUID(), item = UUID()
        let a = EncryptedRevision(vaultID: vault, itemID: item, id: id, parents: [], ciphertext: Data(repeating: 1, count: 28))
        let b = EncryptedRevision(vaultID: vault, itemID: item, id: id, parents: [], ciphertext: Data(repeating: 2, count: 28))
        let body = try LANSyncManifest.encode(a)
        #expect(try LANSyncManifest.decode(body, vaultID: vault) == a)
        #expect(try LANSyncManifest.fingerprint(a) != LANSyncManifest.fingerprint(b))
        #expect(throws: LANSyncError.invalidMessage) { try LANSyncManifest.decode(body.dropLast(), vaultID: vault) }
    }

    @Test func unionRejectsMissingParentsDuplicatesAndCrossSnapshotCycles() throws {
        let vault = UUID(), item = UUID(), a = UUID(), b = UUID()
        let first = EncryptedRevision(vaultID: vault, itemID: item, id: a, parents: [b], ciphertext: Data())
        let cyclic = EncryptedRevision(vaultID: vault, itemID: item, id: b, parents: [a], ciphertext: Data())
        let parent = EncryptedRevision(vaultID: vault, itemID: item, id: b, parents: [], ciphertext: Data())
        #expect(throws: VaultError.damagedData) {
            try VaultRevisionValidation.validateSyncUnion(local: [first], incoming: [cyclic])
        }
        #expect(throws: VaultError.damagedData) {
            try VaultRevisionValidation.validateSyncUnion(local: [], incoming: [first])
        }
        #expect(throws: VaultError.damagedData) {
            try VaultRevisionValidation.validateSyncUnion(local: [parent], incoming: [parent])
        }
        #expect(try VaultRevisionValidation.validateSyncUnion(local: [first], incoming: [parent]).count == 2)
    }

    @Test func mergedHistoryMustFitInTheNextRound() throws {
        let vault = UUID(), item = UUID()
        let ciphertext = Data(count: BackupLimits.sealedRevisionLength.upperBound)
        let fittingCount = BackupLimits.maxPayloadLength / (55 + ciphertext.count)
        let revisions = (0 ... fittingCount).map { _ in
            EncryptedRevision(vaultID: vault, itemID: item, id: UUID(), parents: [], ciphertext: ciphertext)
        }
        try LANSyncManifest.checkBudget(Array(revisions.dropLast()))
        #expect(throws: LANSyncError.limitExceeded) { try LANSyncManifest.checkBudget(revisions) }
    }

    @Test func strictSnapshotRejectsDamagedRevisionEvenAfterCaching() async throws {
        let crypto = VaultCrypto()
        _ = try await crypto.create(password: "synthetic LAN test password")
        let valid = try await crypto.encrypt(VaultItem(title: "Local"), parents: [])
        try await crypto.validateLANSyncSnapshot([valid])
        var ciphertext = valid.ciphertext
        ciphertext[ciphertext.index(before: ciphertext.endIndex)] ^= 1
        let damaged = EncryptedRevision(vaultID: valid.vaultID, itemID: valid.itemID, id: valid.id,
                                        parents: valid.parents, ciphertext: ciphertext)
        await #expect(throws: VaultError.damagedData) { try await crypto.validateLANSyncSnapshot([damaged]) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AEGIS_TEST_LOCAL_NETWORK"] == "1"))
    @MainActor func discoversAndExchangesRevisionsInBothDirections() async throws {
        let crypto = VaultCrypto()
        let header = try await crypto.create(password: "synthetic LAN test password").header
        let key = try await crypto.lanSyncKey(vaultID: header.vaultID)
        let left = try VaultStore.make(inMemory: true), right = try VaultStore.make(inMemory: true)
        try await left.saveHeader(header)
        try await right.saveHeader(header)
        let item = VaultItem(title: "Conflicted")
        let root = try await crypto.encrypt(item, parents: [])
        var leftItem = item, rightItem = item
        leftItem.title = "Left edit"
        rightItem.title = "Right edit"
        let a = try await crypto.encrypt(leftItem, parents: [root.id])
        let b = try await crypto.encrypt(rightItem, parents: [root.id])
        try await left.saveRevision(root)
        try await right.saveRevision(root)
        try await left.saveRevision(a)
        try await right.saveRevision(b)
        let leftService = LANSyncService(), rightService = LANSyncService()
        defer { leftService.stop(); rightService.stop() }
        func start(_ service: LANSyncService, store: VaultStore) throws {
            try service.start(key: key, snapshot: {
                let snapshot = try await store.snapshot()
                try await crypto.validateLANSyncSnapshot(snapshot.revisions)
                return snapshot
            }) { snapshot, revisions in
                try await crypto.validateLANSyncUnion(local: snapshot.revisions, incoming: revisions)
                _ = try await store.appendSyncedRevisions(revisions, expected: snapshot)
            }
        }
        func waitForSync() async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while leftService.lastSuccess == nil || rightService.lastSuccess == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(leftService.lastSuccess != nil)
            try #require(rightService.lastSuccess != nil)
        }

        try start(leftService, store: left)
        try start(rightService, store: right)
        try await waitForSync()
        #expect(try await left.revisions().count == 3)
        #expect(try await right.revisions().count == 3)
        let heads = try await crypto.entries(from: left.revisions())
        #expect(Set(heads.map(\.id)) == Set([a.id, b.id]))
        #expect(heads.allSatisfy { $0.isConflict })

        leftService.stop()
        rightService.stop()
        let marker = try await crypto.encrypt(TrashPolicy.deletionMarker(for: item), parents: [a.id, b.id])
        let lateEdit = try await crypto.encrypt(rightItem, parents: [b.id])
        let added = try await crypto.encrypt(VaultItem(title: "Added while offline"), parents: [])
        try await left.saveRevision(marker)
        try await right.saveRevision(lateEdit)
        try await right.saveRevision(added)
        try start(leftService, store: left)
        try start(rightService, store: right)
        try await waitForSync()
        for store in [left, right] {
            let revisions = try await store.revisions()
            #expect(revisions.count == 6)
            #expect(Set(revisions.map(\.id)) == Set([root.id, a.id, b.id, marker.id, lateEdit.id, added.id]))
            #expect(try await crypto.entries(from: revisions).map(\.id) == [added.id])
        }
    }

    @Test func cancelledOrStaleTransactionsPreserveTheStore() async throws {
        let store = try VaultStore.make(inMemory: true), crypto = VaultCrypto()
        let created = try await crypto.create(password: "synthetic LAN test password")
        try await store.saveHeader(created.header)
        let base = try await store.snapshot()
        let local = try await crypto.encrypt(VaultItem(title: "Local"), parents: [])
        let remote = try await crypto.encrypt(VaultItem(title: "Remote"), parents: [])
        await #expect(throws: CancellationError.self) {
            try await store.appendSyncedRevisions([remote], expected: base) { throw CancellationError() }
        }
        #expect(try await store.revisions().isEmpty)
        try await store.saveRevision(local)
        await #expect(throws: VaultError.vaultChanged) {
            try await store.appendSyncedRevisions([remote], expected: base)
        }
        #expect(try await store.revisions() == [local])
    }
}

/// Byte pipe that honors cancellation like `LocalTransferConnection`, so rounds run without Network.
private actor MemorySocket: LANSyncSocket {
    private var buffer = Data()
    private var waiter: (count: Int, continuation: CheckedContinuation<Data, Error>)?
    private var peer: MemorySocket?

    static func pair() async -> (MemorySocket, MemorySocket) {
        let left = MemorySocket(), right = MemorySocket()
        await left.connect(right)
        await right.connect(left)
        return (left, right)
    }

    private func connect(_ socket: MemorySocket) {
        peer = socket
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        await peer?.deliver(data)
    }

    private func deliver(_ data: Data) {
        buffer.append(data)
        fulfill()
    }

    func read(_ count: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = (count, continuation)
                fulfill()
            }
        } onCancel: {
            Task { await self.cancelRead() }
        }
    }

    private func cancelRead() {
        waiter?.continuation.resume(throwing: CancellationError())
        waiter = nil
    }

    private func fulfill() {
        guard let pending = waiter, buffer.count >= pending.count else { return }
        waiter = nil
        let data = Data(buffer.prefix(pending.count))
        buffer.removeFirst(pending.count)
        pending.continuation.resume(returning: data)
    }
}

struct LANSyncRecoveryTests {
    @Test(.timeLimit(.minutes(1)))
    func silentPeerReleasesTheRoundSlotAfterTheHandshakeTimeout() async throws {
        let (socket, _) = await MemorySocket.pair()
        // The structured task group must cancel and drain the pending read before throwing.
        await #expect(throws: LANSyncError.timedOut) {
            _ = try await LANSyncRound.authenticate(socket: socket, instance: UUID(), expectedPeer: nil,
                                                    key: SymmetricKey(size: .bits256), timeout: .milliseconds(100))
        }
    }

    @Test func dialingPrefersTheLeastFailedEndpointAndPausesWhenAllFailed() {
        #expect(LANSyncService.preferredEndpoint(["replayed", "real"], failures: [:]) == "replayed")
        #expect(LANSyncService.preferredEndpoint(["replayed", "real"], failures: ["replayed": 1]) == "real")
        #expect(LANSyncService.preferredEndpoint(["replayed", "real"], failures: ["replayed": 3, "real": 2]) == "real")
        #expect(LANSyncService.preferredEndpoint(["replayed", "real"], failures: ["replayed": 3, "real": 3]) == nil)
    }

    @Test func roundRetriesACommitRacedByALocalSave() async throws {
        let crypto = VaultCrypto()
        let header = try await crypto.create(password: "synthetic LAN test password").header
        let key = try await crypto.lanSyncKey(vaultID: header.vaultID)
        let left = try VaultStore.make(inMemory: true), right = try VaultStore.make(inMemory: true)
        try await left.saveHeader(header)
        try await right.saveHeader(header)
        let remote = try await crypto.encrypt(VaultItem(title: "From peer"), parents: [])
        let racing = try await crypto.encrypt(VaultItem(title: "Saved during the round"), parents: [])
        try await left.saveRevision(remote)

        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let (dialer, listener) = await MemorySocket.pair()
        let raced = Raced()
        func snapshot(_ store: VaultStore) -> LANSyncRound.Snapshot {
            { try await store.snapshot() }
        }
        func apply(_ store: VaultStore, raceOnce: Bool) -> LANSyncRound.Apply {
            { snapshot, incoming in
                if raceOnce, await raced.first() {
                    try await store.saveRevision(racing)
                }
                try await crypto.validateLANSyncUnion(local: snapshot.revisions, incoming: incoming)
                _ = try await store.appendSyncedRevisions(incoming, expected: snapshot)
            }
        }
        async let initiator: Void = {
            var round = try await LANSyncRound.authenticate(socket: dialer, instance: ids[0], expectedPeer: ids[1], key: key)
            try await round.run(snapshot: snapshot(left), apply: apply(left, raceOnce: false))
        }()
        var round = try await LANSyncRound.authenticate(socket: listener, instance: ids[1], expectedPeer: nil, key: key)
        try await round.run(snapshot: snapshot(right), apply: apply(right, raceOnce: true))
        try await initiator
        #expect(try await Set(right.revisions().map(\.id)) == [remote.id, racing.id])
    }
}

private actor Raced {
    private var done = false
    func first() -> Bool {
        defer { done = true }
        return !done
    }
}
