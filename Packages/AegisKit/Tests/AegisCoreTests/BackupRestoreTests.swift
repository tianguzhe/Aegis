import AegisCore
@testable import AegisStorage
import Foundation
import Testing

/// Export snapshots and transactional restore (Docs/BACKUP_FORMAT_DESIGN_V1.md §9, §10.3, §14.3–§14.4).
@Suite(.serialized) struct BackupRestoreTests {
    private static let master = "a unique master passphrase 2026"

    private struct Source {
        let crypto: VaultCrypto
        let store: VaultStore
        let header: VaultHeader
        let revisions: [EncryptedRevision]
    }

    private static func makeSource() async throws -> Source {
        let crypto = VaultCrypto(), store = try VaultStore.make(inMemory: true)
        let created = try await crypto.create(password: master)
        try await store.saveHeader(created.header)
        let first = try await crypto.encrypt(VaultItem(title: "Bank", username: "alice", password: "one"), parents: [])
        var edited = try await crypto.decrypt(first); edited.password = "two"
        let second = try await crypto.encrypt(edited, parents: [first.id])
        let note = try await crypto.encrypt(VaultItem(kind: .note, title: "Note"), parents: [])
        for revision in [first, second, note] { try await store.saveRevision(revision) }
        return Source(crypto: crypto, store: store, header: created.header, revisions: [first, second, note])
    }

    private static func exportFile(from source: Source) async throws -> Data {
        let snapshot = try await source.store.snapshot()
        let payload = try BackupPayload(exportedAtMillis: 1_793_923_200_000, incompleteHistory: snapshot.hasIncompleteHistory,
                                        vaultKey: try await source.crypto.deviceKey(), header: snapshot.header,
                                        revisions: snapshot.revisions)
        return try BackupCryptor.seal(payload, backupPassword: nil, includeVaultSlot: true)
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aegis-restore-\(UUID().uuidString)")
    }

    @Test func exportedFileRestoresIntoAFreshStoreThatSurvivesReopening() async throws {
        let source = try await Self.makeSource()
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("backup.aegis")
        try await Self.exportFile(from: source).write(to: fileURL)

        let opened = try BackupCryptor.open(try BackupContainer.parse(Data(contentsOf: fileURL)), credential: Self.master)
        _ = try await BackupValidator.validate(opened.payload)
        let storeDirectory = directory.appendingPathComponent("store")
        let result = try await VaultStore.make(directory: storeDirectory)
            .restore(header: opened.payload.header, revisions: opened.payload.revisions)
        #expect(result == RestoreResult(createdHeader: true, insertedRevisions: 3))

        // A new container on the same files sees the committed restore.
        let reopened = try VaultStore.make(directory: storeDirectory)
        #expect(try await reopened.header() == source.header)
        #expect(Set(try await reopened.revisions().map(\.id)) == Set(source.revisions.map(\.id)))
        #expect(try await reopened.pendingObjects().count == 4)
        let crypto = VaultCrypto()
        try await crypto.unlock(password: Self.master, header: try #require(try await reopened.header()))
        let entries = try await crypto.entries(from: try await reopened.revisions())
        #expect(Set(entries.map(\.item.title)) == ["Bank", "Note"])
        #expect(entries.first { $0.item.title == "Bank" }?.item.password == "two")
    }

    @Test func restoreIsIdempotentAndKeepsNewerLocalRevisions() async throws {
        let source = try await Self.makeSource()
        let target = try VaultStore.make(inMemory: true)
        #expect(try await target.restore(header: source.header, revisions: [source.revisions[0]])
                == RestoreResult(createdHeader: true, insertedRevisions: 1))
        let newer = try await source.crypto.encrypt(VaultItem(title: "Only local"), parents: [])
        try await target.saveRevision(newer)

        #expect(try await target.restore(header: source.header, revisions: source.revisions)
                == RestoreResult(createdHeader: false, insertedRevisions: 2))
        #expect(try await target.restore(header: source.header, revisions: source.revisions)
                == RestoreResult(createdHeader: false, insertedRevisions: 0))
        #expect(Set(try await target.revisions().map(\.id)) == Set((source.revisions + [newer]).map(\.id)))
    }

    @Test func restoreRejectsAnotherVaultWithoutWriting() async throws {
        let source = try await Self.makeSource()
        let other = try await VaultCrypto().create(password: Self.master)
        let target = try VaultStore.make(inMemory: true)
        try await target.saveHeader(other.header)
        await #expect(throws: VaultError.differentVault) {
            try await target.restore(header: source.header, revisions: source.revisions)
        }
        #expect(try await target.header() == other.header)
        #expect(try await target.revisions().isEmpty)
    }

    @Test func conflictingOrForeignRevisionsRejectTheWholeRestore() async throws {
        let source = try await Self.makeSource()
        let target = try VaultStore.make(inMemory: true)
        try await target.restore(header: source.header, revisions: [source.revisions[0]])
        let stored = source.revisions[0]
        let conflicting = EncryptedRevision(vaultID: stored.vaultID, itemID: stored.itemID, id: stored.id,
                                            parents: stored.parents, ciphertext: Data(repeating: 1, count: 40))
        await #expect(throws: VaultError.damagedData) {
            try await target.restore(header: source.header, revisions: [source.revisions[2], conflicting])
        }
        let foreign = EncryptedRevision(vaultID: UUID(), itemID: UUID(), id: UUID(), parents: [], ciphertext: Data(count: 40))
        await #expect(throws: VaultError.damagedData) {
            try await target.restore(header: source.header, revisions: [source.revisions[2], foreign])
        }
        #expect(try await target.revisions().map(\.id) == [stored.id])
    }

    @Test func failedCommitLeavesNothingAndCanBeRetried() async throws {
        struct InjectedCommitFailure: Error {}
        let source = try await Self.makeSource()
        let target = try VaultStore.make(inMemory: true)
        await #expect(throws: InjectedCommitFailure.self) {
            try await target.restore(header: source.header, revisions: source.revisions, beforeSave: { throw InjectedCommitFailure() })
        }
        try await target.setMetadata("probe", data: Data([1]))
        #expect(try await target.header() == nil)
        #expect(try await target.pendingObjects().isEmpty)
        #expect(try await target.restore(header: source.header, revisions: source.revisions)
                == RestoreResult(createdHeader: true, insertedRevisions: 3))
    }

    @Test func snapshotReportsIncompleteHistory() async throws {
        let empty = try VaultStore.make(inMemory: true)
        await #expect(throws: VaultError.locked) { try await empty.snapshot() }

        let source = try await Self.makeSource()
        let complete = try await source.store.snapshot()
        #expect(complete.header == source.header)
        #expect(complete.revisions.count == 3)
        #expect(!complete.hasIncompleteHistory)
        // A child synced before its parent leaves the local history open.
        let orphan = try await source.crypto.encrypt(VaultItem(title: "Orphan"), parents: [UUID()])
        try await source.store.saveRevision(orphan)
        #expect(try await source.store.snapshot().hasIncompleteHistory)
    }
}
