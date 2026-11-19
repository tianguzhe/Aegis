import AegisCore
@testable import AegisStorage
import CArgon2
import CryptoKit
import Foundation
import Testing

@Suite(.serialized)
struct VaultTests {
    private let password = "a unique master passphrase 2026"

    @Test func officialArgon2idKnownAnswer() {
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

    @Test func trashExpiresAfterSevenDaysAndPreservesActiveConflicts() async throws {
        let crypto = VaultCrypto()
        _ = try await crypto.create(password: password)
        let deleted = Date(timeIntervalSince1970: 1_800_000_000)
        var item = VaultItem(title: "Trash")
        item.deletedAt = deleted
        let revision = try await crypto.encrypt(item, parents: [])
        let entries = try await crypto.entries(from: [revision])
        let deadline = deleted.addingTimeInterval(7 * 24 * 60 * 60)
        #expect(TrashPolicy.expirationDate(for: item) == deadline)
        #expect(TrashPolicy.expiredGroups(in: entries, now: deadline.addingTimeInterval(-1)).isEmpty)
        #expect(TrashPolicy.expiredGroups(in: entries, now: deadline).count == 1)

        item.deletedAt = nil
        let active = try await crypto.encrypt(item, parents: [])
        let conflict = try await crypto.entries(from: [revision, active])
        #expect(TrashPolicy.expiredGroups(in: conflict, now: deadline).isEmpty)
        item.deletedAt = deleted.addingTimeInterval(60)
        let recent = try await crypto.encrypt(item, parents: [])
        let bothTrashed = try await crypto.entries(from: [revision, recent])
        #expect(TrashPolicy.expiredGroups(in: bothTrashed, now: deadline).isEmpty)
        #expect(TrashPolicy.expiredGroups(in: bothTrashed, now: deadline.addingTimeInterval(60)).first?.count == 2)
    }

    @Test func terminalDeletionSurvivesTransferAndOldBackupMerge() async throws {
        let crypto = VaultCrypto(), source = try VaultStore.make(inMemory: true), target = try VaultStore.make(inMemory: true)
        let created = try await crypto.create(password: password)
        try await source.saveHeader(created.header)
        var item = VaultItem(title: "Deleted", username: "User", password: "Secret", notes: "Private")
        let original = try await crypto.encrypt(item, parents: [])
        item.deletedAt = Date()
        let trashed = try await crypto.encrypt(item, parents: [original.id])
        let marker = TrashPolicy.deletionMarker(for: item)
        #expect(marker.title.isEmpty && marker.username.isEmpty && marker.password.isEmpty && marker.notes.isEmpty)
        let deleted = try await crypto.encrypt(marker, parents: [trashed.id])
        for revision in [original, trashed, deleted] {
            try await source.saveRevision(revision)
        }
        try await target.restore(header: created.header, revisions: source.snapshot().revisions)
        #expect(try await crypto.entries(from: target.revisions()).isEmpty)

        item.deletedAt = nil
        let offlineRestore = try await crypto.encrypt(item, parents: [trashed.id])
        let staleDescendant = try await crypto.encrypt(item, parents: [deleted.id])
        let unrelated = try await crypto.encrypt(VaultItem(title: "Keep"), parents: [])
        try await target.restore(header: created.header, revisions: [original, offlineRestore, staleDescendant, unrelated])
        let remaining = try await crypto.entries(from: target.revisions())
        #expect(remaining.count == 1)
        #expect(remaining.first?.item.title == "Keep")
    }

    @Test func legacyItemsDecodeWithoutTerminalDeletionField() throws {
        let item = VaultItem(title: "Legacy")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json.removeValue(forKey: "permanentlyDeletedAt")
        let decoded = try JSONDecoder().decode(VaultItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.permanentlyDeletedAt == nil)
        #expect(decoded == item)
    }

    @Test func repeatedRestoreIsIdempotent() async throws {
        let crypto = VaultCrypto(), first = try VaultStore.make(inMemory: true), second = try VaultStore.make(inMemory: true)
        let created = try await crypto.create(password: password)
        try await first.saveHeader(created.header)
        let revision = try await crypto.encrypt(VaultItem(title: "Saved"), parents: [])
        try await first.saveRevision(revision)
        let snapshot = try await first.snapshot()
        try await second.restore(header: snapshot.header, revisions: snapshot.revisions)
        try await second.restore(header: snapshot.header, revisions: snapshot.revisions)
        #expect(try await second.revisions().count == 1)
    }

    @Test func failedImportSaveDoesNotLeakIntoLaterSaves() async throws {
        let crypto = VaultCrypto(), source = try VaultStore.make(inMemory: true)
        let created = try await crypto.create(password: password)
        try await source.saveHeader(created.header)
        try await source.saveRevision(crypto.encrypt(VaultItem(title: "Imported"), parents: []))
        let backup = try await JSONDecoder().decode(VaultBackup.self, from: source.backup())

        struct InjectedCommitFailure: Error {}
        let target = try VaultStore.make(inMemory: true)
        await #expect(throws: InjectedCommitFailure.self) {
            try await target.restore(header: backup.header, revisions: backup.revisions, beforeSave: { throw InjectedCommitFailure() })
        }

        #expect(try await target.header() == nil)
        // An unrelated later save must not commit the rolled-back revision inserts.
        try await target.saveHeader(backup.header)
        #expect(try await target.revisions().isEmpty)
    }

    @Test func differentVaultCannotReplaceHeader() async throws {
        let crypto = VaultCrypto(), store = try VaultStore.make(inMemory: true)
        let first = try await crypto.create(password: password)
        let second = try await crypto.create(password: password)
        try await store.saveHeader(first.header)
        await #expect(throws: VaultError.self) { try await store.saveHeader(second.header) }
        #expect(try await store.header() == first.header)
    }

    @Test func parametersAreBoundedBeforeAllocation() throws {
        var params = KDFParameters(); params.memoryKiB = UInt32.max
        #expect(throws: VaultError.self) { try Argon2id.derive(password: password, salt: Data(repeating: 0, count: 16), parameters: params) }
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
        for _ in 0 ..< 100 {
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
