@testable import AegisCore
import Foundation
import Testing

struct VaultPerformanceTests {
    private static let password = "vault performance test password"

    @Test func cachedRevisionStillRejectsChangedCiphertextAndClearsOnLock() async throws {
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: Self.password)
        let first = try await crypto.encrypt(VaultItem(title: "Before"), parents: [])
        var edited = try await crypto.decrypt(first)
        edited.title = "After"
        let second = try await crypto.encrypt(edited, parents: [first.id])

        #expect(try await crypto.cachedEntries(from: [first]).map(\.item.title) == ["Before"])
        #expect(try await crypto.cachedEntries(from: [first, second]).map(\.item.title) == ["After"])
        var ciphertext = first.ciphertext
        ciphertext[0] ^= 1
        let changed = EncryptedRevision(vaultID: first.vaultID, itemID: first.itemID, id: first.id,
                                        parents: first.parents, ciphertext: ciphertext)
        await #expect(throws: VaultError.damagedData) {
            try await crypto.cachedEntries(from: [changed, second])
        }
        await crypto.lock()
        await #expect(throws: VaultError.locked) { try await crypto.cachedEntries(from: [first, second]) }
        // Reopening with the same vault ID and a different key must never reuse plaintext.
        try await crypto.unlock(deviceKey: Data(repeating: 0, count: 32), header: created.header)
        await #expect(throws: VaultError.damagedData) { try await crypto.cachedEntries(from: [first]) }
    }

    @Test func autoFillSnapshotOnlyExposesFillFieldsFromCurrentLogins() async throws {
        let host = VaultCrypto()
        let created = try await host.create(password: Self.password)
        let old = VaultItem(title: "Example", username: "alice", password: "old", website: "example.com", notes: "Not for AutoFill")
        let oldRevision = try await host.encrypt(old, parents: [])
        var new = old
        new.password = "new"
        let current = try await host.encrypt(new, parents: [oldRevision.id])
        let card = try await host.encrypt(VaultItem(kind: .card, title: "Card"), parents: [])
        let note = try await host.encrypt(VaultItem(kind: .note, title: "Note"), parents: [])
        var trash = VaultItem(title: "Trash")
        trash.deletedAt = Date()
        let trashed = try await host.encrypt(trash, parents: [])
        let entries = try await host.entries(from: [oldRevision, current, card, note, trashed])

        let data = try await host.makeAutoFillSnapshot(header: created.header, entries: entries)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent(AutoFillSnapshot.filename))
        let snapshot = try AutoFillSnapshot.read(from: directory)
        let provider = VaultCrypto()
        try await provider.unlock(password: Self.password, header: snapshot.header)
        let logins = try await provider.openAutoFillSnapshot(snapshot)
        let credential = try #require(logins.first)
        #expect(logins.count == 1)
        #expect(credential.id == current.id && credential.password == "new")
        let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(credential)) as? [String: Any])
        #expect(Set(fields.keys) == ["id", "title", "username", "password", "website"])

        var broken = snapshot.ciphertext
        broken[0] ^= 1
        await #expect(throws: VaultError.damagedData) {
            try await provider.openAutoFillSnapshot(AutoFillSnapshot(header: snapshot.header, ciphertext: broken))
        }
    }
}
