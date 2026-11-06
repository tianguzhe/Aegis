import AegisCore
import AegisStorage
import CryptoKit
import Foundation
import Testing

@MainActor
struct LocalVaultStateTests {
    @Test func draftsAndRecoverySurviveLockAndProcessRecreationAsCiphertext() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID(), key = Data(repeating: 7, count: 32)
        let store = LocalVaultStateStore(directory: folder)
        try store.unlock(key: key, vaultID: id)
        var state = LocalVaultState()
        var draft = VaultDraft(item: VaultItem(title: "Draft"), parents: [UUID()])
        draft.item.notes = "Secret draft survives interruptions"
        state.retain(draft)
        state.pendingRecoveryKey = "SYNTHETIC-RECOVERY-SECRET"
        try store.write(state)
        store.lock()
        #expect(store.state.drafts.isEmpty)
        #expect(store.state.pendingRecoveryKey == nil)
        let url = folder.appendingPathComponent("local-state-\(id.uuidString).aegis")
        let encrypted = try Data(contentsOf: url)
        #expect(!String(decoding: encrypted, as: UTF8.self).contains("Secret draft"))
        #expect(!String(decoding: encrypted, as: UTF8.self).contains("SYNTHETIC"))

        let reopened = LocalVaultStateStore(directory: folder)
        try reopened.unlock(key: key, vaultID: id)
        #expect(reopened.state == state)
        var confirmed = reopened.state
        confirmed.pendingRecoveryKey = nil
        confirmed.drafts = []
        try reopened.write(confirmed)
        reopened.lock()
        try reopened.unlock(key: key, vaultID: id)
        #expect(reopened.state.drafts.isEmpty)
        #expect(reopened.state.pendingRecoveryKey == nil)
    }

    @Test func auxiliaryDataAuthenticatesVaultIdentityAndRejectsTampering() throws {
        let key = SymmetricKey(size: .bits256), id = UUID()
        var state = LocalVaultState(); state.pendingRecoveryKey = "synthetic"
        let ciphertext = try LocalVaultStateCipher.seal(state, key: key, vaultID: id)
        #expect(throws: (any Error).self) { try LocalVaultStateCipher.open(ciphertext, key: key, vaultID: UUID()) }
        var tampered = ciphertext; tampered[tampered.count - 1] ^= 1
        #expect(throws: (any Error).self) { try LocalVaultStateCipher.open(tampered, key: key, vaultID: id) }
    }

    @Test func unmodifiedAndDiscardedDraftsAreNotOfferedForRecovery() {
        var state = LocalVaultState()
        var draft = VaultDraft(item: VaultItem(title: "Original"), parents: [])
        state.retain(draft)
        #expect(state.drafts.isEmpty)
        draft.item.notes = "changed"
        state.retain(draft)
        state.retain(draft)
        #expect(state.drafts.count == 1)
        draft.item = draft.original
        state.retain(draft)
        #expect(state.drafts.isEmpty)
    }
}
