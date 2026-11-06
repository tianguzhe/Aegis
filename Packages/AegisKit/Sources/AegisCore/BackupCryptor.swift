import CryptoKit
import Foundation

/// The credential that opened a backup; the import preview explains each differently (§4.5).
public enum BackupCredentialKind: Sendable, Equatable {
    case backupPassword, masterPassword, recoveryKey
}

/// An authenticated backup whose payload is consistent with its slots.
public struct OpenedBackup: Sendable {
    public let payload: BackupPayload
    public let openedWith: BackupCredentialKind
}

/// Seals and opens ABB v1 files (Docs/BACKUP_FORMAT_DESIGN_V1.md §4–§5).
///
/// A random 32-byte file key (FK) encrypts the payload; each slot wraps FK under a key derived
/// from one credential. Security-sensitive: changes here need review against the design doc.
public enum BackupCryptor {
    public static let minimumPasswordCharacters = 12
    public static let maximumPasswordBytes = 4_096

    private static let payloadInfo = Data("aegis.backup.v1.payload".utf8)
    private static let commitmentInfo = Data("aegis.backup.v1.commit".utf8)
    private static let vaultSlotInfo = Data("aegis.backup.v1.vault-slot".utf8)

    /// Seals `payload` into file bytes.
    ///
    /// - Parameters:
    ///   - backupPassword: Adds a password slot. Must have at least 12 characters and at most
    ///     4096 UTF-8 bytes after NFC normalization.
    ///   - includeVaultSlot: Adds a slot the master password or recovery key opens.
    /// - Throws: `BackupError.malformed` when no slot is requested, `BackupError.passwordPolicy`,
    ///   `BackupError.limitExceeded`, or a key-derivation error.
    ///   The returned bytes have already been parsed and opened again with the keys used to build them.
    public static func seal(_ payload: BackupPayload, backupPassword: String?, includeVaultSlot: Bool) throws -> Data {
        try seal(payload, backupPassword: backupPassword, includeVaultSlot: includeVaultSlot, random: SecureRandom.bytes)
    }

    /// `random` exists so tests can produce deterministic vectors; production uses `SecureRandom`.
    static func seal(_ payload: BackupPayload, backupPassword: String?, includeVaultSlot: Bool,
                     random: (Int) throws -> Data) throws -> Data {
        guard backupPassword != nil || includeVaultSlot else { throw BackupError.malformed }
        let normalizedPassword = try backupPassword.map(normalizedNewPassword)
        let plaintext = try payload.encoded()

        var fileKeyBytes = try random(32)
        defer { fileKeyBytes.resetBytes(in: 0..<fileKeyBytes.count) }
        let fileKey = SymmetricKey(data: fileKeyBytes)
        let payloadNonce = try random(BackupHeader.nonceLength)

        // Slot AADs cover everything except the wrap itself, so a placeholder wrap lets the
        // header compute them before the real wraps exist.
        let placeholder = try WrappedFileKey(nonce: Data(count: 12), ciphertext: Data(count: 32), tag: Data(count: 16))
        var draftSlots: [BackupSlot] = [], keys: [SymmetricKey] = []
        if let normalizedPassword {
            let salt = try random(BackupHeader.saltLength)
            keys.append(try Argon2id.derive(password: normalizedPassword, salt: salt, parameters: BackupLimits.passwordSlotKDF))
            draftSlots.append(.password(kdf: BackupLimits.passwordSlotKDF, salt: salt, wrap: placeholder))
        }
        if includeVaultSlot {
            let hkdfSalt = try random(BackupHeader.saltLength)
            keys.append(vaultSlotKey(vaultKey: payload.vaultKey, salt: hkdfSalt))
            draftSlots.append(.vault(header: payload.header, hkdfSalt: hkdfSalt, wrap: placeholder))
        }
        let draft = try BackupHeader(payloadLength: UInt32(plaintext.count), payloadNonce: payloadNonce,
                                     commitment: commitment(for: fileKey), slots: draftSlots)
        var slots: [BackupSlot] = []
        for (index, slot) in draftSlots.enumerated() {
            let wrap = try wrapFileKey(fileKeyBytes, with: keys[index], nonce: try random(WrappedFileKey.nonceLength),
                                       aad: try draft.slotAAD(at: index))
            switch slot {
            case let .password(kdf, salt, _): slots.append(.password(kdf: kdf, salt: salt, wrap: wrap))
            case let .vault(header, hkdfSalt, _): slots.append(.vault(header: header, hkdfSalt: hkdfSalt, wrap: wrap))
            }
        }
        let header = try BackupHeader(payloadLength: draft.payloadLength, payloadNonce: payloadNonce,
                                      commitment: draft.commitment, slots: slots)
        let sealed = try AES.GCM.seal(plaintext, using: payloadKey(for: fileKey),
                                      nonce: AES.GCM.Nonce(data: payloadNonce), authenticating: header.encoded())
        let file = try BackupContainer(header: header, ciphertext: sealed.ciphertext, tag: sealed.tag).encoded()

        // Self-check (§9): parse the bytes back and open every slot and the payload with the
        // keys that built them, so a broken file is never handed to the user.
        let reparsed = try BackupContainer.parse(file)
        for index in reparsed.header.slots.indices {
            guard let unwrapped = unwrapFileKey(in: reparsed.header, at: index, with: keys[index]),
                  constantTimeEquals(unwrapped, fileKeyBytes) else { throw BackupError.malformed }
        }
        guard try decryptPayload(reparsed, fileKey: fileKey) == payload else { throw BackupError.malformed }
        return file
    }

