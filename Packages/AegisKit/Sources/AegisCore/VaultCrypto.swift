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
            passwordBytes.resetBytes(in: 0..<passwordBytes.count)
            output.resetBytes(in: 0..<output.count)
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
    public init() {}

    public func create(password: String) throws -> (header: VaultHeader, recoveryKey: String) {
        guard password.count >= 12 else { throw VaultError.weakMasterPassword }
        let id = UUID(), salt = try SecureRandom.bytes(count: 16), parameters = KDFParameters()
        let kek = try Argon2id.derive(password: password, salt: salt, parameters: parameters)
        var raw = try SecureRandom.bytes(count: 32)
        var recovery = try SecureRandom.bytes(count: 32)
        defer { raw.resetBytes(in: 0..<raw.count); recovery.resetBytes(in: 0..<recovery.count) }
        let wrapped = try AES.GCM.seal(raw, using: kek, authenticating: Self.keyAAD(id, "master")).combined!
        let recoveryWrapped = try AES.GCM.seal(raw, using: SymmetricKey(data: recovery),
                                              authenticating: Self.keyAAD(id, "recovery")).combined!
        let hex = recovery.map { String(format: "%02X", $0) }.joined()
        let formatted = stride(from: 0, to: 64, by: 8).map { start in
            String(hex.dropFirst(start).prefix(8))
        }.joined(separator: "-")
        key = SymmetricKey(data: raw); vaultID = id
        return (VaultHeader(vaultID: id, salt: salt, kdf: parameters, wrappedKey: wrapped,
                            recoveryWrappedKey: recoveryWrapped), formatted)
    }

    public func unlock(password: String, header: VaultHeader) throws {
        var raw = try Self.unwrapVaultKey(password: password, header: header)
        defer { raw.resetBytes(in: 0..<raw.count) }
        key = SymmetricKey(data: raw); vaultID = header.vaultID
    }

    public func recover(recoveryKey: String, header: VaultHeader) throws {
        var raw = try Self.unwrapVaultKey(recoveryKey: recoveryKey, header: header)
        defer { raw.resetBytes(in: 0..<raw.count) }
        key = SymmetricKey(data: raw); vaultID = header.vaultID
    }

    /// Returns the raw vault key wrapped by the master password without unlocking this actor.
    /// Throws `VaultError.invalidPassword` when the password does not open `header.wrappedKey`.
    static func unwrapVaultKey(password: String, header: VaultHeader) throws -> Data {
        try header.validate()
        let kek = try Argon2id.derive(password: password, salt: header.salt, parameters: header.kdf)
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: header.wrappedKey), using: kek,
                                    authenticating: keyAAD(header.vaultID, "master"))
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
        defer { recovery.resetBytes(in: 0..<recovery.count) }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: header.recoveryWrappedKey),
                                    using: SymmetricKey(data: recovery), authenticating: keyAAD(header.vaultID, "recovery"))
        } catch { throw VaultError.invalidPassword }
    }

    public func unlock(deviceKey: Data, header: VaultHeader) throws {
        try header.validate()
        guard deviceKey.count == 32 else { throw VaultError.damagedData }
        key = SymmetricKey(data: deviceKey); vaultID = header.vaultID
    }

    public func deviceKey() throws -> Data {
        guard let key else { throw VaultError.locked }
        return key.withUnsafeBytes { Data($0) }
    }

    public func lock() { key = nil; vaultID = nil }

    public func encrypt(_ item: VaultItem, parents: [UUID]) throws -> EncryptedRevision {
        guard let key, let vaultID else { throw VaultError.locked }
        let id = UUID()
        var plaintext = try JSONEncoder().encode(item)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        guard plaintext.count <= 262_144 else { throw VaultError.oversizedRecord }
        let aad = EncryptedRevision.aad(vaultID: vaultID, itemID: item.id, id: id, parents: parents)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        return EncryptedRevision(vaultID: vaultID, itemID: item.id, id: id, parents: parents, ciphertext: sealed.combined!)
    }

    public func decrypt(_ revision: EncryptedRevision) throws -> VaultItem {
        guard let key, let vaultID else { throw VaultError.locked }
        guard revision.formatVersion == 1 else { throw VaultError.unsupportedFormat }
        guard revision.vaultID == vaultID else { throw VaultError.differentVault }
        guard revision.ciphertext.count <= 300_000 else { throw VaultError.oversizedRecord }
        do {
            var plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: revision.ciphertext), using: key,
                                            authenticating: revision.authenticatedData)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            let item = try JSONDecoder().decode(VaultItem.self, from: plaintext)
            guard item.id == revision.itemID else { throw VaultError.damagedData }
            return item
        } catch { throw VaultError.damagedData }
    }

    public func entries(from revisions: [EncryptedRevision]) throws -> [VaultEntry] {
        // Authenticate every revision before its parent links may suppress another record.
        var items: [UUID: VaultItem] = [:]
        var known: [UUID: EncryptedRevision] = [:]
        for revision in revisions {
            if let existing = known[revision.id], existing != revision { throw VaultError.damagedData }
            guard !revision.parents.contains(revision.id) else { throw VaultError.damagedData }
            known[revision.id] = revision
            items[revision.id] = try decrypt(revision)
        }
        for revision in revisions {
            for parentID in revision.parents {
                if let parent = known[parentID], parent.itemID != revision.itemID { throw VaultError.damagedData }
            }
        }
        let heads = RevisionGraph.heads(in: revisions)
        let counts = Dictionary(grouping: heads, by: \.itemID).mapValues(\.count)
        return heads.compactMap { revision in
            items[revision.id].map { VaultEntry(item: $0, revision: revision, isConflict: counts[revision.itemID, default: 0] > 1) }
        }.sorted { $0.item.modifiedAt > $1.item.modifiedAt }
    }

    private static func keyAAD(_ id: UUID, _ purpose: String) -> Data {
        Data("aegis|key|1|\(id.uuidString)|\(purpose)".utf8)
    }
}
