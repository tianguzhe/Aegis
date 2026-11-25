import AegisCore
import AegisStorage
import Foundation
import LocalAuthentication

/// Encrypted ABB backups and password CSV import (Docs/BACKUP_FORMAT_DESIGN_V1.md).
extension VaultSession {
    // MARK: - Encrypted backup (Docs/BACKUP_FORMAT_DESIGN_V1.md §9–§10)

    enum ExportAuthorization { case authorized, cancelled, needsMasterPassword }

    enum BackupFlowError: LocalizedError {
        case unlockFirst, sessionChanged
        var errorDescription: String? {
            switch self {
            case .unlockFirst: L10n.text("backup.error.unlockFirst")
            case .sessionChanged: L10n.text("backup.error.sessionChanged")
            }
        }
    }

    /// Authenticated backup contents awaiting confirmation. Holds the vault key, so it is only valid
    /// in the session generation that produced it; a lock makes `commitBackup` reject it.
    struct BackupImportPreview {
        let payload: BackupPayload
        let openedWith: BackupCredentialKind
        let itemCount: Int
        let trashedCount: Int
        let conflictCount: Int
        let newRevisionCount: Int
        let destinationHeader: VaultHeader
        let revisions: [EncryptedRevision]
        let requiresEmptyVault: Bool
        let selection: BackupImportPlan
        let generation: UUID
        var exportedAt: Date {
            Date(timeIntervalSince1970: Double(payload.exportedAtMillis) / 1000)
        }

        var isCrossVault: Bool {
            destinationHeader.vaultID != payload.header.vaultID
        }
    }

