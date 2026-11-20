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
    private(set) var pendingItemIDs: Set<UUID> = []
    private(set) var notice: String?
    private(set) var unreadableRevisionCount = 0
    private(set) var isUpdatingBiometrics = false
    private(set) var lanSyncEnabled = false
    private var lanSyncSnapshotDamaged = false
    var lanSyncBlockedByDamage: Bool {
        unreadableRevisionCount > 0 || lanSyncSnapshotDamaged
    }

    let lanSync = LANSyncService()
    @ObservationIgnored private var lanSyncForeground = false
    @ObservationIgnored private var lanSyncToken: UUID?
    @ObservationIgnored private var lanSyncStart: Task<Void, Never>?
    @ObservationIgnored private var lanSyncCommit: Task<RestoreResult, Error>?
    @ObservationIgnored private var lanSyncSuspended = false
    var recoveryKey: String?
    var recoveryAcknowledged = false
    /// Set while the change-password sheet shows the new recovery key itself, so the root view does
    /// not try to present a second sheet on top of the settings sheet.
    var recoveryPresentedInline = false
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
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var lockingTask: Task<Void, Never>?
    @ObservationIgnored private var trashCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var autoFillTask: Task<Void, Never>?
    @ObservationIgnored private var publishedAutoFill: AutoFillVersion?
    @ObservationIgnored private var replacingVault = false
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var localState: LocalVaultStateStore?
    @ObservationIgnored private var draftSnapshots: [UUID: () -> VaultDraft] = [:]
    @ObservationIgnored private var permanentlyDeletedItemIDs: Set<UUID> = []
    /// Session generation in which the user last passed the export check (DEC-4); a lock invalidates it.
    @ObservationIgnored private var exportAuthorization: UUID?

    var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "AegisAppGroup") as? String ?? ""
    }

    private var isPreview: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("--preview-vault") ||
                ProcessInfo.processInfo.arguments.contains("--preview-onboarding")
        #else
            false
        #endif
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
                    if ProcessInfo.processInfo.arguments.contains("--preview-damaged-vault"), let localState {
                        let item = VaultItem(title: "Unreadable test record")
                        let revision = EncryptedRevision(vaultID: result.header.vaultID, itemID: item.id, id: UUID(),
                                                         parents: [], ciphertext: Data())
                        try await store?.saveRevision(revision)
                        var updated = item
                        updated.notes = "Unsaved test notes"
                        var state = localState.state
                        state.retain(VaultDraft(item: updated, original: item, parents: [revision.id]))
                        try localState.write(state)
                        recoverableDrafts = state.drafts
                    }
                    if PreviewFixtures.keychainDeleteFails {
                        UserDefaults.standard.set(true, forKey: "biometry.\(result.header.vaultID)")
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
        } catch { storageAvailable = false; phase = .locked; self.error = error.localizedDescription }
    }

    private func refresh() async throws {
        guard !replacingVault, let store else { return }
        let token = generation
        let requestID = UUID()
        refreshID = requestID
        let loadedHeader = try await store.header()
        guard token == generation, requestID == refreshID else { return }
        if header != loadedHeader {
            stopLANSync()
            lanSyncSnapshotDamaged = false
        }
        header = loadedHeader
        if let header {
            biometricEnabled = UserDefaults.standard.bool(forKey: "biometry.\(header.vaultID)")
            lanSyncEnabled = UserDefaults.standard.bool(forKey: "lanSync.\(header.vaultID)")
        }
        if phase == .unlocked {
            var stored = try await store.localRevisions()
            var loaded = try await crypto.localEntries(from: stored.revisions)
            guard token == generation, requestID == refreshID, phase == .unlocked else { return }
            if stored.unreadableRowCount == 0, loaded.unreadableRevisionCount == 0 {
                let expired = TrashPolicy.expiredGroups(in: loaded.entries)
                if !expired.isEmpty, let loadedHeader {
                    let expected = VaultSnapshot(header: loadedHeader, revisions: stored.revisions)
                    var markers: [EncryptedRevision] = []
                    for group in expired {
                        guard let first = group.first else { continue }
                        try await markers.append(crypto.encrypt(TrashPolicy.deletionMarker(for: first.item), parents: group.map(\.id)))
                        guard token == generation, requestID == refreshID, phase == .unlocked else { return }
                    }
                    // An already-merged active branch invalidates expiry based on old heads.
                    do {
                        _ = try await store.appendSyncedRevisions(markers, expected: expected)
                        lanSync.localDataChanged()
                    } catch VaultError.vaultChanged {
                        // The fresh projection below reschedules expiry using the new heads.
                    }

                    stored = try await store.localRevisions()
                    loaded = try await crypto.localEntries(from: stored.revisions)
                    guard token == generation, requestID == refreshID, phase == .unlocked else { return }
                }
            }
            entries = loaded.entries
            unreadableRevisionCount = stored.unreadableRowCount + loaded.unreadableRevisionCount
            if unreadableRevisionCount > 0 {
                stopLANSync()
                // A partial view cannot establish trash expiry, deletion, or the latest login revision.
                trashCleanupTask?.cancel()
                trashCleanupTask = nil
                permanentlyDeletedItemIDs = []
                do { try invalidateAutoFillSnapshot() } catch { self.error = error.localizedDescription }
                guard loaded.readableRevisionCount > 0 else { throw VaultError.damagedData }
                return
            }
            permanentlyDeletedItemIDs = Set(stored.revisions.map(\.itemID)).subtracting(entries.map(\.item.id))
            if let localState {
                var state = localState.state
                state.drafts.removeAll { permanentlyDeletedItemIDs.contains($0.id) }
                if state != localState.state {
                    try localState.write(state)
                }
                recoverableDrafts = state.drafts
            }
            scheduleTrashCleanup()
            scheduleAutoFillSnapshot()
            reconcileLANSync()
        }
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
            guard token == generation else { header = result.header; phase = .locked; await crypto.lock(); return }
            header = result.header; recoveryKey = result.recoveryKey; recoveryAcknowledged = false
            phase = .unlocked
            try await refresh(); touch()
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
            if recovery {
                try await crypto.recover(recoveryKey: password, header: header)
            } else {
                try await crypto.unlock(password: password, header: header)
            }
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
            defer { key.resetBytes(in: 0 ..< key.count) }
            guard token == generation else { return }
            try await crypto.unlock(deviceKey: key, header: header)
            guard token == generation else { await crypto.lock(); return }
            try await unlockLocalState(header: header)
            guard token == generation else { localState?.lock(); await crypto.lock(); return }
            phase = .unlocked; try await refresh(); touch()
        } catch { phase = .locked; entries = []; recoveryKey = nil; recoverableDrafts = []; localState?.lock(); await crypto.lock(); self.error = error.localizedDescription }
    }

    func setBiometrics(_ enabled: Bool) async {
        guard let header, phase == .unlocked, !isUpdatingBiometrics, !isBusy, enabled != biometricEnabled else { return }
        isUpdatingBiometrics = true; defer { isUpdatingBiometrics = false }
        let token = generation
        do {
            if enabled {
                var key = try await crypto.deviceKey()
                defer { key.resetBytes(in: 0 ..< key.count) }
                // A lock can occur while fetching the key. Do not register it for a stale session.
                guard token == generation, phase == .unlocked, self.header == header else { return }
                try DeviceKeyStore.save(key, vaultID: header.vaultID)
            } else {
                try DeviceKeyStore.delete(vaultID: header.vaultID)
            }
            biometricEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "biometry.\(header.vaultID)")
        } catch { self.error = error.localizedDescription }
    }

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

    private func stopLANSync() {
        lanSyncToken = nil
        lanSyncStart?.cancel(); lanSyncStart = nil
        lanSyncCommit?.cancel()
        lanSync.stop()
    }

    private func reconcileLANSync() {
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

    private func checkLANSync(_ token: UUID, header: VaultHeader) throws {
        try Task.checkCancellation()
        guard lanSyncToken == token, phase == .unlocked, self.header == header, unreadableRevisionCount == 0 else {
            throw CancellationError()
        }
    }

    private func lanSnapshot(store: VaultStore, header: VaultHeader, token: UUID) async throws -> VaultSnapshot {
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

    private func applyLANSync(store: VaultStore, snapshot: VaultSnapshot, incoming: [EncryptedRevision], token: UUID) async throws {
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

    enum LockReason { case manual, background, idle, system }

    func lock(reason: LockReason = .manual) {
        let syncCommit = lanSyncCommit
        stopLANSync()
        // Capture the latest bindings even if SwiftUI has not delivered onChange yet.
        for snapshot in draftSnapshots.values {
            retainDraft(snapshot())
        }
        draftSnapshots.removeAll()
        let previousLock = lockingTask
        let pendingWrite = phase == .unlocked && unreadableRevisionCount == 0 && !replacingVault &&
            (autoFillTask != nil || !pendingItemIDs.isEmpty || isBusy || syncCommit != nil)
        autoFillTask?.cancel()
        autoFillTask = nil
        generation = UUID(); entries = []; recoveryKey = nil; recoverableDrafts = []; idleTask?.cancel(); trashCleanupTask?.cancel()
        permanentlyDeletedItemIDs = []
        unreadableRevisionCount = 0
        lanSyncSnapshotDamaged = false
        noticeTask?.cancel(); notice = nil
        localState?.lock()
        // iOS already enforces the local-only clipboard expiration while suspended.
        if reason != .background {
            SecureClipboard.clear()
        }
        if phase == .unlocked {
            phase = .locked
        }
        let crypto = crypto
        lockingTask = Task { [weak self] in
            await previousLock?.value
            if let syncCommit {
                // Wait only for the database boundary, never for the network round.
                _ = await syncCommit.result
            }
            if pendingWrite {
                await self?.flushAutoFillSnapshot()
            }
            await crypto.lock()
        }
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
        guard phase == .unlocked, let store, !isBusy, !pendingItemIDs.contains(item.id) else { return false }
        guard unreadableRevisionCount == 0 else { error = L10n.text("error.damagedData"); return false }
        pendingItemIDs.insert(item.id)
        defer { pendingItemIDs.remove(item.id) }
        let token = generation
        do {
            let revisions = try await store.revisions()
            let current = try await crypto.cachedEntries(from: revisions)
            // An editor left open on another device must not resurrect a terminally deleted item.
            if revisions.contains(where: { $0.itemID == item.id }), !current.contains(where: { $0.item.id == item.id }) {
                self.error = L10n.text("editor.itemUnavailable")
                return false
            }
            let currentItem = current.filter { $0.item.id == item.id }
            if item.deletedAt == nil, !currentItem.isEmpty, currentItem.allSatisfy({ $0.item.deletedAt != nil }),
               !parents.contains(where: { parent in currentItem.contains { $0.id == parent } })
            {
                self.error = L10n.text("editor.itemChanged")
                return false
            }
            var updated = item; updated.modifiedAt = Date()
            let revision = try await crypto.encrypt(updated, parents: parents)
            guard token == generation, phase == .unlocked, unreadableRevisionCount == 0 else { return false }
            try await store.saveRevision(revision)
            lanSync.localDataChanged()
            try await refresh(); touch()
            guard token == generation, phase == .unlocked else { return false }
            showNotice(L10n.text("notice.saved"))
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func toggleFavorite(_ entry: VaultEntry) async {
        guard entry.item.deletedAt == nil else { return }
        var item = entry.item; item.isFavorite.toggle()
        await save(item, parents: [entry.id])
    }

    func trash(_ entry: VaultEntry) async {
        guard entry.item.deletedAt == nil else { return }
        var item = entry.item; item.deletedAt = Date()
        if await save(item, parents: [entry.id]) {
            showNotice(L10n.text("notice.trashed"))
        }
    }

    func restore(_ entry: VaultEntry) async {
        guard entries.contains(where: { $0.id == entry.id }), let deadline = TrashPolicy.expirationDate(for: entry.item) else { return }
        guard deadline > Date() else {
            error = L10n.text("trash.expired")
            do { try await refresh() } catch { self.error = error.localizedDescription }
            return
        }
        var item = entry.item; item.deletedAt = nil
        if await save(item, parents: [entry.id]) {
            showNotice(L10n.text("notice.restored"))
        }
    }

    func deleteImmediately(_ entry: VaultEntry) async {
        guard phase == .unlocked, entry.item.deletedAt != nil,
              entries.contains(where: { $0.id == entry.id }) else { return }
        let parents = entries.filter { $0.item.id == entry.item.id }.map(\.id)
        if await save(TrashPolicy.deletionMarker(for: entry.item), parents: parents) {
            discardDraft(entry.item.id)
            showNotice(L10n.text("notice.deleted"))
        }
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.notice = nil
        }
    }

    private func scheduleTrashCleanup() {
        trashCleanupTask?.cancel()
        guard unreadableRevisionCount == 0 else { return }
        // A conflict expires only once all its branches have reached their deadlines.
        let deadlines = Dictionary(grouping: entries, by: \.item.id).values.compactMap { group -> Date? in
            let dates = group.compactMap { TrashPolicy.expirationDate(for: $0.item) }
            return dates.count == group.count ? dates.max() : nil
        }
        guard let next = deadlines.min() else { return }
        trashCleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                guard let self, phase == .unlocked else { return }
                try await refresh()
            } catch is CancellationError {
                return
            } catch { self?.error = error.localizedDescription }
        }
    }

    func resolve(_ entry: VaultEntry) async {
        await save(entry.item, parents: entries.filter { $0.item.id == entry.item.id }.map(\.id))
    }

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
        fileprivate let generation: UUID
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
        fileprivate let snapshot: VaultSnapshot
        fileprivate let generation: UUID
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
    private func guardedRestoreStep(token: UUID, _ step: () async throws -> Void) async throws {
        guard token == generation else { throw CancellationError() }
        try await step()
        guard token == generation else { throw CancellationError() }
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private struct AutoFillVersion: Equatable {
        let vaultID: UUID
        let loginRevisions: Set<UUID>

        init(header: VaultHeader, entries: [VaultEntry]) {
            vaultID = header.vaultID
            loginRevisions = Set(entries.lazy.filter(AutoFillCredential.includes).map(\.id))
        }
    }

    private var autoFillDirectory: URL? {
        guard !isPreview, !appGroup.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private func scheduleAutoFillSnapshot() {
        guard !replacingVault, unreadableRevisionCount == 0, let header, let directory = autoFillDirectory else { return }
        autoFillTask?.cancel()
        autoFillTask = nil
        let version = AutoFillVersion(header: header, entries: entries)
        guard shouldPublishAutoFill(version, directory: directory) else { return }
        let token = generation
        autoFillTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard let self, generation == token, phase == .unlocked else { return }
                defer {
                    if !Task.isCancelled {
                        autoFillTask = nil
                    }
                }
                try await publishAutoFillSnapshot(header: header, entries: entries, version: version, directory: directory)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                discardFailedAutoFillSnapshot(error, directory: directory)
            }
        }
    }

    private func flushAutoFillSnapshot() async {
        guard let store, let directory = autoFillDirectory else { return }
        do {
            // A save may have committed just as the UI locked, before its refresh could finish.
            let snapshot = try await store.snapshot()
            let entries = try await crypto.cachedEntries(from: snapshot.revisions)
            let version = AutoFillVersion(header: snapshot.header, entries: entries)
            guard shouldPublishAutoFill(version, directory: directory) else { return }
            try await publishAutoFillSnapshot(header: snapshot.header, entries: entries, version: version, directory: directory)
        } catch {
            discardFailedAutoFillSnapshot(error, directory: directory)
        }
    }

    private func shouldPublishAutoFill(_ version: AutoFillVersion, directory: URL) -> Bool {
        publishedAutoFill != version ||
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent(AutoFillSnapshot.filename).path)
    }

    private func publishAutoFillSnapshot(header: VaultHeader, entries: [VaultEntry], version: AutoFillVersion, directory: URL) async throws {
        try Task.checkCancellation()
        let data = try await crypto.makeAutoFillSnapshot(header: header, entries: entries)
        try Task.checkCancellation()
        let url = directory.appendingPathComponent(AutoFillSnapshot.filename)
        #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: url, options: .atomic)
        #endif
        publishedAutoFill = version
    }

    private func discardFailedAutoFillSnapshot(_ failure: Error, directory: URL) {
        publishedAutoFill = nil
        do {
            try removeAutoFillFile(AutoFillSnapshot.filename, from: directory)
            error = failure.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func invalidateAutoFillSnapshot() throws {
        autoFillTask?.cancel()
        autoFillTask = nil
        publishedAutoFill = nil
        guard let directory = autoFillDirectory else { return }
        try removeAutoFillFile(AutoFillSnapshot.filename, from: directory)
    }

    private func removeAutoFillFile(_ filename: String, from directory: URL) throws {
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
        } catch CocoaError.fileNoSuchFile {}
    }

    private func unlockLocalState(header: VaultHeader) async throws {
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
