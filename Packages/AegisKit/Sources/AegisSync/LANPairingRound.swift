import AegisCore
import CryptoKit
import Foundation

struct LANPairingHandshake {
    enum Role: UInt8 {
        case receiver = 1, sender

        var peer: Self {
            self == .receiver ? .sender : .receiver
        }
    }

    static let serviceType = "_aegis-pair._tcp"
    static let magic = Data("AEGISLN2".utf8)
    static let openingLength = 64
    private static let domain = "aegis.join.v2."

    let role: Role
    let opening: Data
    let commitment: Data
    private let key: Curve25519.KeyAgreement.PrivateKey

    init(role: Role, key: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data? = nil) throws {
        let random = try nonce ?? SecureRandom.bytes(count: 32)
        guard random.count == 32 else { throw LocalTransferError.invalidMessage }
        self.role = role
        self.key = key
        opening = key.publicKey.rawRepresentation + random
        commitment = Self.commit(role: role, opening: opening)
    }

    func validate(peerCommitment: Data, peerOpening: Data) throws {
        guard peerOpening.count == Self.openingLength, peerCommitment == Self.commit(role: role.peer, opening: peerOpening),
              peerOpening.prefix(32) != opening.prefix(32) else { throw LocalTransferError.invalidMessage }
    }

    func complete(peerCommitment: Data, peerOpening: Data) throws -> (code: String, credential: String, frames: LANSyncFrames) {
        try validate(peerCommitment: peerCommitment, peerOpening: peerOpening)
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerOpening.prefix(32))
        let secret = try key.sharedSecretFromKeyAgreement(with: peerKey)
        let transcript = role == .receiver ? commitment + peerCommitment + opening + peerOpening :
            peerCommitment + commitment + peerOpening + opening
        let digest = Data(SHA256.hash(data: Self.magic + transcript))
        func derive(_ purpose: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: digest,
                                           sharedInfo: Data((Self.domain + purpose).utf8), outputByteCount: 32)
        }
        let receiverKey = derive("receiver-to-sender")
        let senderKey = derive("sender-to-receiver")
        let frames = LANSyncFrames(outgoing: role == .receiver ? receiverKey : senderKey,
                                   incoming: role == .receiver ? senderKey : receiverKey)
        let credential = derive("abb-password").withUnsafeBytes { $0.map { String(format: "%02X", $0) }.joined() }
        return try (Self.comparisonCode(key: derive("comparison")), credential, frames)
    }

    private static func commit(role: Role, opening: Data) -> Data {
        Data(SHA256.hash(data: Data((domain + "commit").utf8) + magic + Data([role.rawValue]) + opening))
    }

    private static func comparisonCode(key: SymmetricKey) throws -> String {
        // Rejection sampling avoids favoring any of the one million display values.
        let limit = UInt64(UInt32.max) + 1
        let bound = limit - limit % 1_000_000
        for counter in UInt8(0) ..< 8 {
            let mac = Array(HMAC<SHA256>.authenticationCode(for: Data([counter]), using: key))
            for offset in stride(from: 0, to: mac.count, by: 4) {
                let value = mac[offset ..< offset + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                if value < bound {
                    return String(format: "%06d", Int(value % 1_000_000))
                }
            }
        }
        throw LocalTransferError.invalidMessage
    }
}

struct LANPairingRound {
    private enum Message: UInt8 { case receiverApproval = 1, senderApproval, length, chunk, end, receipt }
    private static let chunkLength = 65536
    static let maxFrameLength = chunkLength + 1 + LANSyncFrames.tagLength
    private let socket: any LANSyncSocket
    private let role: LANPairingHandshake.Role
    private let credential: String
    private var frames: LANSyncFrames
    let comparisonCode: String

    static func handshake(on socket: any LANSyncSocket, role: LANPairingHandshake.Role) async throws -> Self {
        let local = try LANPairingHandshake(role: role)
        let magic = LANPairingHandshake.magic
        // Each contribution is locked before the other opening becomes visible.
        if role == .receiver {
            try await socket.send(magic + local.commitment)
        }
        guard try await socket.read(magic.count) == magic else { throw LocalTransferError.invalidMessage }
        let peerCommitment = try await socket.read(32)
        if role == .sender {
            try await socket.send(magic + local.commitment)
        }
        if role == .receiver {
            try await socket.send(local.opening)
        }
        let peerOpening = try await socket.read(LANPairingHandshake.openingLength)
        let result = try local.complete(peerCommitment: peerCommitment, peerOpening: peerOpening)
        if role == .sender {
            try await socket.send(local.opening)
        }
        return Self(socket: socket, role: role, credential: result.credential, frames: result.frames, comparisonCode: result.code)
    }

