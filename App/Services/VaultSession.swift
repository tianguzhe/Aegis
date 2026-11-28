import AegisCore
import AegisStorage
import AegisSync
import Foundation
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
    var lanSyncEnabled = false
    var lanSyncSnapshotDamaged = false
    var lanSyncBlockedByDamage: Bool {
        unreadableRevisionCount > 0 || lanSyncSnapshotDamaged
    }

    let lanSync = LANSyncService()
    @ObservationIgnored var lanSyncForeground = false
    @ObservationIgnored var lanSyncToken: UUID?
    @ObservationIgnored var lanSyncStart: Task<Void, Never>?
    @ObservationIgnored var lanSyncCommit: Task<RestoreResult, Error>?
    @ObservationIgnored var lanSyncSuspended = false
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

    /// Device-local auto-lock and clipboard timeouts. Not part of the vault or its backups.
    var securitySettings = SecurityPreferences.load() {
        didSet {
            guard securitySettings != oldValue else { return }
            SecurityPreferences.save(securitySettings)
            // Restart the idle timer so a shorter timeout applies immediately.
            touch()
        }
    }

    @ObservationIgnored var generation = UUID()
    @ObservationIgnored let crypto = VaultCrypto()
    @ObservationIgnored var store: VaultStore?
    @ObservationIgnored var idleTask: Task<Void, Never>?
    @ObservationIgnored var lockingTask: Task<Void, Never>?
    @ObservationIgnored var trashCleanupTask: Task<Void, Never>?
    @ObservationIgnored var autoFillTask: Task<Void, Never>?
    @ObservationIgnored var publishedAutoFill: AutoFillVersion?
    @ObservationIgnored var replacingVault = false
    @ObservationIgnored var refreshID = UUID()
    @ObservationIgnored var noticeTask: Task<Void, Never>?
    @ObservationIgnored var localState: LocalVaultStateStore?
    @ObservationIgnored var draftSnapshots: [UUID: () -> VaultDraft] = [:]
    @ObservationIgnored var pendingDraft: (draft: VaultDraft, task: Task<Void, Never>)?
    @ObservationIgnored var permanentlyDeletedItemIDs: Set<UUID> = []
    /// Session generation in which the user last passed the export check (DEC-4); a lock invalidates it.
    @ObservationIgnored var exportAuthorization: UUID?

    var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "AegisAppGroup") as? String ?? ""
    }

    var isPreview: Bool {
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
                        // Simulates enabled biometrics without a Keychain item, so disabling hits the failing delete.
                        try await DeviceKeyStore.markEnabledForPreview(key: crypto.deviceKey(), vaultID: result.header.vaultID)
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

    func refresh() async throws {
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
            biometricEnabled = DeviceKeyStore.isEnabled(vaultID: header.vaultID)
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
            do {
                try await crypto.unlock(deviceKey: key, header: header, keyCheck: DeviceKeyStore.keyCheck(vaultID: header.vaultID) ?? Data())
            } catch VaultError.deviceKeyMismatch {
                // A key that cannot be confirmed must not be offered again; the password path re-enables it.
                // Removing the flags already stops that, and re-enabling overwrites the item, so a failed
                // delete only leaves an unused item and must not hide the mismatch error below.
                try? DeviceKeyStore.delete(vaultID: header.vaultID)
                DeviceKeyStore.forget(vaultID: header.vaultID)
                biometricEnabled = false
                throw VaultError.deviceKeyMismatch
            }
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
                biometricEnabled = true
            } else {
                try DeviceKeyStore.delete(vaultID: header.vaultID)
                DeviceKeyStore.forget(vaultID: header.vaultID)
                biometricEnabled = false
            }
        } catch { self.error = error.localizedDescription }
    }

    enum LockReason { case manual, background, idle, system }

    func lock(reason: LockReason = .manual) {
        let syncCommit = lanSyncCommit
        stopLANSync()
        flushPendingDraft()
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
        let timeout = securitySettings.autoLock.seconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
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

    func toggleArchive(_ entry: VaultEntry) async {
        guard entry.item.deletedAt == nil else { return }
        var item = entry.item
        let next = !item.archived
        item.isArchived = next ? true : nil
        if await save(item, parents: [entry.id]) {
            showNotice(L10n.text(next ? "notice.archived" : "notice.unarchived"))
        }
    }

    /// Distinct tags across non-trashed records, sorted for sidebar and editor suggestions.
    var allTags: [String] {
        let raw = entries.lazy.filter { $0.item.deletedAt == nil }.flatMap(\.item.tagList)
        return VaultItem.normalizeTags(Array(raw)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
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

    func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.notice = nil
        }
    }

    func scheduleTrashCleanup() {
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
}
