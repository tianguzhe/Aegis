import AegisCore
@testable import AegisStorage
import Foundation
import Testing

/// Master password change with vault key rotation (Docs/KEY_ROTATION_DESIGN.md).
@Suite(.serialized) struct KeyRotationTests {
    private static let oldPassword = "the original master passphrase"
    private static let newPassword = "a brand new master passphrase"

    private struct Source {
        let store: VaultStore
        let header: VaultHeader
        let recoveryKey: String
        let vaultKey: Data
        let revisions: [EncryptedRevision]
        let deletedItemID: UUID
    }

    /// History with an edit, a trashed item, a terminal deletion and an unresolved conflict.
    private static func makeSource(store: VaultStore? = nil) async throws -> Source {
        let crypto = VaultCrypto(), store = try store ?? VaultStore.make(inMemory: true)
        let created = try await crypto.create(password: oldPassword)
        try await store.saveHeader(created.header)
        let login = try await crypto.encrypt(VaultItem(title: "Bank", username: "alice", password: "one"), parents: [])
        var edited = try await crypto.decrypt(login); edited.password = "two"
        let edit = try await crypto.encrypt(edited, parents: [login.id])
        var trashedItem = VaultItem(kind: .note, title: "Old note"); trashedItem.deletedAt = Date()
        let trashed = try await crypto.encrypt(trashedItem, parents: [])
        let doomedItem = VaultItem(title: "Deleted", password: "gone")
        let doomed = try await crypto.encrypt(doomedItem, parents: [])
        let marker = try await crypto.encrypt(TrashPolicy.deletionMarker(for: doomedItem), parents: [doomed.id])
        let base = try await crypto.encrypt(VaultItem(title: "Shared", password: "base"), parents: [])
        var left = try await crypto.decrypt(base); left.password = "left"
        var right = try await crypto.decrypt(base); right.password = "right"
        let branchA = try await crypto.encrypt(left, parents: [base.id])
        let branchB = try await crypto.encrypt(right, parents: [base.id])
        let revisions = [login, edit, trashed, doomed, marker, base, branchA, branchB]
        for revision in revisions {
            try await store.saveRevision(revision)
        }
        return try await Source(store: store, header: created.header, recoveryKey: created.recoveryKey,
                                vaultKey: crypto.deviceKey(), revisions: revisions, deletedItemID: doomedItem.id)
    }

    private static func rotate(_ source: Source, to password: String = newPassword) async throws -> VaultRotation {
        try await VaultRotation.prepare(header: source.header, revisions: source.revisions, incompleteHistory: false,
                                        vaultKey: source.vaultKey, newPassword: password)
    }

