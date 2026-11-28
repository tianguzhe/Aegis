import CArgon2
import CryptoKit
import Foundation
import Security

public enum SecureRandom {
    public static func bytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard result == errSecSuccess else { throw VaultError.randomFailure }
        return data
    }
}

public enum Argon2id {
    public static func derive(password: String, salt: Data, parameters: KDFParameters) throws -> SymmetricKey {
        try parameters.validate()
        guard salt.count == 16, password.utf8.count <= 4096 else { throw VaultError.invalidParameters }
        var passwordBytes = Data(password.utf8)
        var output = Data(count: 32)
        defer {
            passwordBytes.resetBytes(in: 0 ..< passwordBytes.count)
            output.resetBytes(in: 0 ..< output.count)
        }
        let result = output.withUnsafeMutableBytes { out in
            passwordBytes.withUnsafeBytes { pwd in
                salt.withUnsafeBytes { salt in
                    argon2id_hash_raw(parameters.iterations, parameters.memoryKiB, parameters.parallelism,
                                      pwd.baseAddress, pwd.count, salt.baseAddress, salt.count,
                                      out.baseAddress, out.count)
                }
            }
        }
        guard result == ARGON2_OK.rawValue else { throw VaultError.derivationFailed }
        return SymmetricKey(data: output)
    }
}