    /// Opens a parsed backup with the single credential the user typed (§4.3).
    ///
    /// Tries, in order: the recovery key (only when the input is shaped like one), the backup
    /// password slot, then the master password through the vault slot. Throws
    /// `BackupError.wrongCredential` when nothing opens; `tampered` or `invalidContent` when a
    /// credential is proven correct but the file fails authentication or consistency checks.
    public static func open(_ container: BackupContainer, credential input: String) throws -> OpenedBackup {
        let normalized = input.precomposedStringWithCanonicalMapping
        guard input.utf8.count <= maximumPasswordBytes, normalized.utf8.count <= maximumPasswordBytes else {
            throw BackupError.wrongCredential
        }
        let header = container.header
        let passwordIndex = header.slots.firstIndex { $0.typeCode == PasswordSlotLayout.type }
        let vaultIndex = header.slots.firstIndex { $0.typeCode == VaultSlotLayout.type }
        var vaultHeader: VaultHeader?, vaultHKDFSalt = Data()
        if let vaultIndex, case let .vault(slotHeader, hkdfSalt, _) = header.slots[vaultIndex] {
            vaultHeader = slotHeader; vaultHKDFSalt = hkdfSalt
        }

        // A vault key unwrapped from the slot's VaultHeader proves the credential; the slot wrap
        // failing afterwards means the file was modified, not that the credential was wrong.
        func openVaultSlot(_ vaultKey: Data, kind: BackupCredentialKind) throws -> OpenedBackup {
            guard let vaultIndex,
                  let fileKey = unwrapFileKey(in: header, at: vaultIndex, with: vaultSlotKey(vaultKey: vaultKey, salt: vaultHKDFSalt))
            else { throw BackupError.tampered }
            let opened = try openPayload(container, fileKey: fileKey, kind: kind)
            guard constantTimeEquals(vaultKey, opened.payload.vaultKey) else { throw BackupError.invalidContent }
            return opened
        }

        if let vaultHeader {
            do {
                var vaultKey = try VaultCrypto.unwrapVaultKey(recoveryKey: input, header: vaultHeader)
                defer { vaultKey.resetBytes(in: 0..<vaultKey.count) }
                return try openVaultSlot(vaultKey, kind: .recoveryKey)
            } catch VaultError.invalidRecoveryKey, VaultError.invalidPassword {
                // Not a recovery key, or not this vault's; try the remaining slots.
            }
        }
        if let passwordIndex, case let .password(kdf, salt, _) = header.slots[passwordIndex] {
            let key = try Argon2id.derive(password: normalized, salt: salt, parameters: kdf)
            if let fileKey = unwrapFileKey(in: header, at: passwordIndex, with: key) {
                return try openPayload(container, fileKey: fileKey, kind: .backupPassword)
            }
        }
        if let vaultHeader {
            do {
                var vaultKey = try VaultCrypto.unwrapVaultKey(password: input, header: vaultHeader)
                defer { vaultKey.resetBytes(in: 0..<vaultKey.count) }
                return try openVaultSlot(vaultKey, kind: .masterPassword)
            } catch VaultError.invalidPassword {
                // Fall through to the single wrong-credential error below.
            }
        }
        throw BackupError.wrongCredential
    }

