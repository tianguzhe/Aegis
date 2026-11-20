import AegisCore
@testable import AegisSync
import CryptoKit
import Foundation
import Testing

@Suite(.serialized) struct LANPairingTests {
    @Test func commitmentsBindRolesAndBothPeersDeriveTheSameCode() throws {
        let receiver = try LANPairingHandshake(role: .receiver)
        let sender = try LANPairingHandshake(role: .sender)
        let left = try receiver.complete(peerCommitment: sender.commitment, peerOpening: sender.opening)
        let right = try sender.complete(peerCommitment: receiver.commitment, peerOpening: receiver.opening)
        #expect(left.code == right.code)
        #expect(left.code.count == 6)
        #expect(left.code.utf8.allSatisfy { (48 ... 57).contains($0) })
        #expect(left.credential == right.credential)
        #expect(left.credential.count == 64)
        #expect(left.frames.outgoing == right.frames.incoming)
        #expect(left.frames.outgoing != right.frames.outgoing)
        var changed = sender.opening
        changed[changed.index(before: changed.endIndex)] ^= 1
        #expect(throws: LocalTransferError.invalidMessage) {
            try receiver.complete(peerCommitment: sender.commitment, peerOpening: changed)
        }
        #expect(throws: LocalTransferError.invalidMessage) {
            try receiver.complete(peerCommitment: receiver.commitment, peerOpening: receiver.opening)
        }
    }

    @Test func snapshotLengthIsBoundedBeforeReadingChunks() throws {
        #expect(try LANPairingRound.lengthBytes(65536) == Data([0, 1, 0, 0]))
        for count in [1, 65536, BackupLimits.maxFileLength] {
            #expect(try LANPairingRound.fileLength(LANPairingRound.lengthBytes(count)) == count)
        }
        for invalid in [Data(), Data([0, 0, 0]), Data([0, 0, 0, 0]), Data(repeating: 255, count: 4)] {
            #expect(throws: LocalTransferError.invalidMessage) { try LANPairingRound.fileLength(invalid) }
        }
        #expect(throws: LocalTransferError.invalidMessage) { try LANPairingRound.lengthBytes(BackupLimits.maxFileLength + 1) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AEGIS_TEST_LOCAL_NETWORK"] == "1"))
    @MainActor func realPairingWaitsForBothConfirmationsBeforeExporting() async throws {
        let sender = LocalVaultTransfer(), receiver = LocalVaultTransfer()
        defer { sender.stop(); receiver.stop() }
        let crypto = VaultCrypto()
        let header = try await crypto.create(password: "synthetic pairing master password").header
        let payload = try await BackupPayload(exportedAtMillis: 0, incompleteHistory: false,
                                              vaultKey: crypto.deviceKey(), header: header, revisions: [])
        var exports = 0
        try sender.offerPairing { credential in
            exports += 1
            return try BackupCryptor.seal(payload, backupPassword: credential, includeVaultSlot: true)
        }
        func connect() async throws {
            receiver.search()
            let discovery = ContinuousClock.now + .seconds(15)
            while receiver.peers.first(where: { $0.name == sender.offerName }) == nil, ContinuousClock.now < discovery {
                try await Task.sleep(for: .milliseconds(100))
            }
            try receiver.receivePairing(from: #require(receiver.peers.first { $0.name == sender.offerName }))
            let handshake = ContinuousClock.now + .seconds(10)
            while sender.state != .comparing || receiver.state != .comparing, ContinuousClock.now < handshake {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(sender.state == .comparing && receiver.state == .comparing)
            #expect(sender.comparisonCode == receiver.comparisonCode)
        }

        try await connect()
        let oldComparison = sender.comparisonID
        receiver.rejectPairing(receiver.comparisonID)
        let rejected = ContinuousClock.now + .seconds(5)
        while sender.state != .offering || receiver.state != .failed, ContinuousClock.now < rejected {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(sender.state == .offering && receiver.state == .failed)
        #expect(sender.comparisonCode.isEmpty)
        #expect(exports == 0)

        try await connect()
        sender.approvePairing(oldComparison)
        #expect(sender.state == .comparing)
        sender.approvePairing(sender.comparisonID)
        #expect(sender.state == .awaitingPeer)
        #expect(exports == 0)
        #expect(receiver.takeReceivedSnapshot() == nil)
        receiver.approvePairing(receiver.comparisonID)
        let finish = ContinuousClock.now + .seconds(15)
        while receiver.state != .received || sender.state != .sent, ContinuousClock.now < finish {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(sender.state == .sent && receiver.state == .received)
        #expect(exports == 1)
        let snapshot = try #require(receiver.takeReceivedSnapshot())
        let container = try BackupContainer.parse(snapshot.data)
        let opened = try BackupCryptor.open(container, credential: snapshot.credential)
        #expect(opened.payload.header == header)
        #expect(receiver.comparisonCode.isEmpty)
        #expect(sender.comparisonCode.isEmpty)
        #expect(receiver.takeReceivedSnapshot() == nil)

        try sender.offerPairing { _ in
            exports += 1
            throw LocalTransferError.invalidMessage
        }
        for attempt in 1 ... 3 {
            try await connect()
            receiver.stop()
            let expected: LocalVaultTransfer.State = attempt == 3 ? .failed : .offering
            let deadline = ContinuousClock.now + .seconds(5)
            while sender.state != expected, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(sender.state == expected)
            #expect(sender.comparisonCode.isEmpty)
        }
        #expect(exports == 1)
        #expect(sender.offerName.isEmpty)
    }
}