    /// Every export first passes the device-owner check (DEC-4). Devices without a passcode cannot
    /// evaluate it, so the caller falls back to `authorizeExport(masterPassword:)`.
    func authorizeExport() async -> ExportAuthorization {
        guard phase == .unlocked else { return .cancelled }
        let token = generation, context = LAContext()
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else { return .needsMasterPassword }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L10n.text("backup.exportReason"))
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return .cancelled
        } catch {
            self.error = error.localizedDescription
            return .cancelled
        }
        guard token == generation, !Task.isCancelled else { return .cancelled }
        exportAuthorization = token
        return .authorized
    }

    func authorizeExport(masterPassword: String) async -> Bool {
        guard phase == .unlocked, let header, !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        let token = generation, verifier = VaultCrypto()
        do {
            try await verifier.unlock(password: masterPassword, header: header)
            await verifier.lock()
            guard token == generation, !Task.isCancelled else { return false }
            exportAuthorization = token
            return true
        } catch {
            await verifier.lock()
            self.error = error.localizedDescription
            return false
        }
    }

    /// Seals a consistent snapshot into an ABB v1 file. Consumes the export authorization.
    /// Throws `VaultError.locked` when unauthorized or when the vault locks before sealing finishes.
    func exportBackup(backupPassword: String?, includeVaultSlot: Bool) async throws -> Data {
        guard let store, phase == .unlocked, !isBusy, exportAuthorization == generation else { throw VaultError.locked }
        isBusy = true; defer { isBusy = false }
        exportAuthorization = nil
        let token = generation
        let snapshot = try await store.snapshot()
        var key = try await crypto.deviceKey()
        defer { key.resetBytes(in: 0 ..< key.count) }
        guard token == generation, snapshot.header == header else { throw VaultError.locked }
        let payload = try BackupPayload(exportedAtMillis: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
                                        vaultKey: key, header: snapshot.header, revisions: snapshot.revisions)
        // Do not hand out a structurally valid file containing a damaged record or graph.
        // The container self-check authenticates the envelope; this validates every revision.
        _ = try await BackupValidator.validate(payload)
        let data = try await Task.detached(priority: .userInitiated) {
            try BackupCryptor.seal(payload, backupPassword: backupPassword, includeVaultSlot: includeVaultSlot)
        }.value
        // Locking while sealing cancels the export before any save dialog appears.
        guard token == generation else { throw VaultError.locked }
        touch()
        return data
    }

    /// Importing an ABB backup into an existing vault requires it to be unlocked first (DEC-5), so a
    /// backup credential cannot operate on the current vault while it is locked.
    var backupImportBlockedByLock: Bool {
        header != nil && phase != .unlocked
    }

    var backupImportGeneration: UUID {
        generation
    }

    struct PasswordCSVPreview {
        let content: PasswordCSVImport.Preview
        let snapshot: VaultSnapshot
        let generation: UUID
    }

    func previewPasswordCSV(_ load: @escaping @Sendable () throws -> PasswordCSVImport.Parsed) async throws -> PasswordCSVPreview {
        guard phase == .unlocked, let store, !isBusy, pendingItemIDs.isEmpty else { throw BackupFlowError.sessionChanged }
        guard unreadableRevisionCount == 0 else { throw VaultError.damagedData }
        let token = generation
        isBusy = true; defer { isBusy = false }
        let worker = Task.detached(priority: .userInitiated, operation: load)
        let parsed = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard generation == token, phase == .unlocked else { throw CancellationError() }
        let snapshot = try await store.snapshot()
        let entries = try await crypto.cachedEntries(from: snapshot.revisions)
        let preview = try await PasswordCSVImport.prepare(parsed, existing: entries, crypto: crypto)
        try Task.checkCancellation()
        guard generation == token, phase == .unlocked, header == snapshot.header else { throw CancellationError() }
        touch()
        return PasswordCSVPreview(content: preview, snapshot: snapshot, generation: token)
    }

    func commitPasswordCSV(_ preview: PasswordCSVPreview, selectedItemIDs: Set<UUID>) async throws {
        guard phase == .unlocked, let store, !isBusy, pendingItemIDs.isEmpty,
              generation == preview.generation, header == preview.snapshot.header else { throw BackupFlowError.sessionChanged }
        guard unreadableRevisionCount == 0 else { throw VaultError.damagedData }
        let selected = preview.content.candidates.filter { selectedItemIDs.contains($0.id) }.map(\.revision)
        guard !selected.isEmpty, selected.count == selectedItemIDs.count else { throw VaultError.damagedData }
        isBusy = true; defer { isBusy = false }
        try Task.checkCancellation()
        let result = try await store.appendImportedRevisions(selected, expected: preview.snapshot)
        lanSync.localDataChanged()
        // A completed transaction counts even when locking prevents the UI from refreshing.
        guard generation == preview.generation, phase == .unlocked else { return }
        do {
            try await refresh()
            guard generation == preview.generation, phase == .unlocked else { return }
            touch()
            showNotice(L10n.format("csv.imported", Int64(result.insertedRevisions)))
        } catch {
            guard generation == preview.generation, phase == .unlocked else { return }
            self.error = L10n.format("csv.error.refresh", Int64(result.insertedRevisions))
        }
    }

    /// Opens and fully validates a backup with the single credential the user typed. Writes nothing.
    func previewBackup(_ container: BackupContainer, credential: String, requireNewVault: Bool = false) async -> BackupImportPreview? {
        guard let store, !isBusy else { return nil }
        isBusy = true; defer { isBusy = false }
        let token = generation
        let requiresEmptyVault = requireNewVault || phase == .setup
        do {
            if requiresEmptyVault, phase != .setup || header != nil {
                throw BackupFlowError.sessionChanged
            }
            guard !backupImportBlockedByLock else { throw BackupFlowError.unlockFirst }
            let opened = try await Task.detached(priority: .userInitiated) {
                try BackupCryptor.open(container, credential: credential)
            }.value
            let payload = opened.payload
            let heads = try await BackupValidator.validate(payload)
            let localRevisions = try await store.revisions()
            var destinationHeader = payload.header
            var revisions = payload.revisions
            var destinationEntries = heads
            if let local = try await store.header() {
                guard !requiresEmptyVault else { throw BackupFlowError.sessionChanged }
                var key = try await crypto.deviceKey()
                defer { key.resetBytes(in: 0 ..< key.count) }
                if local.vaultID == payload.header.vaultID {
                    guard local == payload.header, Self.constantTimeEquals(key, payload.vaultKey) else {
                        throw VaultError.differentVault
                    }
                } else {
                    revisions = try await BackupMigration.revisions(from: payload, to: local, key: key, existing: localRevisions)
                    destinationEntries = try await crypto.entries(from: revisions)
                }
                destinationHeader = local
            }
            let localIDs = Set(localRevisions.map(\.id))
            guard token == generation else { throw BackupFlowError.sessionChanged }
            let items = Dictionary(grouping: heads, by: \.item.id).values
            let trashed = items.filter { group in group.allSatisfy { $0.item.deletedAt != nil } }.count
            return BackupImportPreview(payload: payload, openedWith: opened.openedWith, itemCount: items.count - trashed,
                                       trashedCount: trashed, conflictCount: items.filter { $0.count > 1 }.count,
                                       newRevisionCount: revisions.filter { !localIDs.contains($0.id) }.count,
                                       destinationHeader: destinationHeader, revisions: revisions,
                                       requiresEmptyVault: requiresEmptyVault,
                                       selection: BackupImportPlan(revisions: revisions, entries: destinationEntries, existingRevisionIDs: localIDs),
                                       generation: token)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Commits a confirmed preview. The store write is one transaction; entering the vault afterwards is
    /// a separate step guarded by `generation`, and its failures do not undo or misreport the restore (§10.3–§10.4).
    func commitBackup(_ preview: BackupImportPreview, selectedItemIDs: Set<UUID>) async -> Bool {
        guard let store, !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        let token = generation
        let enterVault = phase != .unlocked
        do {
            guard preview.generation == token, pendingItemIDs.isEmpty else { throw BackupFlowError.sessionChanged }
            guard !backupImportBlockedByLock else { throw BackupFlowError.unlockFirst }
            let revisions = try preview.selection.selectedRevisions(for: selectedItemIDs)
            if preview.requiresEmptyVault {
                guard phase == .setup, header == nil else { throw BackupFlowError.sessionChanged }
                try await store.restoreNewVault(header: preview.destinationHeader, revisions: revisions)
            } else {
                let snapshot = try await store.snapshot()
                guard snapshot.header == preview.destinationHeader else { throw BackupFlowError.sessionChanged }
                let selected: [EncryptedRevision]
                if preview.payload.header.vaultID == snapshot.header.vaultID {
                    selected = revisions
                } else {
                    var key = try await crypto.deviceKey()
                    defer { key.resetBytes(in: 0 ..< key.count) }
                    // Reuse ciphertext that may have been committed by sync after the preview.
                    let migrated = try await BackupMigration.revisions(from: preview.payload, to: snapshot.header,
                                                                       key: key, existing: snapshot.revisions)
                    selected = migrated.filter { selectedItemIDs.contains($0.itemID) }
                    guard Set(selected.map(\.id)) == Set(revisions.map(\.id)) else { throw BackupFlowError.sessionChanged }
                }
                let additions = try await crypto.validateBackupMerge(local: snapshot.revisions, selected: selected)
                guard token == generation, phase == .unlocked else { throw BackupFlowError.sessionChanged }
                try Task.checkCancellation()
                let result = try await store.appendSyncedRevisions(additions, expected: snapshot)
                if result.insertedRevisions > 0 {
                    // The import may have restored a lost parent. The refresh below restarts sync,
                    // and the snapshot check sets the flag again if the history is still damaged.
                    lanSyncSnapshotDamaged = false
                    lanSync.localDataChanged()
                }
            }
        } catch {
            self.error = error.localizedDescription
            return false
        }
        do {
            if enterVault {
                await lockingTask?.value
                try await guardedRestoreStep(token: token) {
                    try await crypto.unlock(deviceKey: preview.payload.vaultKey, header: preview.payload.header)
                }
                try await guardedRestoreStep(token: token) { try await unlockLocalState(header: preview.payload.header) }
                phase = .unlocked
            }
            try await refresh(); touch()
        } catch {
            if enterVault, phase != .unlocked {
                entries = []; localState?.lock(); await crypto.lock(); phase = .locked
            }
            do { header = try await store.header() } catch { self.error = error.localizedDescription }
            if !(error is CancellationError) {
                self.error = L10n.format("backup.restoredWithIssue", error.localizedDescription)
            }
        }
        if phase == .setup {
            phase = .locked
        }
        return true
    }

    /// Runs one step of entering a restored vault; a lock in between leaves it locked instead.
    func guardedRestoreStep(token: UUID, _ step: () async throws -> Void) async throws {
        guard token == generation else { throw CancellationError() }
        try await step()
        guard token == generation else { throw CancellationError() }
    }

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
