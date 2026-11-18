import CryptoKit
import Foundation

/// Re-encrypts another vault's authenticated history without replacing the destination vault.
public enum BackupMigration {
    public static func revisions(from payload: BackupPayload, to header: VaultHeader, key: Data,
                                 existing: [EncryptedRevision]) async throws -> [EncryptedRevision] {
        guard payload.header.vaultID != header.vaultID else { throw VaultError.differentVault }
        // Authenticate all source records and the graph before preparing any destination records.
        _ = try await BackupValidator.validate(payload)
        let source = VaultCrypto(), destination = VaultCrypto()
        do {
            try await source.unlock(deviceKey: payload.vaultKey, header: payload.header)
            try await destination.unlock(deviceKey: key, header: header)
            let known = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            var migrated: [EncryptedRevision] = []
            for revision in payload.revisions {
                try Task.checkCancellation()
                var item = try await source.decrypt(revision)
                item.id = mappedID(item.id, kind: "item", source: payload.header.vaultID, destination: header.vaultID)
                let id = mappedID(revision.id, kind: "revision", source: payload.header.vaultID, destination: header.vaultID)
                let parents = revision.parents.map {
                    mappedID($0, kind: "revision", source: payload.header.vaultID, destination: header.vaultID)
                }
                if let stored = known[id] {
                    // Reuse the authenticated ciphertext: a new random nonce would make an
                    // otherwise identical immutable revision conflict on repeated imports.
                    let storedItem = try await destination.decrypt(stored)
                    guard storedItem == item, stored.itemID == item.id,
                          Set(stored.parents) == Set(parents) else { throw VaultError.damagedData }
                    migrated.append(stored)
                } else {
                    migrated.append(try await destination.encrypt(item, parents: parents, revisionID: id))
                }
            }
            await source.lock(); await destination.lock()
            return migrated
        } catch {
            await source.lock(); await destination.lock()
            throw error
        }
    }

    /// Separate namespaces preserve graph links (including missing parents) and isolate local IDs.
    private static func mappedID(_ id: UUID, kind: String, source: UUID, destination: UUID) -> UUID {
        let context = "aegis|backup-migration|1|\(source.uuidString)|\(destination.uuidString)|\(kind)|\(id.uuidString)"
        var bytes = Array(SHA256.hash(data: Data(context.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // UUID v8 (application-defined), RFC 9562 variant.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
