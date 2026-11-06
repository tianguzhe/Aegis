import AegisCore
import Foundation
import SwiftData

@Model
final class StoredObject {
    @Attribute(.unique) var name: String
    var kind: String
    var payload: Data
    var pending: Bool
    init(name: String, kind: String, payload: Data, pending: Bool) {
        self.name = name; self.kind = kind; self.payload = payload; self.pending = pending
    }
}

public struct SyncObject: Sendable {
    public let name: String
    public let kind: String
    public let payload: Data
    public init(name: String, kind: String, payload: Data) {
        self.name = name; self.kind = kind; self.payload = payload
    }
}

@ModelActor
public actor VaultStore {
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func make(directory: URL? = nil, inMemory: Bool = false) throws -> VaultStore {
        let schema = Schema([StoredObject.self])
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            config = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("vault.store"), cloudKitDatabase: .none)
        } else {
            config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        }
        return VaultStore(modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    private func object(_ name: String) throws -> StoredObject? {
        var descriptor = FetchDescriptor<StoredObject>(predicate: #Predicate { $0.name == name })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    public func header() throws -> VaultHeader? {
        try object("header").map { try JSONDecoder().decode(VaultHeader.self, from: $0.payload) }
    }

    public func saveHeader(_ header: VaultHeader) throws {
        try header.validate()
        if let existing = try self.header() {
            guard existing == header else { throw VaultError.differentVault }
            return
        }
        modelContext.insert(StoredObject(name: "header", kind: "header", payload: try encode(header), pending: true))
        try modelContext.save()
    }

    public func revisions() throws -> [EncryptedRevision] {
        let kind = "revision"
        return try modelContext.fetch(FetchDescriptor<StoredObject>(predicate: #Predicate { $0.kind == kind }))
            .map { try JSONDecoder().decode(EncryptedRevision.self, from: $0.payload) }
    }

    public func saveRevision(_ revision: EncryptedRevision) throws {
        guard let header = try header(), revision.vaultID == header.vaultID else { throw VaultError.differentVault }
        let name = revision.id.uuidString
        guard try object(name) == nil else { return }
        modelContext.insert(StoredObject(name: name, kind: "revision", payload: try encode(revision), pending: true))
        try modelContext.save()
    }

    public func pendingObjects() throws -> [SyncObject] {
        try modelContext.fetch(FetchDescriptor<StoredObject>(predicate: #Predicate { $0.pending }))
            .filter { $0.kind != "metadata" }.map { SyncObject(name: $0.name, kind: $0.kind, payload: $0.payload) }
    }

    public func syncObject(named name: String) throws -> SyncObject? {
        try object(name).map { SyncObject(name: $0.name, kind: $0.kind, payload: $0.payload) }
    }

    public func acknowledge(name: String, payload: Data) throws {
        if let obj = try object(name), obj.payload == payload { obj.pending = false; try modelContext.save() }
    }

    public func receive(_ incoming: SyncObject) throws {
        let canonical: Data
        if incoming.kind == "header" {
            guard incoming.name == "header" else { throw VaultError.damagedData }
            let header = try JSONDecoder().decode(VaultHeader.self, from: incoming.payload)
            try header.validate()
            if let existing = try self.header(), existing != header { throw VaultError.differentVault }
            canonical = try encode(header)
        } else if incoming.kind == "revision" {
            let revision = try JSONDecoder().decode(EncryptedRevision.self, from: incoming.payload)
            guard incoming.name == revision.id.uuidString, revision.formatVersion == 1,
                  revision.ciphertext.count <= 300_000, revision.parents.count <= 1000 else { throw VaultError.damagedData }
            if let header = try header(), revision.vaultID != header.vaultID { throw VaultError.differentVault }
            canonical = try encode(revision)
        } else { throw VaultError.unsupportedFormat }
        if let existing = try object(incoming.name) {
            // Immutable CloudKit records may only acknowledge identical bytes.
            let existingCanonical: Data
            if incoming.kind == "header" { existingCanonical = try encode(JSONDecoder().decode(VaultHeader.self, from: existing.payload)) }
            else { existingCanonical = try encode(JSONDecoder().decode(EncryptedRevision.self, from: existing.payload)) }
            guard existingCanonical == canonical else { throw VaultError.damagedData }
            existing.pending = false
        } else {
            modelContext.insert(StoredObject(name: incoming.name, kind: incoming.kind, payload: canonical, pending: false))
        }
        try modelContext.save()
    }

    public func metadata(_ name: String) throws -> Data? { try object("meta.\(name)")?.payload }
    public func setMetadata(_ name: String, data: Data) throws {
        let key = "meta.\(name)"
        if let existing = try object(key) { existing.payload = data }
        else { modelContext.insert(StoredObject(name: key, kind: "metadata", payload: data, pending: false)) }
        try modelContext.save()
    }

    public func backup() throws -> Data {
        guard let header = try header() else { throw VaultError.locked }
        return try encode(VaultBackup(header: header, revisions: revisions()))
    }

    /// The header and every stored revision, read in one actor turn so they are mutually consistent.
    /// Throws `VaultError.locked` when no vault exists yet.
    public func snapshot() throws -> VaultSnapshot {
        guard let header = try header() else { throw VaultError.locked }
        return VaultSnapshot(header: header, revisions: try revisions())
    }

    /// Merges authenticated backup contents in one transaction (Docs/BACKUP_FORMAT_DESIGN_V1.md §10.3).
    ///
    /// Immutable revisions are unioned: nothing local is deleted, a repeated restore inserts nothing,
    /// and a revision ID already stored with different contents rejects the whole restore. Callers
    /// must authenticate `revisions` first; this only re-checks identity against the current store.
    /// - Throws: `VaultError.differentVault` when another header is stored, `VaultError.damagedData`
    ///   for conflicting or foreign revisions, or the save error. On any error nothing is written.
    @discardableResult
    public func restore(header: VaultHeader, revisions incoming: [EncryptedRevision]) throws -> RestoreResult {
        try restore(header: header, revisions: incoming, beforeSave: {})
    }

    /// `beforeSave` lets tests fail the commit after rows are inserted; production passes a no-op.
    func restore(header: VaultHeader, revisions incoming: [EncryptedRevision],
                 beforeSave: @Sendable () throws -> Void) throws -> RestoreResult {
        try header.validate()
        guard incoming.allSatisfy({ $0.vaultID == header.vaultID && $0.formatVersion == 1 }) else { throw VaultError.damagedData }
        let localHeader = try self.header()
        if let localHeader, localHeader != header { throw VaultError.differentVault }
        let existing = Dictionary(uniqueKeysWithValues: try revisions().map { ($0.id, $0) })
        var additions: [UUID: EncryptedRevision] = [:]
        for revision in incoming {
            if let previous = existing[revision.id] ?? additions[revision.id], previous != revision { throw VaultError.damagedData }
            if existing[revision.id] == nil { additions[revision.id] = revision }
        }
        // Everything is validated before the store is mutated.
        do {
            if localHeader == nil {
                modelContext.insert(StoredObject(name: "header", kind: "header", payload: try encode(header), pending: true))
            }
            for revision in additions.values {
                modelContext.insert(StoredObject(name: revision.id.uuidString, kind: "revision",
                                                payload: try encode(revision), pending: true))
            }
            try beforeSave()
            try modelContext.save()
        } catch {
            // Unsaved inserts would otherwise be committed by the next unrelated save().
            modelContext.rollback()
            throw error
        }
        return RestoreResult(createdHeader: localHeader == nil, insertedRevisions: additions.count)
    }
}

/// A consistent copy of the stored vault used for export.
public struct VaultSnapshot: Sendable {
    public let header: VaultHeader
    public let revisions: [EncryptedRevision]

    /// True when a revision names a parent this device never received, so the history is not closed.
    public var hasIncompleteHistory: Bool {
        let ids = Set(revisions.map(\.id))
        return revisions.contains { $0.parents.contains { !ids.contains($0) } }
    }
}

/// What a restore actually wrote, which may differ from the preview if the store changed meanwhile.
public struct RestoreResult: Sendable, Equatable {
    public let createdHeader: Bool
    public let insertedRevisions: Int
}