/// Owns the unlocked vault key on an executor separate from the UI.
public actor VaultCrypto {
    private var key: SymmetricKey?
    private var vaultID: UUID?
    private var decryptedRevisions: [UUID: (revision: EncryptedRevision, item: VaultItem)] = [:]
    /// Leaves room for the AES-GCM nonce and tag within `BackupLimits.sealedRevisionLength`.
    static let maxItemLength = 262_144
    public init() {}

    public func create(password: String) throws -> (header: VaultHeader, recoveryKey: String) {
        let password = Self.normalizedMasterPassword(password)
        guard password.count >= 12 else { throw VaultError.weakMasterPassword }
        let id = UUID(), salt = try SecureRandom.bytes(count: 16), parameters = KDFParameters()
        let kek = try Argon2id.derive(password: password, salt: salt, parameters: parameters)
        var raw = try SecureRandom.bytes(count: 32)
        var recovery = try SecureRandom.bytes(count: 32)
        defer { raw.resetBytes(in: 0 ..< raw.count); recovery.resetBytes(in: 0 ..< recovery.count) }
        let wrapped = try AES.GCM.seal(raw, using: kek, authenticating: Self.keyAAD(
            vaultID: id, salt: salt, kdf: parameters, purpose: "master"
        )).combined!
        let recoveryWrapped = try AES.GCM.seal(raw, using: SymmetricKey(data: recovery), authenticating: Self.keyAAD(
            vaultID: id, salt: salt, kdf: parameters, purpose: "recovery"
        )).combined!
        let hex = recovery.map { String(format: "%02X", $0) }.joined()
        let formatted = stride(from: 0, to: 64, by: 8).map { start in
            String(hex.dropFirst(start).prefix(8))
        }.joined(separator: "-")
        setKey(raw, vaultID: id)
        return (VaultHeader(vaultID: id, salt: salt, kdf: parameters, wrappedKey: wrapped,
                            recoveryWrappedKey: recoveryWrapped), formatted)
    }

    public func unlock(password: String, header: VaultHeader) throws {
        var raw = try Self.unwrapVaultKey(password: password, header: header)
        defer { raw.resetBytes(in: 0 ..< raw.count) }
        setKey(raw, vaultID: header.vaultID)
    }

    public func recover(recoveryKey: String, header: VaultHeader) throws {
        var raw = try Self.unwrapVaultKey(recoveryKey: recoveryKey, header: header)
        defer { raw.resetBytes(in: 0 ..< raw.count) }
        setKey(raw, vaultID: header.vaultID)
    }

    /// Returns the raw vault key wrapped by the master password without unlocking this actor.
    /// Throws `VaultError.invalidPassword` when the password does not open `header.wrappedKey`.
    static func unwrapVaultKey(password: String, header: VaultHeader) throws -> Data {
        try header.validate()
        let kek = try Argon2id.derive(password: normalizedMasterPassword(password), salt: header.salt, parameters: header.kdf)
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: header.wrappedKey), using: kek,
                                    authenticating: keyAAD(header, "master"))
        } catch { throw VaultError.invalidPassword }
    }

    /// Returns the raw vault key wrapped by the recovery key without unlocking this actor.
    /// Throws `VaultError.invalidRecoveryKey` for text that is not 64 hex digits (whitespace and
    /// hyphens ignored), and `VaultError.invalidPassword` when a well-formed key does not match.
    static func unwrapVaultKey(recoveryKey: String, header: VaultHeader) throws -> Data {
        try header.validate()
        let hex = recoveryKey.filter { !$0.isWhitespace && $0 != "-" }
        guard hex.count == 64 else { throw VaultError.invalidRecoveryKey }
        var recovery = Data()
        for offset in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(hex.dropFirst(offset).prefix(2), radix: 16) else { throw VaultError.invalidRecoveryKey }
            recovery.append(byte)
        }
        defer { recovery.resetBytes(in: 0 ..< recovery.count) }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: header.recoveryWrappedKey),
                                    using: SymmetricKey(data: recovery), authenticating: keyAAD(header, "recovery"))
        } catch { throw VaultError.invalidPassword }
    }

    /// Adopts a raw vault key stored on this device (the biometric Keychain item).
    ///
    /// The vault header holds no key check value, so a wrong key would only surface once a revision
    /// fails to decrypt; an empty vault would accept it silently and seal new records under it.
    /// `keyCheck` must come from `deviceKeyCheck(_:vaultID:)`, computed while the vault was unlocked
    /// with a verified key, and stored apart from the key itself.
    /// - Throws: `VaultError.deviceKeyMismatch` when `deviceKey` does not match `keyCheck`.
    public func unlock(deviceKey: Data, header: VaultHeader, keyCheck: Data) throws {
        guard Self.deviceKeyMatches(deviceKey, vaultID: header.vaultID, check: keyCheck) else {
            throw VaultError.deviceKeyMismatch
        }
        try unlock(verifiedKey: deviceKey, header: header)
    }

    /// Adopts a raw vault key whose source already authenticated it: an AEAD-protected backup
    /// payload, or a key generated together with `header` during rotation. Device-stored keys
    /// must use `unlock(deviceKey:header:keyCheck:)` instead.
    public func unlock(verifiedKey: Data, header: VaultHeader) throws {
        try header.validate()
        guard verifiedKey.count == 32 else { throw VaultError.damagedData }
        setKey(verifiedKey, vaultID: header.vaultID)
    }

    /// A public commitment to a 256-bit vault key; revealing it does not help guess the key.
    public static func deviceKeyCheck(_ key: Data, vaultID: UUID) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: deviceKeyCheckLabel(vaultID), using: SymmetricKey(data: key)))
    }

    static func deviceKeyMatches(_ key: Data, vaultID: UUID, check: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(check, authenticating: deviceKeyCheckLabel(vaultID), using: SymmetricKey(data: key))
    }

    private static func deviceKeyCheckLabel(_ vaultID: UUID) -> Data {
        Data("aegis|device-key-check|1|\(vaultID.uuidString)".utf8)
    }

    private func setKey(_ raw: Data, vaultID: UUID) {
        decryptedRevisions.removeAll()
        key = SymmetricKey(data: raw)
        self.vaultID = vaultID
    }

    public func deviceKey() throws -> Data {
        guard let key else { throw VaultError.locked }
        return key.withUnsafeBytes { Data($0) }
    }

    /// Derives the foreground-only LAN key without exporting the vault key.
    /// Throws when the expected vault is no longer unlocked.
    public func lanSyncKey(vaultID expected: UUID) throws -> SymmetricKey {
        guard let key, vaultID == expected else { throw VaultError.locked }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("aegis.lan.sync.v1".utf8), outputByteCount: 32)
    }

    public func lock() {
        decryptedRevisions.removeAll()
        key = nil; vaultID = nil
    }

    public func makeAutoFillSnapshot(header: VaultHeader, entries: [VaultEntry]) throws -> Data {
        guard let key, vaultID == header.vaultID else { throw VaultError.locked }
        let credentials = entries.filter(AutoFillCredential.includes).map(AutoFillCredential.init)
        var plaintext = try JSONEncoder().encode(credentials)
        defer { plaintext.resetBytes(in: 0 ..< plaintext.count) }
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: AutoFillSnapshot.authenticatedData(vaultID: header.vaultID))
        let data = try JSONEncoder().encode(AutoFillSnapshot(header: header, ciphertext: sealed.combined!))
        guard data.count <= AutoFillSnapshot.maxFileSize else { throw VaultError.oversizedRecord }
        return data
    }

    public func openAutoFillSnapshot(_ snapshot: AutoFillSnapshot) throws -> [AutoFillCredential] {
        guard snapshot.version == 1 else { throw VaultError.unsupportedFormat }
        guard let key, vaultID == snapshot.header.vaultID else { throw VaultError.locked }
        do {
            var plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: snapshot.ciphertext), using: key,
                                             authenticating: snapshot.authenticatedData)
            defer { plaintext.resetBytes(in: 0 ..< plaintext.count) }
            return try JSONDecoder().decode([AutoFillCredential].self, from: plaintext)
        } catch { throw VaultError.damagedData }
    }

    public func encrypt(_ item: VaultItem, parents: [UUID], revisionID: UUID = UUID()) throws -> EncryptedRevision {
        guard let key, let vaultID else { throw VaultError.locked }
        let id = revisionID
        var plaintext = try JSONEncoder().encode(item)
        defer { plaintext.resetBytes(in: 0 ..< plaintext.count) }
        guard plaintext.count <= Self.maxItemLength else { throw VaultError.oversizedRecord }
        let aad = EncryptedRevision.aad(vaultID: vaultID, itemID: item.id, id: id, parents: parents)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        return EncryptedRevision(vaultID: vaultID, itemID: item.id, id: id, parents: parents, ciphertext: sealed.combined!)
    }

    public func decrypt(_ revision: EncryptedRevision) throws -> VaultItem {
        guard let key, let vaultID else { throw VaultError.locked }
        guard revision.formatVersion == 1 else { throw VaultError.unsupportedFormat }
        guard revision.vaultID == vaultID else { throw VaultError.differentVault }
        guard revision.ciphertext.count <= BackupLimits.sealedRevisionLength.upperBound else { throw VaultError.oversizedRecord }
        do {
            var plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: revision.ciphertext), using: key,
                                             authenticating: revision.authenticatedData)
            defer { plaintext.resetBytes(in: 0 ..< plaintext.count) }
            let item = try JSONDecoder().decode(VaultItem.self, from: plaintext)
            guard item.id == revision.itemID else { throw VaultError.damagedData }
            return item
        } catch { throw VaultError.damagedData }
    }

    public func entries(from revisions: [EncryptedRevision]) throws -> [VaultEntry] {
        try entries(from: revisions, usingCache: false)
    }

    /// For the live store. A matching ID alone cannot authenticate a changed ciphertext or graph link.
    public func cachedEntries(from revisions: [EncryptedRevision]) throws -> [VaultEntry] {
        try entries(from: revisions, usingCache: true)
    }

    /// Authenticates the advertised snapshot and rejects invalid graph links before any exchange.
    public func validateLANSyncSnapshot(_ revisions: [EncryptedRevision]) throws {
        try VaultRevisionValidation.validateSyncSnapshot(revisions)
        _ = try cachedEntries(from: revisions)
    }

    /// Authenticates all versions in the graph that would result from the incoming batch.
    /// The caller must commit against the same local snapshot or retry with a fresh one.
    public func validateLANSyncUnion(local: [EncryptedRevision], incoming: [EncryptedRevision]) throws {
        _ = try cachedEntries(from: VaultRevisionValidation.validateSyncUnion(local: local, incoming: incoming))
    }

    /// Returns the new revisions from a confirmed ABB selection after authenticating the merged graph.
    /// - Parameters:
    ///   - local: Revisions from the destination snapshot used for the eventual commit.
    ///   - selected: Chosen revisions in destination identities, including any hidden rotation record.
    /// - Throws: `VaultError.damagedData` on inconsistent revisions or graph links, or `VaultError.locked` without a key.
    /// Commit the returned additions against the same snapshot to preserve the validated union.
    public func validateBackupMerge(local: [EncryptedRevision], selected: [EncryptedRevision]) throws -> [EncryptedRevision] {
        var known: [UUID: EncryptedRevision] = [:]
        for revision in local {
            guard known.updateValue(revision, forKey: revision.id) == nil else { throw VaultError.damagedData }
        }
        var additions: [EncryptedRevision] = []
        for revision in selected {
            if let stored = known[revision.id] {
                // Immutable versions may be repeated only when every authenticated byte matches.
                guard stored == revision else { throw VaultError.damagedData }
            } else {
                additions.append(revision)
            }
        }
        try validateLANSyncUnion(local: local, incoming: additions)
        return additions
    }

    /// Reads local history for display, reporting rejected revisions without editing the store.
    /// Throws `VaultError.locked` without an active key. This result is not valid for export or migration.
    public func localEntries(from revisions: [EncryptedRevision]) throws -> (
        entries: [VaultEntry], readableRevisionCount: Int, unreadableRevisionCount: Int
    ) {
        guard key != nil else { throw VaultError.locked }
        var authenticated: [UUID: (revision: EncryptedRevision, item: VaultItem, count: Int)] = [:]
        var conflictingOwners: [UUID: Set<UUID>] = [:]
        var unreadable = 0
        // Failed authentication cannot establish an ID collision or an item's ownership of a parent.
        for revision in revisions {
            let id = revision.id
            if authenticated[id]?.revision == revision {
                authenticated[id]?.count += 1
                continue
            }
            let item: VaultItem
            do {
                if let cached = decryptedRevisions[id], cached.revision == revision {
                    item = cached.item
                } else {
                    item = try decrypt(revision)
                }
            } catch VaultError.damagedData, VaultError.differentVault, VaultError.unsupportedFormat, VaultError.oversizedRecord {
                unreadable += 1
                continue
            }
            if let existing = authenticated[id] {
                conflictingOwners[id, default: [existing.item.id]].insert(item.id)
                authenticated[id]?.count += 1
            } else {
                authenticated[id] = (revision, item, 1)
            }
        }
        var accepted: [EncryptedRevision] = []
        var items: [UUID: VaultItem] = [:]
        for record in authenticated.values {
            let revision = record.revision
            // Validate links against the authenticated batch before dropping invalid graph nodes.
            let invalidLink = revision.parents.contains { parentID in
                if parentID == revision.id {
                    return true
                }
                if let owners = conflictingOwners[parentID] {
                    return owners.contains { $0 != record.item.id }
                }
                if let parent = authenticated[parentID] {
                    return parent.item.id != record.item.id
                }
                return false
            }
            if conflictingOwners[revision.id] != nil || invalidLink {
                unreadable += record.count
            } else {
                accepted.append(revision)
                items[revision.id] = record.item
            }
        }
        decryptedRevisions = authenticated.compactMapValues { record in
            items[record.revision.id].map { (record.revision, $0) }
        }
        return (Self.projectEntries(from: accepted, items: items), accepted.count, unreadable)
    }

    private func entries(from revisions: [EncryptedRevision], usingCache: Bool) throws -> [VaultEntry] {
        if usingCache, key == nil {
            throw VaultError.locked
        }
        // Authenticate every revision before its parent links may suppress another record.
        var items: [UUID: VaultItem] = [:]
        var known: [UUID: EncryptedRevision] = [:]
        for revision in revisions {
            if let existing = known[revision.id], existing != revision {
                throw VaultError.damagedData
            }
            guard !revision.parents.contains(revision.id) else { throw VaultError.damagedData }
            known[revision.id] = revision
            if usingCache, let cached = decryptedRevisions[revision.id], cached.revision == revision {
                items[revision.id] = cached.item
            } else {
                items[revision.id] = try decrypt(revision)
            }
        }
        for revision in revisions {
            for parentID in revision.parents {
                if let parent = known[parentID], parent.itemID != revision.itemID {
                    throw VaultError.damagedData
                }
            }
        }
        if usingCache {
            decryptedRevisions = known.compactMapValues { revision in items[revision.id].map { (revision, $0) } }
        }
        return Self.projectEntries(from: revisions, items: items)
    }

    private static func projectEntries(from revisions: [EncryptedRevision], items: [UUID: VaultItem]) -> [VaultEntry] {
        // A terminal deletion also suppresses late offline branches and stale restores.
        // Only authenticated markers may suppress an item, even when no longer a graph head.
        let deletedIDs = Set(items.values.filter { $0.permanentlyDeletedAt != nil }.map(\.id))
        let heads = RevisionGraph.heads(in: revisions).filter { !deletedIDs.contains($0.itemID) }
        let counts = Dictionary(grouping: heads, by: \.itemID).mapValues(\.count)
        return heads.compactMap { revision in
            items[revision.id].map { VaultEntry(item: $0, revision: revision, isConflict: counts[revision.itemID, default: 0] > 1) }
        }.sorted { $0.item.modifiedAt > $1.item.modifiedAt }
    }

    /// Binds each key wrap to every public header field that influences unwrapping, so a header with
    /// a swapped salt or altered KDF parameters fails authentication instead of deriving another KEK.
    /// Version 2 of this label; vaults sealed with the version 1 label (vault ID and purpose only)
    /// no longer open, which is acceptable before the first release.
    static func keyAAD(vaultID: UUID, salt: Data, kdf: KDFParameters, purpose: String) -> Data {
        let saltHex = salt.map { String(format: "%02x", $0) }.joined()
        return Data("aegis|key|2|\(vaultID.uuidString)|\(purpose)|\(saltHex)|\(kdf.memoryKiB)|\(kdf.iterations)|\(kdf.parallelism)".utf8)
    }

    private static func keyAAD(_ header: VaultHeader, _ purpose: String) -> Data {
        keyAAD(vaultID: header.vaultID, salt: header.salt, kdf: header.kdf, purpose: purpose)
    }

    /// Master passwords are NFC-normalized before key derivation so the same password typed on
    /// another platform or keyboard (composed vs. decomposed accents) derives the same KEK.
    /// Backup passwords use the same rule (`BackupCryptor`).
    static func normalizedMasterPassword(_ password: String) -> String {
        password.precomposedStringWithCanonicalMapping
    }
}
