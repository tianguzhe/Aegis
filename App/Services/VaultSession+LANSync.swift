import AegisCore
import AegisStorage
import Foundation

/// Foreground LAN synchronization: starts, validates and commits peer exchanges.
extension VaultSession {
    // MARK: - Foreground LAN synchronization

    func setLANSyncEnabled(_ enabled: Bool) {
        guard phase == .unlocked, let header else { return }
        UserDefaults.standard.set(enabled, forKey: "lanSync.\(header.vaultID)")
        lanSyncEnabled = enabled
        reconcileLANSync()
        touch()
    }

    func setLANSyncForeground(_ foreground: Bool) {
        lanSyncForeground = foreground
        reconcileLANSync()
    }

    func stopLANSync() {
        lanSyncToken = nil
        lanSyncStart?.cancel(); lanSyncStart = nil
        lanSyncCommit?.cancel()
        lanSync.stop()
    }

    func reconcileLANSync() {
        guard lanSyncEnabled, lanSyncForeground, !lanSyncSuspended, phase == .unlocked,
              !lanSyncBlockedByDamage, let header, let store
        else {
            if lanSyncToken != nil {
                stopLANSync()
            }
            return
        }
        guard lanSyncToken == nil else { return }
        let token = UUID()
        lanSyncToken = token
        lanSyncStart = Task { [weak self] in
            guard let self else { return }
            do {
                let key = try await crypto.lanSyncKey(vaultID: header.vaultID)
                try checkLANSync(token, header: header)
                try lanSync.start(key: key, snapshot: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await lanSnapshot(store: store, header: header, token: token)
                }, apply: { [weak self] snapshot, incoming in
                    guard let self else { throw CancellationError() }
                    try await applyLANSync(store: store, snapshot: snapshot, incoming: incoming, token: token)
                })
            } catch is CancellationError {
                return
            } catch {
                guard lanSyncToken == token else { return }
                stopLANSync()
                self.error = L10n.text("lan.sync.failed")
            }
        }
    }

    func checkLANSync(_ token: UUID, header: VaultHeader) throws {
        try Task.checkCancellation()
        guard lanSyncToken == token, phase == .unlocked, self.header == header, unreadableRevisionCount == 0 else {
            throw CancellationError()
        }
    }

    func lanSnapshot(store: VaultStore, header: VaultHeader, token: UUID) async throws -> VaultSnapshot {
        try checkLANSync(token, header: header)
        do {
            let snapshot = try await store.snapshot()
            guard snapshot.header == header else { throw VaultError.vaultChanged }
            try await crypto.validateLANSyncSnapshot(snapshot.revisions)
            try checkLANSync(token, header: header)
            return snapshot
        } catch is DecodingError, VaultError.damagedData, VaultError.differentVault, VaultError.unsupportedFormat, VaultError.oversizedRecord {
            try checkLANSync(token, header: header)
            // Revoke discovery when the advertised history cannot be authenticated.
            lanSyncSnapshotDamaged = true
            stopLANSync()
            throw VaultError.damagedData
        }
    }

    func applyLANSync(store: VaultStore, snapshot: VaultSnapshot, incoming: [EncryptedRevision], token: UUID) async throws {
        try checkLANSync(token, header: snapshot.header)
        guard !isBusy, pendingItemIDs.isEmpty else { throw VaultError.vaultChanged }
        try await crypto.validateLANSyncUnion(local: snapshot.revisions, incoming: incoming)
        try checkLANSync(token, header: snapshot.header)
        guard !isBusy, pendingItemIDs.isEmpty, lanSyncCommit == nil else { throw VaultError.vaultChanged }
        let commit = Task { try await store.appendSyncedRevisions(incoming, expected: snapshot) }
        lanSyncCommit = commit
        let result: RestoreResult
        do {
            result = try await withTaskCancellationHandler { try await commit.value } onCancel: { commit.cancel() }
        } catch {
            lanSyncCommit = nil
            throw error
        }
        lanSyncCommit = nil
        guard lanSyncToken == token, result.insertedRevisions > 0 else { return }
        // The transaction already committed. A projection error must not report a failed import.
        do { try await refresh() }
        catch {
            if lanSyncToken == token {
                self.error = L10n.text("lan.sync.refreshFailed")
            }
        }
    }
}
