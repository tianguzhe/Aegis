import AegisCore
import Foundation

/// Read-only insights derived from the unlocked vault: per-item history and password health.
extension VaultSession {
    /// Authenticated history of one item, newest first. Never writes to the store.
    func history(for itemID: UUID) async throws -> [VaultHistoryEntry] {
        guard phase == .unlocked, let store else { throw VaultError.locked }
        let token = generation
        let stored = try await store.localRevisions()
        let history = try await crypto.itemHistory(for: itemID, in: stored.revisions)
        guard token == generation, phase == .unlocked else { throw VaultError.locked }
        touch()
        return history
    }

    /// Restores the visible fields of an older revision as a new revision on top of every current head.
    /// History is preserved; restoring also resolves any open conflict for the item.
    @discardableResult
    func restoreHistory(_ version: VaultHistoryEntry) async -> Bool {
        guard phase == .unlocked, unreadableRevisionCount == 0 else {
            error = L10n.text("error.damagedData"); return false
        }
        let heads = entries.filter { $0.item.id == version.item.id }
        guard let current = heads.first else {
            error = L10n.text("editor.itemUnavailable"); return false
        }
        var restored = version.item
        // Restoring content must not move the item in or out of the trash, archive, or favorites.
        restored.deletedAt = current.item.deletedAt
        restored.isFavorite = current.item.isFavorite
        restored.isArchived = current.item.isArchived
        restored.permanentlyDeletedAt = nil
        guard await save(restored, parents: heads.map(\.id)) else { return false }
        showNotice(L10n.text("history.restored"))
        return true
    }

    /// Offline audit of active logins; computed from decrypted entries already in memory.
    var passwordHealth: PasswordHealth.Report {
        PasswordHealth.analyze(entries)
    }
}
