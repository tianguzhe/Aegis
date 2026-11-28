import Foundation

/// A rotated copy of a vault with new credentials and optionally compacted history.
///
/// Rotation creates a new vault ID instead of bumping an epoch, so `VaultHeader`, the ABB v1 backup
/// format and the LAN protocol stay unchanged. Revisions are moved with `BackupMigration`, whose
/// deterministic ID mapping means a backup taken before the rotation later imports as duplicates
/// of what is already stored, never as resurrected or doubled items.
///
/// Holds the raw new vault key; callers must not persist this value outside the vault store and
/// the device keychain.
public struct VaultRotation: Sendable {
    public let header: VaultHeader
    public let recoveryKey: String
    public let vaultKey: Data
    public let revisions: [EncryptedRevision]

    /// Re-encrypts `revisions` of the vault described by `header` and `vaultKey` into a new vault
    /// protected by `newPassword`. Writes nothing; the caller commits the result atomically.
    ///
    /// - Throws: `VaultError.weakMasterPassword` for a new password shorter than 12 characters,
    ///   `BackupError.invalidContent` when any source record or the version graph fails
    ///   authentication, and `VaultError.damagedData` when the re-encrypted vault does not decrypt
    ///   to exactly the same items as the source.
    public static func prepare(header: VaultHeader, revisions: [EncryptedRevision], vaultKey: Data,
                               newPassword: String, compactHistory: Bool = false) async throws -> VaultRotation
    {
        // exportedAtMillis is unused by the migration; the payload only carries the source vault.
        let source = try BackupPayload(exportedAtMillis: 0, vaultKey: vaultKey, header: header, revisions: revisions)
        // Authenticates every source record and returns the items to compare against afterwards.
        let expected = try await BackupValidator.validate(source)
        let origin = VaultCrypto(), destination = VaultCrypto()
        do {
            try await origin.unlock(verifiedKey: vaultKey, header: header)
            var lineage = try await lineage(in: revisions, using: origin)
            lineage.predecessorChain.append(header.vaultID)
            if compactHistory {
                // A compacted graph cannot accept history from any earlier namespace.
                lineage.retired.formUnion(lineage.predecessorChain)
                lineage.predecessorChain.removeAll()
            }
            let retained = compactHistory ? try await compactedRevisionIDs(source, entries: expected, crypto: origin) : nil
            await origin.lock()

            let created = try await destination.create(password: newPassword)
            let newKey = try await destination.deviceKey()
            var migrated = try await BackupMigration.migrate(source, to: created.header, key: newKey, existing: [], keeping: retained)
            // Keep the lineage in an authenticated, invisible record so exports and LAN joins
            // carry the same import boundary without a change to either container format.
            var record = TrashPolicy.deletionMarker(for: VaultItem(id: created.header.vaultID, kind: .note))
            record.rotationLineage = lineage
            try await migrated.append(destination.encrypt(record, parents: [], revisionID: record.id))
            // Never hand back a rotation that would silently lose or alter an item.
            let actual = try await destination.entries(from: migrated)
            guard try fingerprint(actual) == fingerprint(expected) else { throw VaultError.damagedData }
            await destination.lock()
            return VaultRotation(header: created.header, recoveryKey: created.recoveryKey, vaultKey: newKey,
                                 revisions: migrated)
        } catch {
            await origin.lock()
            await destination.lock()
            throw error
        }
    }

    struct Lineage: Codable, Equatable, Sendable {
        // Oldest first: an imported backup maps through every namespace after its own.
        var predecessorChain: [UUID] = []
        var retired: Set<UUID> = []
    }

    /// Both IDs are reserved to distinguish this record from user items, including deleted notes.
    static func isLineageRecord(_ revision: EncryptedRevision) -> Bool {
        revision.id == revision.vaultID && revision.itemID == revision.vaultID
    }

    static func lineage(in revisions: [EncryptedRevision], using crypto: VaultCrypto) async throws -> Lineage {
        guard let revision = revisions.first(where: isLineageRecord) else { return Lineage() }
        let record = try await crypto.decrypt(revision)
        guard revision.parents.isEmpty, record.permanentlyDeletedAt != nil, let lineage = record.rotationLineage else {
            throw VaultError.damagedData
        }
        let ancestors = Set(lineage.predecessorChain)
        guard ancestors.count == lineage.predecessorChain.count, ancestors.isDisjoint(with: lineage.retired),
              !ancestors.contains(revision.vaultID), !lineage.retired.contains(revision.vaultID)
        else { throw VaultError.damagedData }
        return lineage
    }

    private static func compactedRevisionIDs(_ source: BackupPayload, entries: [VaultEntry], crypto: VaultCrypto) async throws -> Set<UUID> {
        let visible = Set(entries.map(\.item.id))
        var kept = Set(entries.map(\.id))
        var keptDeletionMarkers: Set<UUID> = []
        for revision in source.revisions where !visible.contains(revision.itemID) && !isLineageRecord(revision) {
            try Task.checkCancellation()
            guard !keptDeletionMarkers.contains(revision.itemID) else { continue }
            if try await crypto.decrypt(revision).permanentlyDeletedAt != nil {
                keptDeletionMarkers.insert(revision.itemID)
                kept.insert(revision.id)
            }
        }
        return kept
    }

    /// Visible state of each head with item IDs removed, since the migration maps every ID.
    private static func fingerprint(_ entries: [VaultEntry]) throws -> [Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try entries.map { entry in
            var item = entry.item
            item.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            return try Data([entry.isConflict ? 1 : 0]) + (encoder.encode(item))
        }.sorted { $0.lexicographicallyPrecedes($1) }
    }
}
