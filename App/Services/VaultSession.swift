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
    var error: String?
    var isBusy = false
    var recoveryKey: String?
    var recoveryAcknowledged = false
    var syncStatus: SyncStatus = .disabled
    var header: VaultHeader?
    var biometricEnabled = false
    var storageAvailable = true
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

    var cloudConfigured: Bool { !isPreview && Bundle.main.object(forInfoDictionaryKey: "AegisCloudEnabled") as? String == "YES" }
    var cloudContainer: String { Bundle.main.object(forInfoDictionaryKey: "AegisCloudContainer") as? String ?? "" }
    var appGroup: String { Bundle.main.object(forInfoDictionaryKey: "AegisAppGroup") as? String ?? "" }
    private var isPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--preview-vault")
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
                let result = try await crypto.create(password: "Aegis preview fixture only")
                try await store?.saveHeader(result.header)
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
            try await store.saveHeader(result.header)
            guard token == generation else { self.header = result.header; phase = .locked; await crypto.lock(); return }
            header = result.header; recoveryKey = result.recoveryKey; recoveryAcknowledged = false
            phase = .unlocked
            try await refresh(); touch()
            scheduleSync()
        } catch { await crypto.lock(); self.error = error.localizedDescription }
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
            phase = .unlocked
            try await refresh(); touch()
        } catch { phase = .locked; entries = []; await crypto.lock(); self.error = error.localizedDescription }
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
            phase = .unlocked; try await refresh(); touch()
        } catch { phase = .locked; entries = []; await crypto.lock(); self.error = error.localizedDescription }
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

    func lock() {
        generation = UUID(); entries = []; recoveryKey = nil; idleTask?.cancel(); SecureClipboard.clear()
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
            self?.lock()
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

    func exportBackup() async throws -> Data {
        guard let store, phase == .unlocked else { throw VaultError.locked }
        return try await store.backup()
    }

    func importBackup(data: Data, password: String) async -> Bool {
        guard let store, !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        do {
            guard data.count <= 32 * 1024 * 1024 else { throw VaultError.oversizedRecord }
            let backup = try JSONDecoder().decode(VaultBackup.self, from: data)
            try backup.validate()
            let verifier = VaultCrypto()
            try await verifier.unlock(password: password, header: backup.header)
            _ = try await verifier.entries(from: backup.revisions)
            await verifier.lock()
            try await store.importBackup(backup)
            try await refresh()
            if phase == .setup { phase = .locked }
            scheduleSync()
            return true
        } catch { self.error = error.localizedDescription; return false }
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
}
