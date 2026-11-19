import Foundation

/// A rotated copy of a vault: new identity, vault key, master password and recovery key, with the
/// complete history re-encrypted (Docs/KEY_ROTATION_DESIGN.md §2–§3).
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
    /// - Parameter incompleteHistory: true when some parents were never received on this device.
    /// - Throws: `VaultError.weakMasterPassword` for a new password shorter than 12 characters,
    ///   `BackupError.invalidContent` when any source record or the version graph fails
    ///   authentication, and `VaultError.damagedData` when the re-encrypted vault does not decrypt
    ///   to exactly the same items as the source.
    public static func prepare(header: VaultHeader, revisions: [EncryptedRevision], incompleteHistory: Bool,
                               vaultKey: Data, newPassword: String) async throws -> VaultRotation
    {
        // exportedAtMillis is unused by the migration; the payload only carries the source vault.
        let source = try BackupPayload(exportedAtMillis: 0, incompleteHistory: incompleteHistory, vaultKey: vaultKey,
                                       header: header, revisions: revisions)
        // Authenticates every source record and returns the items to compare against afterwards.
        let expected = try await BackupValidator.validate(source)
        let destination = VaultCrypto()
        do {
            let created = try await destination.create(password: newPassword)
            let newKey = try await destination.deviceKey()
            let migrated = try await BackupMigration.revisions(from: source, to: created.header, key: newKey, existing: [])
            // Never hand back a rotation that would silently lose or alter an item.
            let actual = try await destination.entries(from: migrated)
            guard try fingerprint(actual) == fingerprint(expected) else { throw VaultError.damagedData }
            await destination.lock()
            return VaultRotation(header: created.header, recoveryKey: created.recoveryKey, vaultKey: newKey,
                                 revisions: migrated)
        } catch {
            await destination.lock()
            throw error
        }
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
