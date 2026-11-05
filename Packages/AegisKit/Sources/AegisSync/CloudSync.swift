import AegisCore
import AegisStorage
import CloudKit
import Foundation

public enum SyncStatus: Sendable {
    case disabled, syncing, ready, unavailable, accountChanged, failed(String)
}

public actor CloudSync: CKSyncEngineDelegate {
    private let store: VaultStore
    private let container: CKContainer
    private let zoneID = CKRecordZone.ID(zoneName: "AegisVault")
    private var engine: CKSyncEngine?
    private var stopped = false
    private var operationFailed = false
    private var synchronizing = false
    private var needsAnotherSync = false
    private let update: @Sendable (SyncStatus) async -> Void
    private let changed: @Sendable () async -> Void

    public init(containerID: String, store: VaultStore, update: @escaping @Sendable (SyncStatus) async -> Void,
                changed: @escaping @Sendable () async -> Void) {
        container = CKContainer(identifier: containerID); self.store = store
        self.update = update; self.changed = changed
    }

    public func start() async {
        guard !stopped else { return }
        do {
            guard try await container.accountStatus() == .available else { await update(.unavailable); return }
            let user = try await container.userRecordID().recordName
            let account = Data(user.utf8)
            if let previous = try await store.metadata("account"), previous != account {
                stopped = true; await update(.accountChanged); return
            }
            try await store.setMetadata("account", data: account)
            if engine == nil {
                let state = try await store.metadata("sync-state").map {
                    try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
                }
                var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                                 stateSerialization: state, delegate: self)
                configuration.automaticallySync = true
                engine = CKSyncEngine(configuration)
            }
            await synchronize()
        } catch { await update(.failed(error.localizedDescription)) }
    }

    public func synchronize() async {
        guard !stopped, let engine else { return }
        guard !synchronizing else { needsAnotherSync = true; return }
        synchronizing = true
        needsAnotherSync = false
        defer {
            synchronizing = false
            if needsAnotherSync && !stopped { Task { await self.synchronize() } }
        }
        operationFailed = false
        await update(.syncing)
        do {
            // Fetch the existing header before publishing local changes.
            try await engine.fetchChanges()
            guard !stopped else { return }
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            let pending = try await store.pendingObjects()
            engine.state.add(pendingRecordZoneChanges: pending.map {
                .saveRecord(CKRecord.ID(recordName: $0.name, zoneID: zoneID))
            })
            try await engine.sendChanges()
            if !operationFailed && !needsAnotherSync { await update(.ready) }
        } catch { await update(.failed(error.localizedDescription)) }
    }

    public func stop() async {
        stopped = true
        await engine?.cancelOperations()
        engine = nil
        await update(.disabled)
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard !stopped else { return }
        do {
            switch event {
            case .stateUpdate(let state):
                try await store.setMetadata("sync-state", data: JSONEncoder().encode(state.stateSerialization))
            case .accountChange(let change):
                switch change.changeType {
                case .signIn(let user):
                    let previous = try await store.metadata("account")
                    if previous != Data(user.recordName.utf8) { stopped = true; await update(.accountChanged) }
                case .signOut, .switchAccounts:
                    stopped = true; await update(.accountChanged)
                @unknown default:
                    stopped = true; await update(.accountChanged)
                }
            case .fetchedRecordZoneChanges(let changes):
                // Header is processed first so another vault cannot be silently merged.
                for modification in changes.modifications.sorted(by: { $0.record.recordID.recordName == "header" && $1.record.recordID.recordName != "header" }) {
                    try await receive(modification.record)
                }
                // This protocol uses encrypted revisions for deletions. Unexpected physical deletion is an error.
                if !changes.deletions.isEmpty { throw VaultError.damagedData }
                await changed()
            case .sentRecordZoneChanges(let changes):
                for record in changes.savedRecords {
                    if let payload = record["payload"] as? Data {
                        try await store.acknowledge(name: record.recordID.recordName, payload: payload)
                    }
                }
                for failed in changes.failedRecordSaves {
                    if failed.error.code == .serverRecordChanged, let server = failed.error.serverRecord {
                        try await receive(server)
                        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                    } else {
                        operationFailed = true
                        await update(.failed(failed.error.localizedDescription))
                    }
                }
                await changed()
            case .sentDatabaseChanges(let changes):
                if let failure = changes.failedZoneSaves.first { throw failure.error }
            case .didFetchRecordZoneChanges(let changes):
                if let error = changes.error, error.code != .zoneNotFound { throw error }
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == zoneID }) { throw VaultError.damagedData }
            default: break
            }
        } catch {
            operationFailed = true
            if error is VaultError { stopped = true }
            await update(.failed(error.localizedDescription))
        }
    }

    private func receive(_ record: CKRecord) async throws {
        guard record.recordID.zoneID == zoneID, record.recordType == "VaultObject",
              let kind = record["kind"] as? String, let payload = record["payload"] as? Data,
              payload.count <= 500_000 else { throw VaultError.damagedData }
        try await store.receive(SyncObject(name: record.recordID.recordName, kind: kind, payload: payload))
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !stopped else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        let store = self.store
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: Array(pending.prefix(100))) { id in
            guard let object = try? await store.syncObject(named: id.recordName) else { return nil }
            let record = CKRecord(recordType: "VaultObject", recordID: id)
            record["kind"] = object.kind as CKRecordValue
            record["payload"] = object.payload as CKRecordValue
            return record
        }
    }
}
