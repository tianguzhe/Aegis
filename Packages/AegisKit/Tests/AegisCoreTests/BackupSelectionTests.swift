import AegisCore
import AegisStorage
import Foundation
import Testing

@Suite(.serialized) struct BackupSelectionTests {
    private let master = "selection test master password"

    @Test func subsetKeepsWholeHistoryAndConflictsWithoutWritingOtherItems() async throws {
        let crypto = VaultCrypto(), target = try VaultStore.make(inMemory: true)
        let created = try await crypto.create(password: master)
        let first = try await crypto.encrypt(VaultItem(title: "Selected", username: "alice"), parents: [])
        var changed = try await crypto.decrypt(first); changed.password = "new value"
        let edited = try await crypto.encrypt(changed, parents: [first.id])
        changed.password = "concurrent value"
        let conflict = try await crypto.encrypt(changed, parents: [first.id])
        let skipped = try await crypto.encrypt(VaultItem(kind: .note, title: "Not selected", notes: "private note"), parents: [])
        let revisions = [first, edited, conflict, skipped]
        let payload = try await BackupPayload(exportedAtMillis: 0, incompleteHistory: false,
                                              vaultKey: crypto.deviceKey(), header: created.header, revisions: revisions)
        let plan = try await BackupImportPlan(revisions: revisions, entries: BackupValidator.validate(payload),
                                              existingRevisionIDs: [first.id])
        #expect(plan.items.count == 2)
        #expect(plan.items.first { $0.id == first.itemID }?.isConflict == true)
        let selection: Set<UUID> = [first.itemID]
        let selected = try plan.selectedRevisions(for: selection)
        #expect(Set(selected.map(\.id)) == [first.id, edited.id, conflict.id])
        #expect(plan.summary(for: selection).revisionCount == 3)
        #expect(plan.summary(for: selection).newRevisionCount == 2)
        try await target.restoreNewVault(header: created.header, revisions: selected)
        #expect(try await target.header() == created.header)
        #expect(try await !Set(target.revisions().map(\.itemID)).contains(skipped.itemID))
        let entries = try await crypto.entries(from: target.revisions())
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.isConflict && $0.item.title == "Selected" })
        #expect(try await target.restore(header: created.header, revisions: selected).insertedRevisions == 0)
        // Importing the previously skipped item later works and leaves selected history intact.
        try await target.restore(header: created.header, revisions: plan.selectedRevisions(for: [skipped.itemID]))
        #expect(try await target.revisions().count == 4)
    }

    @Test func selectionPreservesTrashAndDoesNotResurrectPermanentDeletions() async throws {
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: master)
        var trashItem = VaultItem(title: "In trash"); trashItem.deletedAt = Date()
        let trash = try await crypto.encrypt(trashItem, parents: [])
        let alive = try await crypto.encrypt(VaultItem(title: "Was deleted"), parents: [])
        let marker = try await crypto.encrypt(TrashPolicy.deletionMarker(for: crypto.decrypt(alive)), parents: [alive.id])
        let other = try await crypto.encrypt(VaultItem(title: "Keep local"), parents: [])
        let revisions = [trash, alive, marker, other]
        let plan = try await BackupImportPlan(revisions: revisions, entries: crypto.entries(from: revisions))
        #expect(plan.items.first { $0.id == trash.itemID }?.isTrashed == true)
        #expect(plan.items.first { $0.id == alive.itemID }?.isPermanentlyDeleted == true)
        let target = try VaultStore.make(inMemory: true)
        try await target.restore(header: created.header, revisions: [alive, other])
        let selected = try plan.selectedRevisions(for: [alive.itemID, trash.itemID])
        #expect(Set(selected.map(\.id)) == [trash.id, alive.id, marker.id])
        try await target.restore(header: created.header, revisions: selected)
        let entries = try await crypto.entries(from: target.revisions())
        #expect(Set(entries.map(\.item.title)) == ["In trash", "Keep local"])
    }

    @Test func crossVaultSelectionUsesDestinationIDsAndKeepsLocalItems() async throws {
        let source = VaultCrypto(), destination = VaultCrypto()
        let original = try await source.create(password: master)
        let header = try await destination.create(password: "destination selection password").header
        let a = try await source.encrypt(VaultItem(title: "Selected"), parents: [])
        let b = try await source.encrypt(VaultItem(title: "Skipped"), parents: [])
        let payload = try await BackupPayload(exportedAtMillis: 0, incompleteHistory: false,
                                              vaultKey: source.deviceKey(), header: original.header, revisions: [a, b])
        let local = try await destination.encrypt(VaultItem(title: "Existing"), parents: [])
        let migrated = try await BackupMigration.revisions(from: payload, to: header, key: destination.deviceKey(), existing: [local])
        let plan = try await BackupImportPlan(revisions: migrated, entries: destination.entries(from: migrated))
        let id = try #require(plan.items.first { $0.title == "Selected" }?.id)
        #expect(id != a.itemID)
        let target = try VaultStore.make(inMemory: true)
        try await target.restore(header: header, revisions: [local])
        try await target.restore(header: header, revisions: plan.selectedRevisions(for: [id]))
        #expect(try await Set(destination.entries(from: target.revisions()).map(\.item.title)) == ["Existing", "Selected"])
    }

    @Test func invalidOrEmptySelectionIsRejectedButEmptyVaultCanBeJoined() async throws {
        let crypto = VaultCrypto()
        _ = try await crypto.create(password: master)
        let revision = try await crypto.encrypt(VaultItem(title: "One"), parents: [])
        let plan = try await BackupImportPlan(revisions: [revision], entries: crypto.entries(from: [revision]))
        #expect(!plan.canImport([]))
        #expect(!plan.canImport([UUID()]))
        #expect(throws: BackupSelectionError.noSelection) { try plan.selectedRevisions(for: []) }
        #expect(throws: BackupSelectionError.invalidSelection) { try plan.selectedRevisions(for: [UUID()]) }
        let empty = BackupImportPlan(revisions: [], entries: [])
        #expect(empty.canImport([]))
        #expect(try empty.selectedRevisions(for: []).isEmpty)
    }
}
