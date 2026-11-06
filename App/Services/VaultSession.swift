import AegisCore
import AegisStorage
import AegisSync
import Foundation
import LocalAuthentication
import Observation

@MainActor @Observable
final class VaultSession {
    enum Phase { case loading, setup, locked, unlocked }
    var phase: Phase = .loading
    var entries: [VaultEntry] = []
    let presentationStack = VaultPresentationStack()
    var error: String?
    var isBusy = false
    var recoveryKey: String?
    var recoveryAcknowledged = false
    var syncStatus: SyncStatus = .disabled
    var header: VaultHeader?
    var biometricEnabled = false
    var storageAvailable = true
    var recoverableDrafts: [VaultDraft] = []
    var passwordOptions = PasswordPreferences.load() {
        didSet { PasswordPreferences.save(passwordOptions) }
    }
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let crypto = VaultCrypto()
    @ObservationIgnored private var store: VaultStore?
    @ObservationIgnored private var sync: CloudSync?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var lockingTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var localState: LocalVaultStateStore?
    @ObservationIgnored private var draftSnapshots: [UUID: () -> VaultDraft] = [:]
    /// Session generation in which the user last passed the export check (DEC-4); a lock invalidates it.
    @ObservationIgnored private var exportAuthorization: UUID?

    var cloudConfigured: Bool { !isPreview && Bundle.main.object(forInfoDictionaryKey: "AegisCloudEnabled") as? String == "YES" }
    var cloudContainer: String { Bundle.main.object(forInfoDictionaryKey: "AegisCloudContainer") as? String ?? "" }
    var appGroup: String { Bundle.main.object(forInfoDictionaryKey: "AegisAppGroup") as? String ?? "" }
    private var isPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--preview-vault") ||
        ProcessInfo.processInfo.arguments.contains("--preview-onboarding")
        #else
        false
        #endif
    }
    var syncTitle: String {
        switch syncStatus {
        case .disabled: L10n.text("sync.disabled")
        case .syncing: L10n.text("sync.syncing")
        case .ready: L10n.text("sync.ready")
        case .unavailable: L10n.text("sync.unavailable")
        case .accountChanged: L10n.text("sync.accountChanged")
        case .failed: L10n.text("sync.failed")
        }
    }

    func bootstrap() async {
        guard store == nil else { return }
        do {
            #if DEBUG
            if isPreview {
                store = try VaultStore.make(inMemory: true)
                localState = LocalVaultStateStore(directory: nil)
                if ProcessInfo.processInfo.arguments.contains("--preview-onboarding") {
                    phase = .setup
                    return
                }
                let result = try await crypto.create(password: "Aegis preview fixture only")
                try await store?.saveHeader(result.header)
                try await unlockLocalState(header: result.header)
                for item in PreviewFixtures.items {
                    try await store?.saveRevision(crypto.encrypt(item, parents: []))
                }
                phase = .unlocked
                try await refresh(); touch()
                return
            }
            #endif
            let directory: URL
            if !appGroup.isEmpty {
                guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
                    throw NSError(domain: "Aegis", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("error.appGroup")])
                }
                directory = group.appendingPathComponent("Database", isDirectory: true)
            } else {
                directory = URL.applicationSupportDirectory.appendingPathComponent("Aegis", isDirectory: true)
            }
            store = try VaultStore.make(directory: directory)
            localState = LocalVaultStateStore(directory: directory)
            try await refresh()
            phase = header == nil ? .setup : .locked
            if cloudConfigured { await connectCloud() }
        } catch { storageAvailable = false; phase = .locked; self.error = error.localizedDescription }
    }

    func connectCloud() async {
        guard cloudConfigured, let store else { error = L10n.text("sync.setupRequired"); return }
        if sync == nil {
            sync = CloudSync(containerID: cloudContainer, store: store, update: { [weak self] status in
                await self?.updateSync(status)
            }, changed: { [weak self] in await self?.cloudChanged() })
        }
        await sync?.start()
    }

    private func updateSync(_ status: SyncStatus) {
        syncStatus = status
        if case .accountChanged = status { lock(); error = L10n.text("sync.accountChangedDetail") }
    }

    private func cloudChanged() async {
        do {
            try await refresh()
            if phase == .setup, header != nil { phase = .locked }
        } catch { self.error = error.localizedDescription }
    }

    private func refresh() async throws {
        guard let store else { return }
        header = try await store.header()
        if let header { biometricEnabled = UserDefaults.standard.bool(forKey: "biometry.\(header.vaultID)") }
        if phase == .unlocked {
            let token = generation
            let loaded = try await crypto.entries(from: store.revisions())
            guard token == generation, phase == .unlocked else { return }
            entries = loaded
        }
        try await publishAutoFillSnapshot()
    }

    func create(password: String) async {
        guard !isBusy, let store, phase == .setup else { return }
        isBusy = true; defer { isBusy = false }
        let token = generation
        do {
            await lockingTask?.value
            let result = try await crypto.create(password: password)
            guard token == generation else { await crypto.lock(); return }
            try await unlockLocalState(header: result.header)
            guard token == generation else { localState?.lock(); await crypto.lock(); return }
            guard let localState else { throw VaultError.locked }
            var pending = localState.state
            pending.pendingRecoveryKey = result.recoveryKey
            // Persist recovery setup before committing the header, so interruption is recoverable.
            try localState.write(pending)
            try await store.saveHeader(result.header)
            guard token == generation else { self.header = result.header; phase = .locked; await crypto.lock(); return }
            header = result.header; recoveryKey = result.recoveryKey; recoveryAcknowledged = false
            phase = .unlocked
            try await refresh(); touch()
            scheduleSync()
        } catch {
            phase = header == nil ? .setup : .locked
            entries = []; recoveryKey = nil; recoverableDrafts = []; localState?.lock()
            await crypto.lock(); self.error = error.localizedDescription
        }
    }

    func unlock(password: String, recovery: Bool = false) async {
        guard !isBusy, let header else { return }
        isBusy = true; defer { isBusy = false }
        let token = generation
        do {
            await lockingTask?.value
            if recovery { try await crypto.recover(recoveryKey: password, header: header) }
            else { try await crypto.unlock(password: password, header: header) }
            guard token == generation else { await crypto.lock(); return }
            try await unlockLocalState(header: header)
            guard token == generation else { localState?.lock(); await crypto.lock(); return }
            phase = .unlocked
            try await refresh(); touch()
        } catch { phase = .locked; entries = []; recoveryKey = nil; recoverableDrafts = []; localState?.lock(); await crypto.lock(); self.error = error.localizedDescription }
    }

    func unlockWithBiometrics() async {
        guard !isBusy, let header else { return }
        isBusy = true; defer { isBusy = false }
        let token = generation
        do {
            await lockingTask?.value
            var key = try await Task.detached { try DeviceKeyStore.read(vaultID: header.vaultID) }.value
            defer { key.resetBytes(in: 0..<key.count) }
            guard token == generation else { return }
            try await crypto.unlock(deviceKey: key, header: header)
            guard token == generation else { await crypto.lock(); return }
            try await unlockLocalState(header: header)
            guard token == generation else { localState?.lock(); await crypto.lock(); return }
            phase = .unlocked; try await refresh(); touch()
        } catch { phase = .locked; entries = []; recoveryKey = nil; recoverableDrafts = []; localState?.lock(); await crypto.lock(); self.error = error.localizedDescription }
    }

    func setBiometrics(_ enabled: Bool) async {
        guard let header, phase == .unlocked else { return }
        do {
            if enabled {
                var key = try await crypto.deviceKey()
                defer { key.resetBytes(in: 0..<key.count) }
                try DeviceKeyStore.save(key, vaultID: header.vaultID)
            } else { DeviceKeyStore.delete(vaultID: header.vaultID) }
            biometricEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "biometry.\(header.vaultID)")
        } catch { self.error = error.localizedDescription }
    }

    enum LockReason { case manual, background, idle, system }

    func lock(reason: LockReason = .manual) {
        // Capture the latest bindings even if SwiftUI has not delivered onChange yet.
        for snapshot in draftSnapshots.values { retainDraft(snapshot()) }
        draftSnapshots.removeAll()
        generation = UUID(); entries = []; recoveryKey = nil; recoverableDrafts = []; idleTask?.cancel()
        localState?.lock()
        // iOS already enforces the local-only clipboard expiration while suspended.
        if reason != .background { SecureClipboard.clear() }
        if phase == .unlocked { phase = .locked }
        let crypto = self.crypto
        lockingTask = Task { await crypto.lock() }
    }

    func touch() {
        guard phase == .unlocked else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.lock(reason: .idle)
        }
    }

    @discardableResult
    func save(_ item: VaultItem, parents: [UUID]) async -> Bool {
        guard phase == .unlocked, let store else { return false }
        let token = generation
        do {
            var updated = item; updated.modifiedAt = Date()
            let revision = try await crypto.encrypt(updated, parents: parents)
            guard token == generation else { return false }
            try await store.saveRevision(revision)
            try await refresh(); touch()
            scheduleSync()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func toggleFavorite(_ entry: VaultEntry) async {
        var item = entry.item; item.isFavorite.toggle()
        await save(item, parents: [entry.id])
    }
    func trash(_ entry: VaultEntry) async {
        var item = entry.item; item.deletedAt = Date()
        await save(item, parents: [entry.id])
    }
    func restore(_ entry: VaultEntry) async {
        var item = entry.item; item.deletedAt = nil
        await save(item, parents: [entry.id])
    }
    func resolve(_ entry: VaultEntry) async {
        await save(entry.item, parents: entries.filter { $0.item.id == entry.item.id }.map(\.id))
    }

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

    struct ExportedBackup {
        let data: Data
        let incompleteHistory: Bool
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
        fileprivate let generation: UUID
        var exportedAt: Date { Date(timeIntervalSince1970: Double(payload.exportedAtMillis) / 1000) }
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
        guard token == generation else { return .cancelled }
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
            guard token == generation else { return false }
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
    func exportBackup(backupPassword: String?, includeVaultSlot: Bool) async throws -> ExportedBackup {
        guard let store, phase == .unlocked, !isBusy, exportAuthorization == generation else { throw VaultError.locked }
        isBusy = true; defer { isBusy = false }
        exportAuthorization = nil
        let token = generation
        let snapshot = try await store.snapshot()
        var key = try await crypto.deviceKey()
        defer { key.resetBytes(in: 0..<key.count) }
        guard token == generation, snapshot.header == header else { throw VaultError.locked }
        let payload = try BackupPayload(exportedAtMillis: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
                                        incompleteHistory: snapshot.hasIncompleteHistory, vaultKey: key,
                                        header: snapshot.header, revisions: snapshot.revisions)
        // Do not hand out a structurally valid file containing a damaged record or graph.
        // The container self-check authenticates the envelope; this validates every revision.
        _ = try await BackupValidator.validate(payload)
        let data = try await Task.detached(priority: .userInitiated) {
            try BackupCryptor.seal(payload, backupPassword: backupPassword, includeVaultSlot: includeVaultSlot)
        }.value
        // Locking while sealing cancels the export before any save dialog appears.
        guard token == generation else { throw VaultError.locked }
        touch()
        return ExportedBackup(data: data, incompleteHistory: snapshot.hasIncompleteHistory)
    }

    /// Importing an ABB backup into an existing vault requires it to be unlocked first (DEC-5), so a
    /// backup credential cannot operate on the current vault while it is locked.
    var backupImportBlockedByLock: Bool { header != nil && phase != .unlocked }

    /// Opens and fully validates a backup with the single credential the user typed. Writes nothing.
    func previewBackup(_ container: BackupContainer, credential: String) async -> BackupImportPreview? {
        guard let store, !isBusy else { return nil }
        isBusy = true; defer { isBusy = false }
        let token = generation
        do {
            guard !backupImportBlockedByLock else { throw BackupFlowError.unlockFirst }
            let opened = try await Task.detached(priority: .userInitiated) {
                try BackupCryptor.open(container, credential: credential)
            }.value
            let payload = opened.payload
            let heads = try await BackupValidator.validate(payload)
            if let local = try await store.header() {
                guard local == payload.header else { throw VaultError.differentVault }
                var key = try await crypto.deviceKey()
                defer { key.resetBytes(in: 0..<key.count) }
                guard Self.constantTimeEquals(key, payload.vaultKey) else { throw VaultError.differentVault }
            }
            let localIDs = Set(try await store.revisions().map(\.id))
            guard token == generation else { throw BackupFlowError.sessionChanged }
            let items = Dictionary(grouping: heads, by: \.item.id).values
            let trashed = items.filter { group in group.allSatisfy { $0.item.deletedAt != nil } }.count
            return BackupImportPreview(payload: payload, openedWith: opened.openedWith, itemCount: items.count - trashed,
                                       trashedCount: trashed, conflictCount: items.filter { $0.count > 1 }.count,
                                       newRevisionCount: payload.revisions.filter { !localIDs.contains($0.id) }.count,
                                       generation: token)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Commits a confirmed preview. The store write is one transaction; entering the vault afterwards is
    /// a separate step guarded by `generation`, and its failures do not undo or misreport the restore (§10.3–§10.4).
    func commitBackup(_ preview: BackupImportPreview) async -> Bool {
        guard let store, !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        let token = generation
        let enterVault = phase != .unlocked
        do {
            guard preview.generation == token else { throw BackupFlowError.sessionChanged }
            guard !backupImportBlockedByLock else { throw BackupFlowError.unlockFirst }
            try await store.restore(header: preview.payload.header, revisions: preview.payload.revisions)
        } catch {
            self.error = error.localizedDescription
            return false
        }
        do {
            if enterVault {
                try await guardedRestoreStep(token: token) {
                    try await crypto.unlock(deviceKey: preview.payload.vaultKey, header: preview.payload.header)
                }
                try await guardedRestoreStep(token: token) { try await unlockLocalState(header: preview.payload.header) }
                phase = .unlocked
            }
            try await refresh(); touch()
        } catch {
            if enterVault, phase != .unlocked { entries = []; localState?.lock(); await crypto.lock(); phase = .locked }
            do { header = try await store.header() } catch { self.error = error.localizedDescription }
            if !(error is CancellationError) { self.error = L10n.format("backup.restoredWithIssue", error.localizedDescription) }
        }
        if phase == .setup { phase = .locked }
        scheduleSync()
        return true
    }

    /// Runs one step of entering a restored vault; a lock in between leaves it locked instead.
    private func guardedRestoreStep(token: UUID, _ step: () async throws -> Void) async throws {
        guard token == generation else { throw CancellationError() }
        try await step()
        guard token == generation else { throw CancellationError() }
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func publishAutoFillSnapshot() async throws {
        guard !isPreview, !appGroup.isEmpty, let store, try await store.header() != nil,
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let data = try await store.backup()
        let url = directory.appendingPathComponent("autofill.aegis")
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func scheduleSync() {
        guard let sync else { return }
        syncTask = Task { await sync.synchronize() }
    }

    private func unlockLocalState(header: VaultHeader) async throws {
        let token = generation
        var key = try await crypto.deviceKey()
        defer { key.resetBytes(in: 0..<key.count) }
        guard token == generation else { throw VaultError.locked }
        try localState?.unlock(key: key, vaultID: header.vaultID)
        recoverableDrafts = localState?.state.drafts ?? []
        recoveryKey = localState?.state.pendingRecoveryKey
        recoveryAcknowledged = false
    }

    func retainDraft(_ draft: VaultDraft) {
        guard phase == .unlocked, let localState else { return }
        do {
            var updated = localState.state
            updated.retain(draft)
            try localState.write(updated)
            recoverableDrafts = updated.drafts
        } catch { self.error = error.localizedDescription }
    }

    func observeDraft(_ id: UUID, snapshot: @escaping () -> VaultDraft) { draftSnapshots[id] = snapshot }
    func stopObservingDraft(_ id: UUID) { draftSnapshots.removeValue(forKey: id) }

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
