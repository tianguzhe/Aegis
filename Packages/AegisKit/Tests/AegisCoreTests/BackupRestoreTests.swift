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
        for revision in [first, second, note] {
            try await store.saveRevision(revision)
        }
        return Source(crypto: crypto, store: store, header: created.header, revisions: [first, second, note])
    }

    private static func exportFile(from source: Source) async throws -> Data {
        let snapshot = try await source.store.snapshot()
        let payload = try await BackupPayload(exportedAtMillis: 1_793_923_200_000, vaultKey: source.crypto.deviceKey(), header: snapshot.header,
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

        let opened = try BackupCryptor.open(BackupContainer.parse(Data(contentsOf: fileURL)), credential: Self.master)
        _ = try await BackupValidator.validate(opened.payload)
        let storeDirectory = directory.appendingPathComponent("store")
        let result = try await VaultStore.make(directory: storeDirectory)
            .restore(header: opened.payload.header, revisions: opened.payload.revisions)
        #expect(result == RestoreResult(createdHeader: true, insertedRevisions: 3))

        // A new container on the same files sees the committed restore.
        let reopened = try VaultStore.make(directory: storeDirectory)
        #expect(try await reopened.header() == source.header)
        #expect(try await Set(reopened.revisions().map(\.id)) == Set(source.revisions.map(\.id)))
        let crypto = VaultCrypto()
        try await crypto.unlock(password: Self.master, header: #require(try await reopened.header()))
        let entries = try await crypto.entries(from: reopened.revisions())
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
        #expect(try await Set(target.revisions().map(\.id)) == Set((source.revisions + [newer]).map(\.id)))
    }

    @Test func selectedMergeAuthenticatesTheUnionAndCommitsAgainstTheCheckedSnapshot() async throws {
        let source = try await Self.makeSource()
        let target = try VaultStore.make(inMemory: true)
        let (parent, child, unrelated) = (source.revisions[0], source.revisions[1], source.revisions[2])
        try await target.restoreNewVault(header: source.header, revisions: [parent])
        let before = try await target.snapshot()
        let additions = try await source.crypto.validateBackupMerge(local: before.revisions, selected: [child, parent])
        #expect(additions == [child])
        try await target.saveRevision(unrelated)
        await #expect(throws: VaultError.vaultChanged) {
            try await target.appendSyncedRevisions(additions, expected: before)
        }
        let fresh = try await target.snapshot()
        #expect(Set(fresh.revisions.map(\.id)) == [parent.id, unrelated.id])
        let retry = try await source.crypto.validateBackupMerge(local: fresh.revisions, selected: [child, parent])
        #expect(try await target.appendSyncedRevisions(retry, expected: fresh).insertedRevisions == 1)
        let complete = try await target.snapshot()
        #expect(try await source.crypto.validateBackupMerge(local: complete.revisions, selected: source.revisions).isEmpty)
    }

    @Test func selectedMergeRejectsMissingParentsAndChangedCiphertext() async throws {
        let source = try await Self.makeSource()
        let parent = source.revisions[0], child = source.revisions[1]
        await #expect(throws: VaultError.damagedData) {
            try await source.crypto.validateBackupMerge(local: [], selected: [child])
        }
        let sameItem = try await source.crypto.decrypt(parent)
        let differentCiphertext = try await source.crypto.encrypt(sameItem, parents: [], revisionID: parent.id)
        await #expect(throws: VaultError.damagedData) {
            try await source.crypto.validateBackupMerge(local: [parent], selected: [differentCiphertext, child])
        }
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

    @Test func anotherDevicesBackupMigratesWithoutReplacingLocalDataOrCredentials() async throws {
        let source = try await Self.makeSource()
        let opened = try await BackupCryptor.open(BackupContainer.parse(Self.exportFile(from: source)), credential: Self.master)
        let crypto = VaultCrypto(), target = try VaultStore.make(inMemory: true)
        let password = "destination master password"
        let local = try await crypto.create(password: password)
        try await target.saveHeader(local.header)
        // Even a matching source item ID must not merge with an unrelated local item.
        let localItem = VaultItem(id: source.revisions[0].itemID, title: "Only local", password: "local secret")
        let localRevision = try await crypto.encrypt(localItem, parents: [])
        try await target.saveRevision(localRevision)
        let key = try await crypto.deviceKey()
        let migrated = try await BackupMigration.revisions(from: opened.payload, to: local.header, key: key,
                                                           existing: target.revisions())
        // Preparing the preview has no storage side effects.
        #expect(try await target.revisions() == [localRevision])
        #expect(migrated.allSatisfy { $0.vaultID == local.header.vaultID })
        #expect(Set(migrated.map(\.itemID)).isDisjoint(with: source.revisions.map(\.itemID)))
        #expect(try await target.restore(header: local.header, revisions: migrated).insertedRevisions == 3)
        #expect(try await target.header() == local.header)

        await crypto.lock()
        try await crypto.unlock(password: password, header: local.header)
        let entries = try await crypto.entries(from: target.revisions())
        #expect(Set(entries.map(\.item.title)) == ["Only local", "Bank", "Note"])
        #expect(entries.first { $0.item.title == "Only local" }?.item == localItem)
        #expect(entries.first { $0.item.title == "Bank" }?.item.password == "two")
        // The original master password cannot unlock the destination.
        await #expect(throws: VaultError.invalidPassword) {
            try await VaultCrypto().unlock(password: Self.master, header: local.header)
        }

        let bank = try #require(entries.first { $0.item.title == "Bank" })
        var edited = bank.item; edited.password = "edited on destination"
        let newer = try await crypto.encrypt(edited, parents: [bank.id])
        try await target.saveRevision(newer)
        let repeated = try await BackupMigration.revisions(from: opened.payload, to: local.header, key: key,
                                                           existing: target.revisions())
        #expect(repeated == migrated)
        #expect(try await target.restore(header: local.header, revisions: repeated).insertedRevisions == 0)
        let afterRepeat = try await crypto.entries(from: target.revisions())
        #expect(afterRepeat.count == 3)
        #expect(afterRepeat.first { $0.item.title == "Bank" }?.item.password == "edited on destination")
    }

    @Test func migrationPreservesConflictsTrashAndDeletionMarkers() async throws {
        let source = try await Self.makeSource()
        let original = try await source.crypto.decrypt(source.revisions[0])
        var branch = original; branch.password = "offline branch"
        let conflict = try await source.crypto.encrypt(branch, parents: [source.revisions[0].id])
        var trash = VaultItem(title: "Trash"); trash.deletedAt = Date()
        let trashed = try await source.crypto.encrypt(trash, parents: [])
        var deletedNote = try await source.crypto.decrypt(source.revisions[2])
        deletedNote.permanentlyDeletedAt = Date()
        let deletion = try await source.crypto.encrypt(deletedNote, parents: [source.revisions[2].id])
        let payload = try await BackupPayload(exportedAtMillis: 0, vaultKey: source.crypto.deviceKey(), header: source.header,
                                              revisions: source.revisions + [conflict, trashed, deletion])
        let targetCrypto = VaultCrypto()
        let local = try await targetCrypto.create(password: Self.master)
        let migrated = try await BackupMigration.revisions(from: payload, to: local.header,
                                                           key: targetCrypto.deviceKey(), existing: [])
        let entries = try await targetCrypto.entries(from: migrated)
        #expect(entries.filter { $0.item.title == "Bank" }.count == 2)
        #expect(entries.filter { $0.item.title == "Bank" }.allSatisfy { $0.isConflict })
        #expect(entries.first { $0.item.title == "Trash" }?.item.deletedAt == trash.deletedAt)
        #expect(!entries.contains { $0.item.title == "Note" })
        let migratedPayload = try await BackupPayload(exportedAtMillis: 0, vaultKey: targetCrypto.deviceKey(),
                                                      header: local.header, revisions: migrated)
        #expect(try await BackupValidator.validate(migratedPayload).count == 3)
    }

    @Test func migrationRejectsTamperedSourceAndConflictingDestination() async throws {
        let source = try await Self.makeSource()
        let payload = try await BackupPayload(exportedAtMillis: 0, vaultKey: source.crypto.deviceKey(), header: source.header, revisions: source.revisions)
        let crypto = VaultCrypto()
        let local = try await crypto.create(password: Self.master)
        let key = try await crypto.deviceKey()
        let migrated = try await BackupMigration.revisions(from: payload, to: local.header, key: key, existing: [])
        let stored = migrated[0]
        var changed = try await crypto.decrypt(stored); changed.password = "conflicting content"
        let conflicting = try await crypto.encrypt(changed, parents: stored.parents, revisionID: stored.id)
        await #expect(throws: VaultError.damagedData) {
            try await BackupMigration.revisions(from: payload, to: local.header, key: key, existing: [conflicting])
        }
        var damaged = source.revisions
        let first = damaged.removeFirst()
        var ciphertext = first.ciphertext; ciphertext[ciphertext.startIndex] ^= 1
        damaged.append(EncryptedRevision(vaultID: first.vaultID, itemID: first.itemID, id: first.id,
                                         parents: first.parents, ciphertext: ciphertext))
        let invalid = try BackupPayload(exportedAtMillis: 0, vaultKey: payload.vaultKey,
                                        header: source.header, revisions: damaged)
        await #expect(throws: BackupError.invalidContent) {
            try await BackupMigration.revisions(from: invalid, to: local.header, key: key, existing: [])
        }
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
        #expect(try await target.header() == nil)
        // An unrelated later save must not commit the rolled-back revision inserts.
        try await target.saveHeader(source.header)
        #expect(try await target.revisions().isEmpty)
        #expect(try await target.restore(header: source.header, revisions: source.revisions)
            == RestoreResult(createdHeader: false, insertedRevisions: 3))
    }

    @Test func snapshotReadsTheHeaderWithEveryRevision() async throws {
        let empty = try VaultStore.make(inMemory: true)
        await #expect(throws: VaultError.locked) { try await empty.snapshot() }

        let source = try await Self.makeSource()
        let complete = try await source.store.snapshot()
        #expect(complete.header == source.header)
        #expect(complete.revisions.count == 3)
    }
}
