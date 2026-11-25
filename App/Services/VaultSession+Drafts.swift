import AegisCore
import Foundation

/// Encrypted local state: unsaved drafts and the pending recovery key.
extension VaultSession {
    func unlockLocalState(header: VaultHeader) async throws {
        let token = generation
        var key = try await crypto.deviceKey()
        defer { key.resetBytes(in: 0 ..< key.count) }
        guard token == generation else { throw VaultError.locked }
        try localState?.unlock(key: key, vaultID: header.vaultID)
        recoverableDrafts = localState?.state.drafts ?? []
        recoveryKey = localState?.state.pendingRecoveryKey
        recoveryAcknowledged = false
    }

    func retainDraft(_ draft: VaultDraft) {
        guard phase == .unlocked, !permanentlyDeletedItemIDs.contains(draft.id), let localState else { return }
        do {
            var updated = localState.state
            updated.retain(draft)
            try localState.write(updated)
            recoverableDrafts = updated.drafts
        } catch { self.error = error.localizedDescription }
    }

    func observeDraft(_ id: UUID, snapshot: @escaping () -> VaultDraft) {
        draftSnapshots[id] = snapshot
    }

    func stopObservingDraft(_ id: UUID) {
        draftSnapshots.removeValue(forKey: id)
    }

    func discardDraft(_ id: UUID) {
        guard phase == .unlocked, let localState else { return }
        do {
            var updated = localState.state
            updated.drafts.removeAll { $0.id == id }
            try localState.write(updated)
            recoverableDrafts = updated.drafts
        } catch { self.error = error.localizedDescription }
    }

    func confirmRecovery() {
        guard recoveryAcknowledged, let localState else { return }
        do {
            var updated = localState.state
            updated.pendingRecoveryKey = nil
            try localState.write(updated)
            recoveryKey = nil
            touch()
        } catch { self.error = error.localizedDescription }
    }
}