    // MARK: - Internals

    /// Verifies the commitment, decrypts and decodes the payload, then checks it against the slots.
    private static func openPayload(_ container: BackupContainer, fileKey bytes: Data, kind: BackupCredentialKind) throws -> OpenedBackup {
        var fileKeyBytes = bytes
        defer { fileKeyBytes.resetBytes(in: 0..<fileKeyBytes.count) }
        let fileKey = SymmetricKey(data: fileKeyBytes)
        let payload = try decryptPayload(container, fileKey: fileKey)
        if let index = container.header.slots.firstIndex(where: { $0.typeCode == VaultSlotLayout.type }),
           case let .vault(slotHeader, hkdfSalt, _) = container.header.slots[index] {
            // The vault slot must describe this payload's vault and wrap this file key under its vault key.
            guard slotHeader == payload.header,
                  let unwrapped = unwrapFileKey(in: container.header, at: index,
                                                with: vaultSlotKey(vaultKey: payload.vaultKey, salt: hkdfSalt)),
                  constantTimeEquals(unwrapped, fileKeyBytes) else { throw BackupError.invalidContent }
        }
        return OpenedBackup(payload: payload, openedWith: kind)
    }

    private static func decryptPayload(_ container: BackupContainer, fileKey: SymmetricKey) throws -> BackupPayload {
        guard constantTimeEquals(commitment(for: fileKey), container.header.commitment) else { throw BackupError.tampered }
        var plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: container.header.payloadNonce),
                                            ciphertext: container.ciphertext, tag: container.tag)
            plaintext = try AES.GCM.open(box, using: payloadKey(for: fileKey), authenticating: container.header.encoded())
        } catch { throw BackupError.tampered }
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        do { return try BackupPayload.decode(plaintext) }
        catch BackupError.malformed { throw BackupError.invalidContent }
    }

    static func wrapFileKey(_ fileKey: Data, with key: SymmetricKey, nonce: Data, aad: Data) throws -> WrappedFileKey {
        let sealed = try AES.GCM.seal(fileKey, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return try WrappedFileKey(nonce: nonce, ciphertext: sealed.ciphertext, tag: sealed.tag)
    }

    /// Returns nil when authentication fails, which callers classify by context.
    private static func unwrapFileKey(in header: BackupHeader, at index: Int, with key: SymmetricKey) -> Data? {
        let wrap: WrappedFileKey
        switch header.slots[index] {
        case let .password(_, _, slotWrap), let .vault(_, _, slotWrap): wrap = slotWrap
        }
        guard let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: wrap.nonce), ciphertext: wrap.ciphertext, tag: wrap.tag)
        else { return nil }
        guard let aad = try? header.slotAAD(at: index) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: aad)
    }

    static func vaultSlotKey(vaultKey: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: vaultKey), salt: salt, info: vaultSlotInfo, outputByteCount: 32)
    }

    static func payloadKey(for fileKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: fileKey, salt: Data(), info: payloadInfo, outputByteCount: 32)
    }

    static func commitment(for fileKey: SymmetricKey) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: fileKey, salt: Data(), info: commitmentInfo, outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    /// Backup passwords are NFC-normalized so the same password typed on macOS and iOS matches.
    private static func normalizedNewPassword(_ password: String) throws -> String {
        let normalized = password.precomposedStringWithCanonicalMapping
        guard normalized.count >= minimumPasswordCharacters, normalized.utf8.count <= maximumPasswordBytes else {
            throw BackupError.passwordPolicy
        }
        return normalized
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
