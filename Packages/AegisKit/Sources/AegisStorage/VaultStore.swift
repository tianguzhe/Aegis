import AegisCore
import Foundation
import SwiftData

@Model
final class StoredObject {
    @Attribute(.unique) var name: String
    var kind: String
    var payload: Data
    init(name: String, kind: String, payload: Data) {
        self.name = name; self.kind = kind; self.payload = payload
    }
}

@ModelActor
public actor VaultStore {
    private var cachedHeader: VaultHeader?
    /// Decoded revision rows, mirroring the store. This actor is the only writer of the database in
    /// the process (the AutoFill extension reads a separate snapshot file), so every successful save
    /// updates the mirror and saves, refreshes and sync rounds skip refetching and decoding all rows.
    /// Only set while every row decodes, so `localRevisions()` keeps counting damaged rows.
    /// A failed save drops it, and the next read refetches from the store.
    private var cachedRevisions: [EncryptedRevision]?

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
        if let cachedHeader {
            return cachedHeader
        }
        let header = try object("header").map { try JSONDecoder().decode(VaultHeader.self, from: $0.payload) }
        cachedHeader = header
        return header
    }

    public func saveHeader(_ header: VaultHeader) throws {
        try header.validate()
        if let existing = try self.header() {
            guard existing == header else { throw VaultError.differentVault }
            return
        }
        try modelContext.insert(StoredObject(name: "header", kind: "header", payload: encode(header)))
        try saveChanges()
        cachedHeader = header
    }

    private func revisionObjects() throws -> [StoredObject] {
        let kind = "revision"
        return try modelContext.fetch(FetchDescriptor<StoredObject>(predicate: #Predicate { $0.kind == kind }))
    }

    public func revisions() throws -> [EncryptedRevision] {
        if let cachedRevisions {
            return cachedRevisions
        }
        let decoder = JSONDecoder()
        let revisions = try revisionObjects().map { try decoder.decode(EncryptedRevision.self, from: $0.payload) }
        cachedRevisions = revisions
        return revisions
    }

    /// Reads local revision rows for display. Counts undecodable rows without modifying them.
    /// Store fetch errors still propagate. Decoded revisions must be authenticated by the caller.
    public func localRevisions() throws -> (revisions: [EncryptedRevision], unreadableRowCount: Int) {
        if let cachedRevisions {
            return (cachedRevisions, 0)
        }
        let decoder = JSONDecoder()
        var revisions: [EncryptedRevision] = []
        var unreadable = 0
        for object in try revisionObjects() {
            do {
                try revisions.append(decoder.decode(EncryptedRevision.self, from: object.payload))
            } catch is DecodingError {
                unreadable += 1
            }
        }
        if unreadable == 0 {
            cachedRevisions = revisions
        }
        return (revisions, unreadable)
    }

    public func saveRevision(_ revision: EncryptedRevision) throws {
        guard let header = try header(), revision.vaultID == header.vaultID else { throw VaultError.differentVault }
        let name = revision.id.uuidString
        guard try object(name) == nil else { return }
        try modelContext.insert(StoredObject(name: name, kind: "revision", payload: encode(revision)))
        try saveChanges()
        cachedRevisions?.append(revision)
    }

    private func saveChanges() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            cachedRevisions = nil
            throw error
        }
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
    func restore(header: VaultHeader, revisions incoming: [EncryptedRevision]) throws -> RestoreResult {
        try restore(header: header, revisions: incoming, beforeSave: {})
    }

    /// Appends new root revisions to the exact state reviewed in the import preview.
    /// A stale preview throws `VaultError.vaultChanged` before any rows are written.
    public func appendImportedRevisions(_ incoming: [EncryptedRevision], expected: VaultSnapshot) throws -> RestoreResult {
        guard !incoming.isEmpty, incoming.allSatisfy(\.parents.isEmpty) else { throw VaultError.damagedData }
        return try restore(header: expected.header, revisions: incoming, expected: expected) {
            try Task.checkCancellation()
        }
    }

    /// Appends authenticated, graph-validated versions (including local deletion markers) to an
    /// existing vault. `expected` is the exact snapshot used to validate those versions.
    /// Throws on a changed vault, cancellation, or save failure without persisting a partial batch.
    public func appendSyncedRevisions(_ incoming: [EncryptedRevision], expected: VaultSnapshot) throws -> RestoreResult {
        try appendSyncedRevisions(incoming, expected: expected) { try Task.checkCancellation() }
    }

    func appendSyncedRevisions(_ incoming: [EncryptedRevision], expected: VaultSnapshot,
                               beforeSave: @Sendable () throws -> Void) throws -> RestoreResult
    {
        try restore(header: expected.header, revisions: incoming, expected: expected, beforeSave: beforeSave)
    }

    /// Joins an existing vault only while this store is still empty. The check and write share one
    /// actor turn, so another setup cannot turn onboarding into a merge.
    @discardableResult
    public func restoreNewVault(header: VaultHeader, revisions: [EncryptedRevision]) throws -> RestoreResult {
        guard try self.header() == nil else { throw VaultError.differentVault }
        guard try self.revisions().isEmpty else { throw VaultError.damagedData }
        // The invitation or import sheet can close while the store is waiting to commit.
        return try restore(header: header, revisions: revisions) { try Task.checkCancellation() }
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
            for object in all where object.kind != "header" {
                modelContext.delete(object)
            }
            for revision in incoming {
                try modelContext.insert(StoredObject(name: revision.id.uuidString, kind: "revision",
                                                     payload: encode(revision)))
            }
            try beforeSave()
            try modelContext.save()
            cachedHeader = header
            cachedRevisions = incoming
        } catch {
            modelContext.rollback()
            cachedRevisions = nil
            throw error
        }
    }

    /// `beforeSave` lets tests fail the commit after rows are inserted; production passes a no-op.
    func restore(header: VaultHeader, revisions incoming: [EncryptedRevision], expected: VaultSnapshot? = nil,
                 beforeSave: @Sendable () throws -> Void) throws -> RestoreResult
    {
        try header.validate()
        guard incoming.allSatisfy({ $0.vaultID == header.vaultID && $0.formatVersion == 1 }) else { throw VaultError.damagedData }
        let localHeader = try self.header()
        if let localHeader, localHeader != header {
            throw VaultError.differentVault
        }
        var existing: [UUID: EncryptedRevision] = [:]
        for revision in try revisions() {
            guard existing.updateValue(revision, forKey: revision.id) == nil else { throw VaultError.damagedData }
        }
        if let expected {
            guard localHeader == expected.header, existing.count == expected.revisions.count,
                  expected.revisions.allSatisfy({ existing[$0.id] == $0 }) else { throw VaultError.vaultChanged }
        }
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
                try modelContext.insert(StoredObject(name: "header", kind: "header", payload: encode(header)))
            }
            for revision in additions.values {
                try modelContext.insert(StoredObject(name: revision.id.uuidString, kind: "revision",
                                                     payload: encode(revision)))
            }
            try beforeSave()
            try modelContext.save()
            cachedHeader = header
            cachedRevisions?.append(contentsOf: additions.values)
        } catch {
            // Unsaved inserts would otherwise be committed by the next unrelated save().
            modelContext.rollback()
            cachedRevisions = nil
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

/// A consistent cut of the stored vault, used for export, sync and conditional writes.
public struct VaultSnapshot: Sendable {
    public let header: VaultHeader
    public let revisions: [EncryptedRevision]

    /// Uses revisions captured with this header. A conditional writer still checks the store cut.
    public init(header: VaultHeader, revisions: [EncryptedRevision]) {
        self.header = header
        self.revisions = revisions
    }
}

/// What a restore actually wrote, which may differ from the preview if the store changed meanwhile.
public struct RestoreResult: Sendable, Equatable {
    public let createdHeader: Bool
    public let insertedRevisions: Int
}
