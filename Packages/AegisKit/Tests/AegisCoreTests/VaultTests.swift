import AegisCore
import AegisStorage
import CArgon2
import CryptoKit
import Foundation
import Testing

@Suite(.serialized)
struct VaultTests {
    private let password = "a unique master passphrase 2026"

    @Test func officialArgon2idKnownAnswer() throws {
        let pwd = Data("password".utf8), salt = Data("somesalt".utf8)
        var output = Data(count: 32)
        let result = output.withUnsafeMutableBytes { out in
            pwd.withUnsafeBytes { p in salt.withUnsafeBytes { s in
                argon2id_hash_raw(2, 65536, 1, p.baseAddress, p.count, s.baseAddress, s.count, out.baseAddress, out.count)
            } }
        }
        #expect(result == 0)
        #expect(output.map { String(format: "%02x", $0) }.joined() == "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7")
    }

    @Test func vaultRoundTripAndWrongPassword() async throws {
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: password)
        let item = VaultItem(title: "私人账号", username: "me@example.com", password: "never-in-plaintext", notes: "敏感备注")
        let encrypted = try await crypto.encrypt(item, parents: [])
        #expect(try await crypto.decrypt(encrypted) == item)
        #expect(!String(decoding: encrypted.ciphertext, as: UTF8.self).contains(item.password))
        await crypto.lock()
        await #expect(throws: VaultError.self) { try await crypto.decrypt(encrypted) }
        await #expect(throws: VaultError.self) { try await crypto.unlock(password: "wrong", header: created.header) }
        try await crypto.unlock(password: password, header: created.header)
        #expect(try await crypto.decrypt(encrypted) == item)
    }

    @Test func tamperAndIdentitySwapRejected() async throws {
        let crypto = VaultCrypto()
        _ = try await crypto.create(password: password)
        let revision = try await crypto.encrypt(VaultItem(title: "Account"), parents: [])
        var altered = revision.ciphertext; altered[20] ^= 1
        let tampered = EncryptedRevision(vaultID: revision.vaultID, itemID: revision.itemID, id: revision.id, parents: [], ciphertext: altered)
        let swapped = EncryptedRevision(vaultID: revision.vaultID, itemID: UUID(), id: revision.id, parents: [], ciphertext: revision.ciphertext)
        let parents = EncryptedRevision(vaultID: revision.vaultID, itemID: revision.itemID, id: revision.id, parents: [UUID()], ciphertext: revision.ciphertext)
        await #expect(throws: VaultError.self) { try await crypto.decrypt(tampered) }
        await #expect(throws: VaultError.self) { try await crypto.decrypt(swapped) }
        await #expect(throws: VaultError.self) { try await crypto.entries(from: [parents]) }
    }

    @Test func encryptionUsesFreshNonce() async throws {
        let crypto = VaultCrypto()
        _ = try await crypto.create(password: password)
        let item = VaultItem(title: "Same")
        let first = try await crypto.encrypt(item, parents: [])
        let second = try await crypto.encrypt(item, parents: [])
        #expect(first.ciphertext.prefix(12) != second.ciphertext.prefix(12))
    }

    @Test func recoveryKeyUnlocksSameVault() async throws {
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: password)
        let revision = try await crypto.encrypt(VaultItem(title: "Recovered"), parents: [])
        await crypto.lock()
        try await crypto.recover(recoveryKey: created.recoveryKey.lowercased(), header: created.header)
        #expect(try await crypto.decrypt(revision).title == "Recovered")
        await #expect(throws: VaultError.self) { try await crypto.recover(recoveryKey: "invalid", header: created.header) }
    }

    @Test func offlineConflictsAndDeletionRemainRecoverable() async throws {
        let crypto = VaultCrypto()
        _ = try await crypto.create(password: password)
        var item = VaultItem(title: "Initial")
        let base = try await crypto.encrypt(item, parents: [])
        item.title = "Mac change"
        let mac = try await crypto.encrypt(item, parents: [base.id])
        item.title = "Phone change"
        let phone = try await crypto.encrypt(item, parents: [base.id])
        let history = [base, mac, phone]
        let conflicts = try await crypto.entries(from: history)
        #expect(conflicts.count == 2)
        #expect(conflicts.allSatisfy { $0.isConflict })
        item.deletedAt = Date()
        let resolution = try await crypto.encrypt(item, parents: [mac.id, phone.id])
        let resolved = try await crypto.entries(from: history + [resolution])
        #expect(resolved.count == 1)
        #expect(resolved.first?.item.deletedAt != nil)
        item.deletedAt = nil
        let restored = try await crypto.encrypt(item, parents: [resolution.id])
        #expect(try await crypto.entries(from: history + [resolution, restored]).first?.item.deletedAt == nil)
    }

    @Test func backupImportAndSyncAcknowledgement() async throws {
        let crypto = VaultCrypto(), first = try VaultStore.make(inMemory: true), second = try VaultStore.make(inMemory: true)
        let created = try await crypto.create(password: password)
        try await first.saveHeader(created.header)
        let revision = try await crypto.encrypt(VaultItem(title: "Saved"), parents: [])
        try await first.saveRevision(revision)
        let data = try await first.backup()
        let backup = try JSONDecoder().decode(VaultBackup.self, from: data)
        try await second.importBackup(backup)
        try await second.importBackup(backup)
        #expect(try await second.revisions().count == 1)
        for pending in try await first.pendingObjects() {
            try await first.acknowledge(name: pending.name, payload: pending.payload)
        }
        #expect(try await first.pendingObjects().isEmpty)
        #expect(try await second.pendingObjects().count == 2)
    }

    @Test func differentVaultCannotReplaceHeader() async throws {
        let crypto = VaultCrypto(), store = try VaultStore.make(inMemory: true)
        let first = try await crypto.create(password: password)
        let second = try await crypto.create(password: password)
        try await store.saveHeader(first.header)
        await #expect(throws: VaultError.self) { try await store.saveHeader(second.header) }
        let incoming = SyncObject(name: "header", kind: "header", payload: try JSONEncoder().encode(second.header))
        await #expect(throws: VaultError.self) { try await store.receive(incoming) }
        #expect(try await store.header() == first.header)
    }

    @Test func parametersAreBoundedBeforeAllocation() throws {
        var params = KDFParameters(); params.memoryKiB = UInt32.max
        #expect(throws: VaultError.self) { try Argon2id.derive(password: password, salt: Data(repeating: 0, count: 16), parameters: params) }
    }

    @Test func equivalentRecordsWithDifferentJSONOrderAreAccepted() async throws {
        let crypto = VaultCrypto(), store = try VaultStore.make(inMemory: true)
        let created = try await crypto.create(password: password)
        try await store.saveHeader(created.header)
        let revision = try await crypto.encrypt(VaultItem(title: "Order independent"), parents: [])
        try await store.saveRevision(revision)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]
        try await store.receive(SyncObject(name: "header", kind: "header", payload: encoder.encode(created.header)))
        try await store.receive(SyncObject(name: revision.id.uuidString, kind: "revision", payload: encoder.encode(revision)))
        #expect(try await store.pendingObjects().isEmpty)
        #expect(try await store.revisions().count == 1)
    }

    @Test func revisionCannotHideAnUnrelatedItem() async throws {
        let crypto = VaultCrypto()
        _ = try await crypto.create(password: password)
        let original = try await crypto.encrypt(VaultItem(title: "One"), parents: [])
        let unrelated = try await crypto.encrypt(VaultItem(title: "Two"), parents: [original.id])
        await #expect(throws: VaultError.self) { try await crypto.entries(from: [original, unrelated]) }
    }

    @Test func generatedPasswordsMeetSelectedPolicy() throws {
        var seen = Set<String>()
        for _ in 0..<100 {
            let password = try PasswordGenerator.generate()
            #expect(password.count == 16)
            #expect(password.contains { $0.isUppercase })
            #expect(password.contains { $0.isLowercase })
            #expect(password.contains { $0.isNumber })
            #expect(password.contains { !$0.isLetter && !$0.isNumber })
            seen.insert(password)
        }
        #expect(seen.count == 100)
        var options = PasswordOptions(); options.uppercase = false; options.digits = false; options.symbols = false
        #expect(try PasswordGenerator.generate(options: options).allSatisfy { $0.isLowercase })
    }

    @Test func chineseResourceBundleLoads() {
        #expect(L10n.text("action.unlock") == "解锁保险库")
        #expect(L10n.format("list.count", Int64(3)).contains("3"))
    }

    @Test func generatorPreferencesPersistAndDriveGeneration() throws {
        let suite = "AegisTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PasswordPreferences.load(from: defaults).length == 16)
        var configured = PasswordOptions()
        configured.length = 32; configured.uppercase = false; configured.symbols = false; configured.digits = false
        PasswordPreferences.save(configured, to: defaults)
        let restored = PasswordPreferences.load(from: defaults)
        #expect(restored == configured)
        let generated = try PasswordGenerator.generate(options: restored)
        #expect(generated.count == 32)
        #expect(generated.allSatisfy { $0.isLowercase })
    }
}
