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

    /// Coalesces per-keystroke editor updates: each write re-seals the whole local state file on the
    /// main actor. Lock flushes the pending draft, and any direct retain or discard of the same item
    /// supersedes it, so a stale pending write can neither overwrite nor resurrect a draft.
    func retainDraftSoon(_ draft: VaultDraft) {
        if let pending = pendingDraft, pending.draft.id != draft.id {
            flushPendingDraft()
        }
        pendingDraft?.task.cancel()
        let token = generation
        let task = Task { [weak self] in
            do { try await Task.sleep(for: Self.draftWriteDelay) } catch { return }
            guard let self, generation == token else { return }
            flushPendingDraft()
        }
        pendingDraft = (draft, task)
    }

    static let draftWriteDelay: Duration = .milliseconds(400)

    func flushPendingDraft() {
        guard let pending = pendingDraft else { return }
        pendingDraft = nil
        pending.task.cancel()
        retainDraft(pending.draft)
    }

    private func dropPendingDraft(for id: UUID) {
        guard let pending = pendingDraft, pending.draft.id == id else { return }
        pendingDraft = nil
        pending.task.cancel()
    }

    func retainDraft(_ draft: VaultDraft) {
        dropPendingDraft(for: draft.id)
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
        dropPendingDraft(for: id)
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
