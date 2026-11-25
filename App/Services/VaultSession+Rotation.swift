import AegisCore
import Foundation

/// Master password change with full key rotation (Docs/KEY_ROTATION_DESIGN.md).
extension VaultSession {
    // MARK: - Master password change (Docs/KEY_ROTATION_DESIGN.md §3)

    /// Re-encrypts the retained history with new vault credentials and replaces the store atomically.
    ///
    /// Open editors and retained drafts block the change: they are sealed with the old key and
    /// reference item IDs that the rotation remaps. On success `recoveryKey` holds the new recovery
    /// key, which is also persisted (encrypted under the new key) before the commit, so an
    /// interruption after the commit still asks for confirmation on the next unlock.
    /// - Returns: true once the rotated vault is stored, even if re-enabling biometrics failed.
    @discardableResult
    func changeMasterPassword(current: String, new: String, compactHistory: Bool) async -> Bool {
        guard phase == .unlocked, let store, let localState, let header, !isBusy, !isUpdatingBiometrics,
              pendingItemIDs.isEmpty else { return false }
        guard draftSnapshots.isEmpty, recoverableDrafts.isEmpty else {
            error = L10n.text("rotation.error.unsavedDrafts"); return false
        }
        isBusy = true
        lanSyncSuspended = true
        stopLANSync()
        defer {
            replacingVault = false
            isBusy = false
            lanSyncSuspended = false
            reconcileLANSync()
        }
        let token = generation
        var stateMovedToNewVault = false
        let rotation: VaultRotation
        do {
            let verifier = VaultCrypto()
            do { try await verifier.unlock(password: current, header: header); await verifier.lock() }
            catch { await verifier.lock(); throw error }
            let snapshot = try await store.snapshot()
            var oldKey = try await crypto.deviceKey()
            defer { oldKey.resetBytes(in: 0 ..< oldKey.count) }
            guard token == generation, snapshot.header == header else { throw BackupFlowError.sessionChanged }
            rotation = try await VaultRotation.prepare(header: snapshot.header, revisions: snapshot.revisions,
                                                       vaultKey: oldKey, newPassword: new, compactHistory: compactHistory)
            guard token == generation, phase == .unlocked else { throw BackupFlowError.sessionChanged }
            // Persist the new recovery key before the commit, mirroring create().
            try localState.unlock(key: rotation.vaultKey, vaultID: rotation.header.vaultID)
            stateMovedToNewVault = true
            var pending = LocalVaultState()
            pending.pendingRecoveryKey = rotation.recoveryKey
            try localState.write(pending)
            replacingVault = true
            refreshID = UUID()
            try invalidateAutoFillSnapshot()
            // Rejects the swap if anything was saved after the snapshot.
            try await store.replaceVault(expected: snapshot, header: rotation.header, revisions: rotation.revisions)
        } catch {
            replacingVault = false
            if token == generation, phase == .unlocked {
                scheduleTrashCleanup()
                scheduleAutoFillSnapshot()
            }
            if stateMovedToNewVault, token == generation {
                do {
                    var key = try await crypto.deviceKey()
                    defer { key.resetBytes(in: 0 ..< key.count) }
                    try localState.unlock(key: key, vaultID: header.vaultID)
                } catch { localState.lock() }
            }
            self.error = error.localizedDescription
            return false
        }

        // The store now only holds the rotated vault; the old identity must not be used again.
        self.header = rotation.header
        UserDefaults.standard.removeObject(forKey: "lanSync.\(header.vaultID)")
        lanSyncEnabled = false
        lanSyncSnapshotDamaged = false
        let wasBiometric = biometricEnabled
        // Cleanup is after the database commit. Keep all warnings even if the app locks here.
        var warnings: [String] = []
        defer {
            if !warnings.isEmpty {
                self.error = warnings.joined(separator: "\n")
            }
        }
        do { try DeviceKeyStore.delete(vaultID: header.vaultID) }
        catch { warnings.append(L10n.format("rotation.biometricCleanupFailed", error.localizedDescription)) }
        UserDefaults.standard.removeObject(forKey: "biometry.\(header.vaultID)")
        biometricEnabled = false
        do { try localState.discard(vaultID: header.vaultID) } catch { warnings.append(error.localizedDescription) }
        // Locked while committing: the next unlock uses the new password and shows the recovery key.
        guard token == generation, phase == .unlocked else { return true }
        do {
            try await crypto.unlock(deviceKey: rotation.vaultKey, header: rotation.header)
            guard token == generation, phase == .unlocked else { return true }
            replacingVault = false
            recoveryKey = rotation.recoveryKey; recoveryAcknowledged = false
            if wasBiometric {
                do {
                    try DeviceKeyStore.save(rotation.vaultKey, vaultID: rotation.header.vaultID)
                    biometricEnabled = true
                    UserDefaults.standard.set(true, forKey: "biometry.\(rotation.header.vaultID)")
                } catch { warnings.append(L10n.format("rotation.biometricFailed", error.localizedDescription)) }
            }
            try await refresh(); touch()
            showNotice(L10n.text("notice.passwordChanged"))
        } catch {
            // Never stay unlocked with a key that may not match the stored vault.
            lock()
            warnings.append(L10n.format("rotation.finishedWithIssue", error.localizedDescription))
        }
        return true
    }
}