    private enum ApprovalEvent: Sendable { case local, peer(Data) }

    mutating func exchangeApproval(waitForLocal: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        let socket = socket
        try await withThrowingTaskGroup(of: ApprovalEvent.self) { group in
            group.addTask {
                try await waitForLocal()
                return .local
            }
            // Keep reading while the comparison is visible so a peer rejection closes both screens.
            group.addTask { try await .peer(Self.readFrame(from: socket)) }
            for try await event in group {
                switch event {
                case .local:
                    try await send(role == .receiver ? .receiverApproval : .senderApproval)
                case let .peer(frame):
                    let expected: Message = role == .receiver ? .senderApproval : .receiverApproval
                    guard try open(frame, expecting: expected).isEmpty else { throw LocalTransferError.invalidMessage }
                }
            }
        }
    }

    static func lengthBytes(_ count: Int) throws -> Data {
        guard count > 0, count <= BackupLimits.maxFileLength else { throw LocalTransferError.invalidMessage }
        return UInt32(count).lanBytes
    }

    static func fileLength(_ bytes: Data) throws -> Int {
        // Check the announced size before reserving memory or reading chunks.
        guard bytes.count == 4 else { throw LocalTransferError.invalidMessage }
        var reader = LANSyncReader(bytes)
        let count = try Int(reader.integer(UInt32.self))
        guard count > 0, count <= BackupLimits.maxFileLength else { throw LocalTransferError.invalidMessage }
        return count
    }

    mutating func export(using export: @MainActor (String) async throws -> Data) async throws {
        let file = try await export(credential)
        try await send(.length, body: Self.lengthBytes(file.count))
        for offset in stride(from: file.startIndex, to: file.endIndex, by: Self.chunkLength) {
            try await send(.chunk, body: file[offset ..< min(offset + Self.chunkLength, file.endIndex)])
        }
        let digest = Data(SHA256.hash(data: file))
        try await send(.end, body: digest)
        guard try await receive(.receipt) == digest else { throw LocalTransferError.invalidMessage }
    }

    mutating func importSnapshot() async throws -> (Data, String) {
        let size = try await Self.fileLength(receive(.length))
        var file = Data()
        file.reserveCapacity(size)
        while file.count < size {
            let chunk = try await receive(.chunk)
            guard chunk.count == min(Self.chunkLength, size - file.count) else { throw LocalTransferError.invalidMessage }
            file.append(chunk)
        }
        let digest = Data(SHA256.hash(data: file))
        guard try await receive(.end) == digest else { throw LocalTransferError.invalidMessage }
        _ = try BackupContainer.parse(file)
        try await send(.receipt, body: digest)
        return (file, credential)
    }

    private mutating func send(_ message: Message, body: Data = Data()) async throws {
        try Task.checkCancellation()
        let frame = try frames.seal(Data([message.rawValue]) + body)
        try await socket.send(UInt32(frame.count).lanBytes + frame)
    }

    private mutating func receive(_ message: Message) async throws -> Data {
        let frame = try await Self.readFrame(from: socket)
        return try open(frame, expecting: message)
    }

    private static func readFrame(from socket: any LANSyncSocket) async throws -> Data {
        try Task.checkCancellation()
        var length = try await LANSyncReader(socket.read(4))
        let count = try Int(length.integer(UInt32.self))
        guard count > LANSyncFrames.tagLength, count <= maxFrameLength else {
            throw LocalTransferError.invalidMessage
        }
        return try await socket.read(count)
    }

    private mutating func open(_ frame: Data, expecting message: Message) throws -> Data {
        let contents = try frames.open(frame)
        guard contents.first == message.rawValue else { throw LocalTransferError.invalidMessage }
        return Data(contents.dropFirst())
    }
}
