@testable import AegisCore
import CryptoKit
import Foundation
import Testing

/// Sealing, opening and validation of ABB v1 files (Docs/BACKUP_FORMAT_DESIGN_V1.md §4–§5, §8.2, §14.2–§14.3).
@Suite(.serialized) struct BackupCryptoTests {
    private static let master = "a unique master passphrase 2026"
    private static let backupPassword = "Caf\u{E9} backup passphrase"

    private struct Vault {
        let crypto: VaultCrypto
        let header: VaultHeader
        let recoveryKey: String
        let vaultKey: Data
        let revisions: [EncryptedRevision]

        func payload(vaultKey key: Data? = nil, incomplete: Bool = false) throws -> BackupPayload {
            try BackupPayload(exportedAtMillis: 1_000, incompleteHistory: incomplete, vaultKey: key ?? vaultKey,
                              header: header, revisions: revisions)
        }
    }

    private static func makeVault() async throws -> Vault {
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: master)
        let first = try await crypto.encrypt(VaultItem(title: "Mail", username: "alice", password: "pw-1"), parents: [])
        var edited = try await crypto.decrypt(first); edited.password = "pw-2"
        let second = try await crypto.encrypt(edited, parents: [first.id])
        let other = try await crypto.encrypt(VaultItem(kind: .note, title: "Note"), parents: [])
        return Vault(crypto: crypto, header: created.header, recoveryKey: created.recoveryKey,
                     vaultKey: try await crypto.deviceKey(), revisions: [first, second, other])
    }

    private static func open(_ file: Data, _ credential: String) throws -> OpenedBackup {
        try BackupCryptor.open(try BackupContainer.parse(file), credential: credential)
    }

    // MARK: Modes and credentials

    @Test func vaultSlotOpensWithMasterPasswordOrRecoveryKey() async throws {
        let vault = try await Self.makeVault()
        let file = try BackupCryptor.seal(try vault.payload(), backupPassword: nil, includeVaultSlot: true)
        #expect(try BackupContainer.parse(file).header.slots.map(\.typeCode) == [0x02])

        let byMaster = try Self.open(file, Self.master)
        #expect(byMaster.openedWith == .masterPassword)
        #expect(byMaster.payload == (try vault.payload()))
        let byRecovery = try Self.open(file, vault.recoveryKey.lowercased())
        #expect(byRecovery.openedWith == .recoveryKey)
        #expect(throws: BackupError.wrongCredential) { try Self.open(file, "not the master passphrase") }
    }

    @Test func bothSlotsOpenWithEveryCredential() async throws {
        let vault = try await Self.makeVault()
        let file = try BackupCryptor.seal(try vault.payload(), backupPassword: Self.backupPassword, includeVaultSlot: true)
        #expect(try BackupContainer.parse(file).header.slots.map(\.typeCode) == [0x01, 0x02])

        #expect(try Self.open(file, Self.backupPassword).openedWith == .backupPassword)
        // NFD input of the same backup password opens the NFC-normalized slot (DEC-10).
        #expect(try Self.open(file, "Cafe\u{301} backup passphrase").openedWith == .backupPassword)
        #expect(try Self.open(file, Self.master).openedWith == .masterPassword)
        #expect(try Self.open(file, vault.recoveryKey).openedWith == .recoveryKey)
    }

    @Test func passwordOnlyBackupRejectsVaultCredentials() async throws {
        let vault = try await Self.makeVault()
        let file = try BackupCryptor.seal(try vault.payload(), backupPassword: Self.backupPassword, includeVaultSlot: false)
        #expect(try BackupContainer.parse(file).header.slots.map(\.typeCode) == [0x01])
        #expect(try Self.open(file, Self.backupPassword).payload == (try vault.payload()))
        #expect(throws: BackupError.wrongCredential) { try Self.open(file, Self.master) }
        #expect(throws: BackupError.wrongCredential) { try Self.open(file, vault.recoveryKey) }
        #expect(throws: BackupError.wrongCredential) { try Self.open(file, String(repeating: "x", count: 4_097)) }
    }

    @Test func backupPasswordPolicyIsEnforcedOnExport() async throws {
        let vault = try await Self.makeVault()
        #expect(throws: BackupError.malformed) {
            try BackupCryptor.seal(try vault.payload(), backupPassword: nil, includeVaultSlot: false)
        }
        #expect(throws: BackupError.passwordPolicy) {
            try BackupCryptor.seal(try vault.payload(), backupPassword: "eleven char", includeVaultSlot: false)
        }
        #expect(throws: BackupError.passwordPolicy) {
            try BackupCryptor.seal(try vault.payload(), backupPassword: String(repeating: "\u{4E2D}", count: 1_366), includeVaultSlot: false)
        }
    }

    @Test func repeatedExportsUseFreshRandomness() async throws {
        let vault = try await Self.makeVault()
        let first = try BackupCryptor.seal(try vault.payload(), backupPassword: nil, includeVaultSlot: true)
        let second = try BackupCryptor.seal(try vault.payload(), backupPassword: nil, includeVaultSlot: true)
        let a = try BackupContainer.parse(first).header, b = try BackupContainer.parse(second).header
        #expect(a.payloadNonce != b.payloadNonce)
        #expect(a.commitment != b.commitment)
        #expect(first != second)
        #expect(try Self.open(first, vault.recoveryKey).payload == (try Self.open(second, vault.recoveryKey).payload))
    }

    // MARK: Tampering

    @Test func tamperingIsClassifiedByWhatTheCredentialProves() async throws {
        let vault = try await Self.makeVault()
        let file = try BackupCryptor.seal(try vault.payload(), backupPassword: Self.backupPassword, includeVaultSlot: true)
        let recovery = vault.recoveryKey
        func flipped(_ offset: Int) -> Data { var copy = file; copy[offset] ^= 0x01; return copy }
        let tagOffset = file.count - 16
        // The recovery key proves the credential, so any later failure is tampering.
        #expect(throws: BackupError.tampered) { try Self.open(flipped(396), recovery) }          // ciphertext
        #expect(throws: BackupError.tampered) { try Self.open(flipped(tagOffset), recovery) }    // payload tag
        #expect(throws: BackupError.tampered) { try Self.open(flipped(16), recovery) }           // payload nonce
        #expect(throws: BackupError.tampered) { try Self.open(flipped(40), recovery) }           // commitment
        #expect(throws: BackupError.tampered) { try Self.open(flipped(200), recovery) }          // vault slot wrappedKey
        #expect(throws: BackupError.tampered) { try Self.open(flipped(348), recovery) }          // vault slot wrap
        #expect(throws: BackupError.tampered) { try Self.open(flipped(104), recovery) }          // password slot wrap
        // A password slot cannot tell a wrong password from an edited slot.
        #expect(throws: BackupError.wrongCredential) { try Self.open(flipped(104), Self.backupPassword) }
        // An untouched file still opens.
        #expect(try Self.open(file, recovery).openedWith == .recoveryKey)
    }

    @Test func slotsCannotBeMovedBetweenFiles() async throws {
        let vault = try await Self.makeVault()
        let target = try BackupCryptor.seal(try vault.payload(), backupPassword: nil, includeVaultSlot: true)
        let donor = try BackupCryptor.seal(try vault.payload(), backupPassword: nil, includeVaultSlot: true)
        var spliced = target
        spliced.replaceSubrange(60..<304, with: donor[60..<304])
        #expect(throws: BackupError.tampered) { try Self.open(spliced, vault.recoveryKey) }
    }

    @Test func commitmentMismatchIsTamperingEvenWhenTheSlotOpens() async throws {
        let vault = try await Self.makeVault()
        var stream = DeterministicRandom()
        let file = try BackupCryptor.seal(try vault.payload(), backupPassword: nil, includeVaultSlot: true,
                                          random: { try stream.bytes($0) })
        let fileKey = stream.history[0]
        let original = try BackupContainer.parse(file)
        guard case let .vault(header, hkdfSalt, _) = original.header.slots[0] else { Issue.record("expected vault slot"); return }
        // Re-wrap the real file key under a header whose commitment is wrong.
        let placeholder = try WrappedFileKey(nonce: Data(count: 12), ciphertext: Data(count: 32), tag: Data(count: 16))
        let forged = try BackupHeader(payloadLength: original.header.payloadLength, payloadNonce: original.header.payloadNonce,
                                      commitment: Data(repeating: 0xAB, count: 32),
                                      slots: [.vault(header: header, hkdfSalt: hkdfSalt, wrap: placeholder)])
        let wrap = try BackupCryptor.wrapFileKey(fileKey, with: BackupCryptor.vaultSlotKey(vaultKey: vault.vaultKey, salt: hkdfSalt),
                                                 nonce: Data(repeating: 7, count: 12), aad: try forged.slotAAD(at: 0))
        let rewrapped = try BackupHeader(payloadLength: forged.payloadLength, payloadNonce: forged.payloadNonce,
                                         commitment: forged.commitment, slots: [.vault(header: header, hkdfSalt: hkdfSalt, wrap: wrap)])
        let container = try BackupContainer(header: rewrapped, ciphertext: original.ciphertext, tag: original.tag)
        #expect(throws: BackupError.tampered) { try BackupCryptor.open(container, credential: vault.recoveryKey) }
    }

    @Test func selfConsistentForgedVaultKeyFailsRecordValidation() async throws {
        let vault = try await Self.makeVault()
        // An author who knows only the backup password substitutes another vault key everywhere.
        let file = try BackupCryptor.seal(try vault.payload(vaultKey: Data(repeating: 0x5A, count: 32)),
                                          backupPassword: Self.backupPassword, includeVaultSlot: true)
        let opened = try Self.open(file, Self.backupPassword)
        await #expect(throws: BackupError.invalidContent) { try await BackupValidator.validate(opened.payload) }
        // The recovery key proves the real vault key, which cannot open the forged vault slot.
        #expect(throws: BackupError.tampered) { try Self.open(file, vault.recoveryKey) }
    }

    @Test func payloadVaultKeyMustMatchTheVaultSlot() async throws {
        let vault = try await Self.makeVault()
        var stream = DeterministicRandom()
        let file = try BackupCryptor.seal(try vault.payload(), backupPassword: Self.backupPassword, includeVaultSlot: true,
                                          random: { try stream.bytes($0) })
        let original = try BackupContainer.parse(file), header = original.header
        // Re-encrypt a payload carrying a different vault key under the same header and file key.
        let plaintext = try vault.payload(vaultKey: Data(repeating: 0x5A, count: 32)).encoded()
        let sealed = try AES.GCM.seal(plaintext, using: BackupCryptor.payloadKey(for: SymmetricKey(data: stream.history[0])),
                                      nonce: AES.GCM.Nonce(data: header.payloadNonce), authenticating: header.encoded())
        let forged = try BackupContainer(header: header, ciphertext: sealed.ciphertext, tag: sealed.tag).encoded()
        #expect(throws: BackupError.invalidContent) { try Self.open(forged, Self.backupPassword) }
        #expect(throws: BackupError.invalidContent) { try Self.open(forged, vault.recoveryKey) }
    }

    // MARK: Golden vector

    private struct CryptoSpec: Decodable {
        struct Vault: Decodable {
            let vaultID: UUID; let vaultKey, salt: String; let memoryKiB, iterations, parallelism: UInt32
            let masterWrapNonce, recoveryWrapNonce: String
        }
        struct Payload: Decodable { let exportedAtMillis: Int64; let incompleteHistory: Bool }
        struct Revision: Decodable {
            let itemID, revisionID: UUID; let nonce, title, username, password: String; let modifiedAtReferenceSeconds: Double
        }
        let masterPassword, backupPassword, recoveryKey: String
        let vault: Vault; let payload: Payload; let revision: Revision
    }

    private static func goldenFile() throws -> (file: Data, spec: CryptoSpec) {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let spec = try JSONDecoder().decode(CryptoSpec.self, from: Data(contentsOf: fixtures.appendingPathComponent("abb-v1-crypto-spec.json")))
        var kdf = KDFParameters()
        kdf.memoryKiB = spec.vault.memoryKiB; kdf.iterations = spec.vault.iterations; kdf.parallelism = spec.vault.parallelism
        let vaultKey = hex(spec.vault.vaultKey), id = spec.vault.vaultID
        let masterKEK = try Argon2id.derive(password: spec.masterPassword, salt: hex(spec.vault.salt), parameters: kdf)
        let recoveryBytes = hex(spec.recoveryKey.replacingOccurrences(of: "-", with: ""))
        func wrapVaultKey(_ key: SymmetricKey, nonce: String, purpose: String) throws -> Data {
            try AES.GCM.seal(vaultKey, using: key, nonce: AES.GCM.Nonce(data: hex(nonce)),
                             authenticating: Data("aegis|key|1|\(id.uuidString)|\(purpose)".utf8)).combined!
        }
        let header = VaultHeader(vaultID: id, salt: hex(spec.vault.salt), kdf: kdf,
                                 wrappedKey: try wrapVaultKey(masterKEK, nonce: spec.vault.masterWrapNonce, purpose: "master"),
                                 recoveryWrappedKey: try wrapVaultKey(SymmetricKey(data: recoveryBytes),
                                                                      nonce: spec.vault.recoveryWrapNonce, purpose: "recovery"))
        var item = VaultItem(id: spec.revision.itemID, title: spec.revision.title, username: spec.revision.username,
                             password: spec.revision.password)
        item.modifiedAt = Date(timeIntervalSinceReferenceDate: spec.revision.modifiedAtReferenceSeconds)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let aad = EncryptedRevision.aad(vaultID: id, itemID: item.id, id: spec.revision.revisionID, parents: [])
        let sealedItem = try AES.GCM.seal(encoder.encode(item), using: SymmetricKey(data: vaultKey),
                                          nonce: AES.GCM.Nonce(data: hex(spec.revision.nonce)), authenticating: aad).combined!
        let revision = EncryptedRevision(vaultID: id, itemID: item.id, id: spec.revision.revisionID, parents: [], ciphertext: sealedItem)
        let payload = try BackupPayload(exportedAtMillis: spec.payload.exportedAtMillis, incompleteHistory: spec.payload.incompleteHistory,
                                        vaultKey: vaultKey, header: header, revisions: [revision])
        var stream = DeterministicRandom()
        let file = try BackupCryptor.seal(payload, backupPassword: spec.backupPassword, includeVaultSlot: true,
                                          random: { try stream.bytes($0) })
        return (file, spec)
    }

    @Test func goldenVectorIsStableAndOpensWithEveryCredential() async throws {
        let (file, spec) = try Self.goldenFile()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/abb-v1-crypto.bin")
        if ProcessInfo.processInfo.environment["AEGIS_RECORD_FIXTURES"] == "1" {
            try file.write(to: url)
            Issue.record("Recorded abb-v1-crypto.bin; verify it with the Python reference and rerun without AEGIS_RECORD_FIXTURES")
        } else {
            #expect(file == (try Data(contentsOf: url)), "abb-v1-crypto.bin differs from the golden fixture")
        }
        for (credential, kind) in [(spec.backupPassword, BackupCredentialKind.backupPassword),
                                   (spec.masterPassword, .masterPassword), (spec.recoveryKey, .recoveryKey)] {
            let opened = try Self.open(file, credential)
            #expect(opened.openedWith == kind)
            let entries = try await BackupValidator.validate(opened.payload)
            #expect(entries.map(\.item.title) == [spec.revision.title])
        }
    }

    // MARK: Validator

    @Test func validatorAcceptsAuthenticHistory() async throws {
        let vault = try await Self.makeVault()
        let entries = try await BackupValidator.validate(try vault.payload())
        #expect(Set(entries.map(\.item.title)) == ["Mail", "Note"])
        #expect(entries.first { $0.item.title == "Mail" }?.item.password == "pw-2")
    }

    @Test func validatorRejectsUnauthenticRecords() async throws {
        let vault = try await Self.makeVault()
        var revisions = vault.revisions
        var damaged = revisions[2].ciphertext; damaged[20] ^= 0x01
        let tampered = EncryptedRevision(vaultID: vault.header.vaultID, itemID: revisions[2].itemID, id: revisions[2].id,
                                         parents: [], ciphertext: damaged)
        let relabelled = EncryptedRevision(vaultID: vault.header.vaultID, itemID: UUID(), id: revisions[2].id,
                                           parents: [], ciphertext: revisions[2].ciphertext)
        for replacement in [tampered, relabelled] {
            revisions[2] = replacement
            let payload = try BackupPayload(exportedAtMillis: 0, incompleteHistory: false, vaultKey: vault.vaultKey,
                                            header: vault.header, revisions: revisions)
            await #expect(throws: BackupError.invalidContent) { try await BackupValidator.validate(payload) }
        }
    }

    @Test func validatorChecksTheVersionGraph() async throws {
        let vault = try await Self.makeVault()
        let key = SymmetricKey(data: vault.vaultKey), vaultID = vault.header.vaultID
        func revision(_ item: VaultItem, id: UUID, parents: [UUID]) throws -> EncryptedRevision {
            let aad = EncryptedRevision.aad(vaultID: vaultID, itemID: item.id, id: id, parents: parents)
            let sealed = try AES.GCM.seal(JSONEncoder().encode(item), using: key, authenticating: aad).combined!
            return EncryptedRevision(vaultID: vaultID, itemID: item.id, id: id, parents: parents, ciphertext: sealed)
        }
        func validate(_ revisions: [EncryptedRevision], incomplete: Bool = false) async throws -> [VaultEntry] {
            try await BackupValidator.validate(try BackupPayload(exportedAtMillis: 0, incompleteHistory: incomplete,
                                                                 vaultKey: vault.vaultKey, header: vault.header, revisions: revisions))
        }
        let item = VaultItem(title: "Looped"), a = UUID(), b = UUID(), c = UUID()
        // Two- and three-node cycles would otherwise hide the item entirely.
        await #expect(throws: BackupError.invalidContent) {
            try await validate([try revision(item, id: a, parents: [b]), try revision(item, id: b, parents: [a])])
        }
        await #expect(throws: BackupError.invalidContent) {
            try await validate([try revision(item, id: a, parents: [c]), try revision(item, id: b, parents: [a]),
                                try revision(item, id: c, parents: [b])])
        }
        // A parent from another item.
        let other = try revision(VaultItem(title: "Other"), id: c, parents: [])
        await #expect(throws: BackupError.invalidContent) { try await validate([other, try revision(item, id: a, parents: [c])]) }
        // A parent missing from the file is allowed only when the history is flagged incomplete.
        let orphan = try revision(item, id: a, parents: [UUID()])
        await #expect(throws: BackupError.invalidContent) { try await validate([orphan]) }
        #expect(try await validate([orphan], incomplete: true).map(\.item.title) == ["Looped"])
    }
}

/// The k-th byte requested is (k + 1) mod 256, matching abb-v1-crypto-spec.json.
private struct DeterministicRandom {
    private var counter = 0
    private(set) var history: [Data] = []

    mutating func bytes(_ count: Int) throws -> Data {
        let data = Data((0..<count).map { UInt8(truncatingIfNeeded: counter + $0 + 1) })
        counter += count
        history.append(data)
        return data
    }
}

private func hex(_ string: String) -> Data {
    var data = Data(), index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return data
}
