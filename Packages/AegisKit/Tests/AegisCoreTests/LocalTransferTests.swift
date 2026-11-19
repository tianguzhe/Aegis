import AegisCore
import AegisStorage
@testable import AegisSync
import Foundation
import Testing

@Suite(.serialized) struct LocalTransferTests {
    private static let code = "00112233445566778899AABBCCDDEEFF"

    @Test func pairingCodeIsFullEntropyAndAcceptsPresentationSeparators() throws {
        #expect(try LocalTransferProtocol.normalizeCode(" 0011-2233-4455-6677-8899-aabb-ccdd-eeff\n") == Self.code)
        #expect(try LocalTransferProtocol.normalizeCode(LocalTransferProtocol.displayCode(Self.code)) == Self.code)
        let generated = try LocalTransferProtocol.makeCode()
        #expect(generated.count == 32)
        #expect(try LocalTransferProtocol.makeCode() != generated)
        for invalid in ["123456", String(repeating: "G", count: 32), Self.code + "0", "００１１２２３３４４５５６６７７８８９９ＡＡＢＢＣＣＤＤＥＥＦＦ"] {
            #expect(throws: LocalTransferError.invalidCode) { try LocalTransferProtocol.normalizeCode(invalid) }
        }
    }

    @Test func proofBindsChallengeDirectionAndReceivedBytes() throws {
        let challenge = Data(0 ..< 32), other = Data(repeating: 1, count: 32)
        let request = try LocalTransferProtocol.proof(code: Self.code, challenge: challenge)
        // Independent Python hashlib/hmac vector, also used by future non-Swift implementations.
        #expect(request.map { String(format: "%02x", $0) }.joined() == "728885ed911a3f4246f0730afb778b8c4da3a2285030dd85f1cd606136be06fb")
        #expect(try LocalTransferProtocol.verify(request, code: Self.code, challenge: challenge))
        #expect(try !LocalTransferProtocol.verify(request, code: Self.code, challenge: other))
        #expect(try !LocalTransferProtocol.verify(request, code: String(repeating: "F", count: 32), challenge: challenge))
        #expect(try !LocalTransferProtocol.verify(request, code: Self.code, challenge: challenge, receivedFile: Data([1])))
        let receipt = try LocalTransferProtocol.proof(code: Self.code, challenge: challenge, receivedFile: Data([1]))
        #expect(try !LocalTransferProtocol.verify(receipt, code: Self.code, challenge: challenge, receivedFile: Data([2])))
        #expect(try !LocalTransferProtocol.verify(Data(), code: Self.code, challenge: challenge))
    }

    @Test func frameLengthsAreBoundedBeforeReadingTheBody() throws {
        #expect(try LocalTransferProtocol.lengthBytes(65536) == Data([0, 1, 0, 0]))
        for count in [1, 65536, BackupLimits.maxFileLength] {
            #expect(try LocalTransferProtocol.fileLength(LocalTransferProtocol.lengthBytes(count)) == count)
        }
        for invalid in [Data(), Data([0, 0, 0]), Data([0, 0, 0, 0]), Data(repeating: 255, count: 4)] {
            #expect(throws: LocalTransferError.invalidMessage) { try LocalTransferProtocol.fileLength(invalid) }
        }
        #expect(throws: LocalTransferError.invalidMessage) { try LocalTransferProtocol.lengthBytes(BackupLimits.maxFileLength + 1) }
    }

    @Test func joiningAnEmptyDevicePreservesVaultIdentityAndBothUnlockCredentials() async throws {
        let source = VaultCrypto(), store = try VaultStore.make(inMemory: true)
        let master = "old device master password"
        let original = try await source.create(password: master)
        let revision = try await source.encrypt(VaultItem(title: "Shared vault", password: "secret"), parents: [])
        let payload = try await BackupPayload(exportedAtMillis: 0, incompleteHistory: false, vaultKey: source.deviceKey(),
                                              header: original.header, revisions: [revision])
        let file = try BackupCryptor.seal(payload, backupPassword: Self.code, includeVaultSlot: true)
        let opened = try BackupCryptor.open(BackupContainer.parse(file), credential: Self.code)
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
            try BackupCryptor.open(BackupContainer.parse(file), credential: String(repeating: "F", count: 32))
        }
    }

    /// Opt-in integration: exercises real Bonjour discovery, TCP framing, authentication and transfer.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AEGIS_TEST_LOCAL_NETWORK"] == "1"))
    @MainActor func localNetworkDiscoversAndTransfersAnEncryptedSnapshot() async throws {
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: "local network test master password")
        let payload = try await BackupPayload(exportedAtMillis: 0, incompleteHistory: false,
                                              vaultKey: crypto.deviceKey(), header: created.header, revisions: [])
        let code = try LocalTransferProtocol.makeCode()
        let file = try BackupCryptor.seal(payload, backupPassword: code, includeVaultSlot: true)
        let sender = LocalVaultTransfer(), receiver = LocalVaultTransfer()
        defer { sender.stop(); receiver.stop() }
        try sender.offer(file, code: code)
        receiver.search()
        let discoveryDeadline = Date().addingTimeInterval(15)
        while receiver.peers.first(where: { $0.name == sender.offerName }) == nil, Date() < discoveryDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let firstPeer = try #require(receiver.peers.first { $0.name == sender.offerName })
        try receiver.receive(from: firstPeer, code: code == Self.code ? String(repeating: "F", count: 32) : Self.code)
        let rejectionDeadline = Date().addingTimeInterval(5)
        while receiver.state != .failed, Date() < rejectionDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(receiver.state == .failed)
        #expect(receiver.receivedData == nil)
        #expect(sender.state == .offering)
        // A failed pairing releases the connection; the actual new device can still join.
        receiver.search()
        let retryDeadline = Date().addingTimeInterval(10)
        while receiver.peers.first(where: { $0.name == sender.offerName }) == nil, Date() < retryDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let peer = try #require(receiver.peers.first { $0.name == sender.offerName })
        try receiver.receive(from: peer, code: code)
        let transferDeadline = Date().addingTimeInterval(10)
        while receiver.state != .received, receiver.state != .failed, Date() < transferDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(receiver.receivedData == file)
        let receiptDeadline = Date().addingTimeInterval(5)
        while sender.state != .sent, Date() < receiptDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(sender.state == .sent)
        #expect(sender.pairingCode.isEmpty)
        receiver.stop()
        #expect(receiver.receivedData == nil)
        #expect(receiver.pairingCode.isEmpty)
        #expect(receiver.state == .idle)
    }
}
