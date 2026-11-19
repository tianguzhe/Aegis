import AegisCore
import Foundation
import SwiftData

@Model
final class StoredObject {
    @Attribute(.unique) var name: String
    var kind: String
    var payload: Data
    // No longer read since iCloud sync was removed. Kept so existing stores open without a
    // SwiftData schema migration; older stores may also hold unused "metadata" rows.
    var pending: Bool
    init(name: String, kind: String, payload: Data, pending: Bool) {
        self.name = name; self.kind = kind; self.payload = payload; self.pending = pending
    }
}

@ModelActor
public actor VaultStore {
    private func encode(_ value: some Encodable) throws -> Data {
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
        return try VaultStore(modelContainer: ModelContainer(for: schema, configurations: config))
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
        try modelContext.insert(StoredObject(name: "header", kind: "header", payload: encode(header), pending: true))
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
        try modelContext.insert(StoredObject(name: name, kind: "revision", payload: encode(revision), pending: true))
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
        return try VaultSnapshot(header: header, revisions: revisions())
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

    /// Joins an existing vault only while this store is still empty. The check and write share one
    /// actor turn, so a concurrent setup or cloud fetch cannot turn onboarding into a merge.
    @discardableResult
    public func restoreNewVault(header: VaultHeader, revisions: [EncryptedRevision]) throws -> RestoreResult {
        guard try self.header() == nil else { throw VaultError.differentVault }
        guard try self.revisions().isEmpty else { throw VaultError.damagedData }
        return try restore(header: header, revisions: revisions)
    }

    /// `beforeSave` lets tests fail the commit after rows are changed; production passes a no-op.
    func replaceVault(expected: VaultSnapshot, header: VaultHeader, revisions incoming: [EncryptedRevision],
                      beforeSave: @Sendable () throws -> Void) throws
    {
        try header.validate()
        guard header.vaultID != expected.header.vaultID,
              incoming.allSatisfy({ $0.vaultID == header.vaultID && $0.formatVersion == 1 }),
              Set(incoming.map(\.id)).count == incoming.count else { throw VaultError.damagedData }
        guard let current = try object("header"),
              try JSONDecoder().decode(VaultHeader.self, from: current.payload) == expected.header
        else { throw VaultError.vaultChanged }
        let all = try modelContext.fetch(FetchDescriptor<StoredObject>())
        let storedRevisionIDs = Set(all.filter { $0.kind == "revision" }.map(\.name))
        guard storedRevisionIDs == Set(expected.revisions.map(\.id.uuidString)) else { throw VaultError.vaultChanged }
        do {
            // The header row is updated in place: deleting and re-inserting the unique name
            // "header" in one save would rely on SwiftData's upsert behaviour.
            current.payload = try encode(header)
            current.pending = true
            // Leftover "metadata" rows from the removed iCloud sync are dropped along with revisions.
            for object in all where object.kind != "header" {
                modelContext.delete(object)
            }
            for revision in incoming {
                try modelContext.insert(StoredObject(name: revision.id.uuidString, kind: "revision",
                                                     payload: encode(revision), pending: true))
            }
            try beforeSave()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// `beforeSave` lets tests fail the commit after rows are inserted; production passes a no-op.
    func restore(header: VaultHeader, revisions incoming: [EncryptedRevision],
                 beforeSave: @Sendable () throws -> Void) throws -> RestoreResult
    {
        try header.validate()
        guard incoming.allSatisfy({ $0.vaultID == header.vaultID && $0.formatVersion == 1 }) else { throw VaultError.damagedData }
        let localHeader = try self.header()
        if let localHeader, localHeader != header {
            throw VaultError.differentVault
        }
        let existing = try Dictionary(uniqueKeysWithValues: revisions().map { ($0.id, $0) })
        var additions: [UUID: EncryptedRevision] = [:]
        for revision in incoming {
            if let previous = existing[revision.id] ?? additions[revision.id], previous != revision {
                throw VaultError.damagedData
            }
            if existing[revision.id] == nil {
                additions[revision.id] = revision
            }
        }
        // Everything is validated before the store is mutated.
        do {
            if localHeader == nil {
                try modelContext.insert(StoredObject(name: "header", kind: "header", payload: encode(header), pending: true))
            }
            for revision in additions.values {
                try modelContext.insert(StoredObject(name: revision.id.uuidString, kind: "revision",
                                                     payload: encode(revision), pending: true))
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

public extension VaultStore {
    /// Replaces the stored vault with a rotated one in one transaction (Docs/KEY_ROTATION_DESIGN.md §3).
    ///
    /// `expected` is the snapshot the rotation was prepared from. Any save after it would be lost by
    /// the swap, so a changed header or revision set rejects the replacement. Every old revision is
    /// deleted, so the store no longer holds ciphertext under the old vault key (SQLite may still
    /// keep freed pages on disk until they are reused).
    /// - Throws: `VaultError.vaultChanged` when the store differs from `expected`,
    ///   `VaultError.damagedData` for revisions not belonging to `header`, or the save error.
    ///   On any error nothing is written.
    func replaceVault(expected: VaultSnapshot, header: VaultHeader, revisions: [EncryptedRevision]) throws {
        try replaceVault(expected: expected, header: header, revisions: revisions, beforeSave: {})
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
