import AegisCore
import AegisStorage
@testable import AegisSync
import Testing

struct LocalTransferTests {
    @Test func joiningAnEmptyDevicePreservesVaultIdentityAndBothUnlockCredentials() async throws {
        let source = VaultCrypto(), store = try VaultStore.make(inMemory: true)
        let master = "old device master password"
        let original = try await source.create(password: master)
        let revision = try await source.encrypt(VaultItem(title: "Shared vault", password: "secret"), parents: [])
        let payload = try await BackupPayload(exportedAtMillis: 0, incompleteHistory: false, vaultKey: source.deviceKey(),
                                              header: original.header, revisions: [revision])
        let sender = try LANPairingHandshake(role: .sender), receiver = try LANPairingHandshake(role: .receiver)
        let outgoing = try sender.complete(peerCommitment: receiver.commitment, peerOpening: receiver.opening)
        let incoming = try receiver.complete(peerCommitment: sender.commitment, peerOpening: sender.opening)
        let file = try BackupCryptor.seal(payload, backupPassword: outgoing.credential, includeVaultSlot: true)
        let container = try BackupContainer.parse(file)
        let opened = try BackupCryptor.open(container, credential: incoming.credential)
        _ = try await BackupValidator.validate(opened.payload)
        #expect(try await store.header() == nil)
        #expect(try await store.restoreNewVault(header: opened.payload.header, revisions: opened.payload.revisions).createdHeader)
        #expect(try await store.header() == original.header)
        #expect(try await store.revisions() == [revision])
        let joined = VaultCrypto()
        try await joined.unlock(password: master, header: opened.payload.header)
        #expect(try await joined.deviceKey() == payload.vaultKey)
        await joined.lock()
        try await joined.recover(recoveryKey: original.recoveryKey, header: opened.payload.header)
        #expect(try await joined.entries(from: store.revisions()).first?.item.password == "secret")
        await #expect(throws: VaultError.differentVault) {
            try await store.restoreNewVault(header: opened.payload.header, revisions: [])
        }
        #expect(try await store.revisions() == [revision])
        #expect(throws: BackupError.wrongCredential) {
            try BackupCryptor.open(container, credential: incoming.code)
        }
    }
}
