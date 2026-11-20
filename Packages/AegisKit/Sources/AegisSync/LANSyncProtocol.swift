import AegisCore
import CryptoKit
import Foundation

public enum LANSyncError: Error, Equatable, Sendable {
    case authenticationFailed, invalidMessage, limitExceeded, differentVault, conflictingRevision
}

struct LANSyncHandshake {
    static let serviceType = "_aegis-sync._tcp"
    static let magic = Data("AEGISSY1".utf8)
    static let helloLength = 88
    private static let discoveryDomain = Data("aegis.lan.sync.v1.discovery".utf8)

    let instance: UUID
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let hello: Data

    init(instance: UUID) throws {
        self.instance = instance
        hello = try Self.magic + instance.lanBytes + ephemeral.publicKey.rawRepresentation + (SecureRandom.bytes(count: 32))
    }

    static func announcement(_ instance: UUID, key: SymmetricKey) -> Data {
        let bytes = instance.lanBytes
        return bytes + Data(HMAC<SHA256>.authenticationCode(for: discoveryDomain + bytes, using: key))
    }

    static func discover(_ announcement: Data, key: SymmetricKey) -> UUID? {
        guard announcement.count == 48 else { return nil }
        let bytes = Data(announcement.prefix(16))
        guard HMAC<SHA256>.isValidAuthenticationCode(announcement.suffix(32), authenticating: discoveryDomain + bytes, using: key) else { return nil }
        var reader = LANSyncReader(bytes)
        return try? reader.uuid()
    }

    struct Exchange {
        let peer: UUID
        let proof: Data
        private let peerConfirmation: Data
        private let key: SymmetricKey
        let frames: LANSyncFrames

        var expectedProof: Data {
            Data(HMAC<SHA256>.authenticationCode(for: peerConfirmation, using: key))
        }

        init(peer: UUID, proof: Data, peerConfirmation: Data, key: SymmetricKey, frames: LANSyncFrames) {
            self.peer = peer
            self.proof = proof
            self.peerConfirmation = peerConfirmation
            self.key = key
            self.frames = frames
        }

        func authenticate(_ received: Data) throws {
            guard HMAC<SHA256>.isValidAuthenticationCode(received, authenticating: peerConfirmation, using: key) else {
                throw LANSyncError.authenticationFailed
            }
        }
    }

    func exchange(with remote: Data, initiating: Bool, key: SymmetricKey) throws -> Exchange {
        guard remote.count == Self.helloLength, remote.prefix(8) == Self.magic else { throw LANSyncError.invalidMessage }
        var reader = LANSyncReader(Data(remote.dropFirst(8)))
        let peer = try reader.uuid()
        guard peer != instance else { throw LANSyncError.invalidMessage }
        let publicKey: Curve25519.KeyAgreement.PublicKey
        let secret: SharedSecret
        do {
            publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: reader.bytes(32))
            secret = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
        } catch { throw LANSyncError.authenticationFailed }
        // Both roles hash the same transcript, including fresh challenges and stable discovery identities.
        let transcript = Data(SHA256.hash(data: initiating ? hello + remote : remote + hello))
        let local = Data("aegis.lan.sync.v1.confirm.".utf8) + Data((initiating ? "initiator" : "responder").utf8) + transcript
        let confirmation = Data("aegis.lan.sync.v1.confirm.".utf8) + Data((initiating ? "responder" : "initiator").utf8) + transcript
        let proof = Data(HMAC<SHA256>.authenticationCode(for: local, using: key))
        var material = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: key.withUnsafeBytes { Data($0) },
                                                      sharedInfo: Data("aegis.lan.sync.v1.session".utf8) + transcript,
                                                      outputByteCount: 64).withUnsafeBytes { Data($0) }
        defer { material.resetBytes(in: 0 ..< material.count) }
        let outgoing = SymmetricKey(data: initiating ? material.prefix(32) : material.suffix(32))
        let incoming = SymmetricKey(data: initiating ? material.suffix(32) : material.prefix(32))
        return Exchange(peer: peer, proof: proof, peerConfirmation: confirmation, key: key,
                        frames: LANSyncFrames(outgoing: outgoing, incoming: incoming))
    }
}

struct LANSyncFrames {
    static let maxLength = 1_048_576
    static let tagLength = 16
    let outgoing: SymmetricKey
    let incoming: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    init(outgoing: SymmetricKey, incoming: SymmetricKey) {
        self.outgoing = outgoing
        self.incoming = incoming
    }

    mutating func seal(_ message: Data) throws -> Data {
        guard !message.isEmpty, message.count <= Self.maxLength - Self.tagLength, sent < UInt64.max else {
            throw LANSyncError.limitExceeded
        }
        let box = try ChaChaPoly.seal(message, using: outgoing, nonce: Self.nonce(sent))
        sent += 1
        return box.ciphertext + box.tag
    }

    mutating func open(_ frame: Data) throws -> Data {
        guard frame.count > Self.tagLength, frame.count <= Self.maxLength, received < UInt64.max else {
            throw LANSyncError.limitExceeded
        }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(received), ciphertext: frame.dropLast(Self.tagLength), tag: frame.suffix(Self.tagLength))
            let message = try ChaChaPoly.open(box, using: incoming)
            received += 1
            return message
        } catch { throw LANSyncError.invalidMessage }
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        // Only the expected sequence can authenticate, and each direction has a different key.
        try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + counter.lanBytes)
    }
}

extension FixedWidthInteger {
    var lanBytes: Data {
        withUnsafeBytes(of: bigEndian) { Data($0) }
    }
}

extension UUID {
    var lanBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}

struct LANSyncReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var remaining: Int {
        data.endIndex - offset
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw LANSyncError.invalidMessage }
        defer { offset += count }
        return Data(data[offset ..< offset + count])
    }

    mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        try bytes(MemoryLayout<T>.size).reduce(0) { ($0 << 8) | T($1) }
    }

    mutating func uuid() throws -> UUID {
        let raw = try [UInt8](bytes(16))
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                           raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }
}