    /// Item contents with IDs removed, since rotation maps every ID into the new vault's namespace.
    private static func contents(_ entries: [VaultEntry]) throws -> [String] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try entries.map { entry in
            var item = entry.item; item.id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
            return try "\(entry.isConflict)|" + String(decoding: encoder.encode(item), as: UTF8.self)
        }.sorted()
    }

    @Test func rotatedVaultOpensOnlyWithNewCredentials() async throws {
        let source = try await Self.makeSource()
        let rotation = try await Self.rotate(source)

        #expect(rotation.header.vaultID != source.header.vaultID)
        #expect(rotation.vaultKey != source.vaultKey)
        #expect(rotation.recoveryKey != source.recoveryKey)
        #expect(rotation.revisions.allSatisfy { $0.vaultID == rotation.header.vaultID })
        #expect(Set(rotation.revisions.map(\.id)).isDisjoint(with: source.revisions.map(\.id)))

        try await VaultCrypto().unlock(password: Self.newPassword, header: rotation.header)
        try await VaultCrypto().recover(recoveryKey: rotation.recoveryKey, header: rotation.header)
        await #expect(throws: VaultError.invalidPassword) {
            try await VaultCrypto().unlock(password: Self.oldPassword, header: rotation.header)
        }
        await #expect(throws: VaultError.invalidPassword) {
            try await VaultCrypto().recover(recoveryKey: source.recoveryKey, header: rotation.header)
        }
        // A device that only kept the old vault key cannot read anything written by the rotation.
        let stale = VaultCrypto()
        try await stale.unlock(deviceKey: source.vaultKey, header: rotation.header)
        for revision in rotation.revisions {
            await #expect(throws: VaultError.damagedData) { try await stale.decrypt(revision) }
        }
    }

    @Test func historyConflictsAndDeletionsSurviveRotation() async throws {
        let source = try await Self.makeSource()
        let rotation = try await Self.rotate(source)
        let before = VaultCrypto(), after = VaultCrypto()
        try await before.unlock(deviceKey: source.vaultKey, header: source.header)
        try await after.unlock(password: Self.newPassword, header: rotation.header)
        let oldEntries = try await before.entries(from: source.revisions)
        let newEntries = try await after.entries(from: rotation.revisions)

        #expect(rotation.revisions.filter { $0.id != rotation.header.vaultID }.count == source.revisions.count)
        #expect(try Self.contents(newEntries) == Self.contents(oldEntries))
        #expect(newEntries.filter(\.isConflict).count == 2)
        #expect(newEntries.contains { $0.item.title == "Old note" && $0.item.deletedAt != nil })
        #expect(!newEntries.contains { $0.item.title == "Deleted" })
        #expect(newEntries.first { $0.item.title == "Bank" }?.item.password == "two")
    }

    @Test func keepingTheSameMasterPasswordStillRotatesTheKey() async throws {
        let source = try await Self.makeSource()
        let rotation = try await Self.rotate(source, to: Self.oldPassword)
        #expect(rotation.header.salt != source.header.salt)
        #expect(rotation.vaultKey != source.vaultKey)
        try await VaultCrypto().unlock(password: Self.oldPassword, header: rotation.header)
    }

    @Test func compactionPreservesVisibleStateAndCarriesItsImportBoundaryInBackups() async throws {
        let source = try await Self.makeSource()
        let oldBackup = try BackupPayload(exportedAtMillis: 0, incompleteHistory: false, vaultKey: source.vaultKey,
                                          header: source.header, revisions: source.revisions)
        let compacted = try await VaultRotation.prepare(header: source.header, revisions: source.revisions,
                                                        incompleteHistory: false, vaultKey: source.vaultKey,
                                                        newPassword: Self.newPassword, compactHistory: true)
        let backup = try BackupPayload(exportedAtMillis: 0, incompleteHistory: false, vaultKey: compacted.vaultKey,
                                       header: compacted.header, revisions: compacted.revisions)
        let reopened = try BackupPayload.decode(backup.encoded())
        let visible = try await BackupValidator.validate(reopened)
        let original = try await BackupValidator.validate(oldBackup)
        #expect(try Self.contents(visible) == Self.contents(original))
        #expect(compacted.revisions.count < source.revisions.count)
        #expect(compacted.revisions.allSatisfy { $0.parents.isEmpty })

        let plan = BackupImportPlan(revisions: reopened.revisions, entries: visible)
        let login = try #require(visible.first { $0.item.title == "Bank" })
        let selected = try plan.selectedRevisions(for: [login.item.id])
        #expect(!plan.itemIDs.contains(compacted.header.vaultID))
        #expect(selected.contains { $0.id == compacted.header.vaultID })
        await #expect(throws: VaultError.retiredVaultHistory) {
            try await BackupMigration.revisions(from: oldBackup, to: reopened.header, key: reopened.vaultKey, existing: selected)
        }

        let crypto = VaultCrypto()
        try await crypto.unlock(deviceKey: compacted.vaultKey, header: compacted.header)
        var retainedItems: [VaultItem] = []
        for revision in compacted.revisions {
            try await retainedItems.append(crypto.decrypt(revision))
        }
        let marker = try #require(retainedItems.first { $0.permanentlyDeletedAt != nil && $0.id != compacted.header.vaultID })
        let lateBranch = try await crypto.encrypt(VaultItem(id: marker.id, title: "Stale restore"), parents: [])
        #expect(try await crypto.entries(from: compacted.revisions + [lateBranch]).allSatisfy { $0.item.id != marker.id })
    }

    @Test func ancestorBackupsFollowAllRotationsAndRespectCompaction() async throws {
        let source = try await Self.makeSource()
        let first = try await Self.rotate(source)
        let second = try await VaultRotation.prepare(header: first.header, revisions: first.revisions, incompleteHistory: false,
                                                     vaultKey: first.vaultKey, newPassword: Self.newPassword)
        let target = try VaultStore.make(inMemory: true)
        try await target.restoreNewVault(header: second.header, revisions: second.revisions)
        let crypto = VaultCrypto()
        try await crypto.unlock(deviceKey: second.vaultKey, header: second.header)
        let current = try #require(try await crypto.entries(from: second.revisions).first { $0.item.title == "Bank" })
        var edited = current.item; edited.password = "after two rotations"
        try await target.saveRevision(crypto.encrypt(edited, parents: [current.id]))
        let before = try await target.snapshot()
        let oldest = try BackupPayload(exportedAtMillis: 0, incompleteHistory: false, vaultKey: source.vaultKey,
                                       header: source.header, revisions: source.revisions.filter { $0.id != source.revisions[4].id })
        let middle = try BackupPayload(exportedAtMillis: 0, incompleteHistory: false, vaultKey: first.vaultKey,
                                       header: first.header, revisions: first.revisions)
        for backup in [oldest, middle] {
            let migrated = try await BackupMigration.revisions(from: backup, to: second.header, key: second.vaultKey,
                                                               existing: before.revisions)
            #expect(try await target.restore(header: second.header, revisions: migrated).insertedRevisions == 0)
        }
        let after = try await crypto.entries(from: target.revisions())
        #expect(after.first { $0.item.title == "Bank" }?.item.password == "after two rotations")
        #expect(after.filter { $0.item.title == "Bank" }.count == 1)
        #expect(!after.contains { $0.item.title == "Deleted" })

        let compacted = try await VaultRotation.prepare(header: second.header, revisions: before.revisions, incompleteHistory: false,
                                                        vaultKey: second.vaultKey, newPassword: Self.newPassword, compactHistory: true)
        let latest = try await VaultRotation.prepare(header: compacted.header, revisions: compacted.revisions, incompleteHistory: false,
                                                     vaultKey: compacted.vaultKey, newPassword: Self.newPassword)
        for backup in [oldest, middle] {
            await #expect(throws: VaultError.retiredVaultHistory) {
                try await BackupMigration.revisions(from: backup, to: latest.header, key: latest.vaultKey, existing: latest.revisions)
            }
        }
        let postCompaction = try BackupPayload(exportedAtMillis: 0, incompleteHistory: false, vaultKey: compacted.vaultKey,
                                               header: compacted.header, revisions: compacted.revisions)
        let migrated = try await BackupMigration.revisions(from: postCompaction, to: latest.header, key: latest.vaultKey,
                                                           existing: latest.revisions)
        #expect(Set(migrated.map(\.id)).isSubset(of: Set(latest.revisions.map(\.id))))
    }

    @Test func weakNewPasswordIsRejected() async throws {
        let source = try await Self.makeSource()
        await #expect(throws: VaultError.weakMasterPassword) { try await Self.rotate(source, to: "short") }
    }

    @Test func replaceVaultSwapsTheStoreAndSurvivesReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-rotation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.makeSource(store: VaultStore.make(directory: directory))
        let snapshot = try await source.store.snapshot()
        let rotation = try await Self.rotate(source)

        try await source.store.replaceVault(expected: snapshot, header: rotation.header, revisions: rotation.revisions)

        let reopened = try VaultStore.make(directory: directory)
        #expect(try await reopened.header() == rotation.header)
        #expect(try await Set(reopened.revisions().map(\.id)) == Set(rotation.revisions.map(\.id)))
        // Saving afterwards accepts only the rotated vault.
        let crypto = VaultCrypto()
        try await crypto.unlock(password: Self.newPassword, header: rotation.header)
        try await reopened.saveRevision(crypto.encrypt(VaultItem(title: "After"), parents: []))
        #expect(try await reopened.revisions().count == rotation.revisions.count + 1)
    }

    @Test func replaceVaultRejectsAStoreThatChangedAfterTheSnapshot() async throws {
        let source = try await Self.makeSource()
        let snapshot = try await source.store.snapshot()
        let rotation = try await Self.rotate(source)
        let crypto = VaultCrypto()
        try await crypto.unlock(deviceKey: source.vaultKey, header: source.header)
        let late = try await crypto.encrypt(VaultItem(title: "Saved meanwhile"), parents: [])
        try await source.store.saveRevision(late)

        await #expect(throws: VaultError.vaultChanged) {
            try await source.store.replaceVault(expected: snapshot, header: rotation.header, revisions: rotation.revisions)
        }
        #expect(try await source.store.header() == source.header)
        #expect(try await Set(source.store.revisions().map(\.id)) == Set((source.revisions + [late]).map(\.id)))
    }

    @Test func failedReplaceWritesNothingAndCanBeRetried() async throws {
        struct InjectedCommitFailure: Error {}
        let source = try await Self.makeSource()
        let snapshot = try await source.store.snapshot()
        let rotation = try await Self.rotate(source)

        await #expect(throws: InjectedCommitFailure.self) {
            try await source.store.replaceVault(expected: snapshot, header: rotation.header, revisions: rotation.revisions,
                                                beforeSave: { throw InjectedCommitFailure() })
        }
        #expect(try await source.store.header() == source.header)
        #expect(try await Set(source.store.revisions().map(\.id)) == Set(source.revisions.map(\.id)))

        try await source.store.replaceVault(expected: snapshot, header: rotation.header, revisions: rotation.revisions)
        #expect(try await source.store.header() == rotation.header)
    }

    @Test func importingABackupFromBeforeTheRotationAddsNothing() async throws {
        let source = try await Self.makeSource()
        let snapshot = try await source.store.snapshot()
        let rotation = try await Self.rotate(source)
        try await source.store.replaceVault(expected: snapshot, header: rotation.header, revisions: rotation.revisions)

        let oldBackup = try BackupPayload(exportedAtMillis: 1_793_923_200_000, incompleteHistory: false,
                                          vaultKey: source.vaultKey, header: source.header, revisions: source.revisions)
        let migrated = try await BackupMigration.revisions(from: oldBackup, to: rotation.header, key: rotation.vaultKey,
                                                           existing: source.store.revisions())
        let result = try await source.store.restore(header: rotation.header, revisions: migrated)
        #expect(result == RestoreResult(createdHeader: false, insertedRevisions: 0))
    }
}
