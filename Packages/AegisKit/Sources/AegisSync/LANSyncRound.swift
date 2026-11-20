import AegisCore
import AegisStorage
import CryptoKit
import Foundation

protocol LANSyncSocket: Sendable {
    func send(_ data: Data) async throws
    func read(_ count: Int) async throws -> Data
}

struct LANSyncRound {
    typealias Snapshot = @Sendable () async throws -> VaultSnapshot
    typealias Apply = @Sendable (VaultSnapshot, [EncryptedRevision], Set<UUID>, Bool) async throws -> Void

    private enum Message: UInt8 { case hello = 1, manifest, revision, end, done }
    private static let manifestChunk = 1024

    let socket: any LANSyncSocket
    let initiating: Bool
    private var frames: LANSyncFrames

    static func authenticate(socket: any LANSyncSocket, instance: UUID, expectedPeer: UUID?, key: SymmetricKey) async throws -> Self {
        let handshake = try LANSyncHandshake(instance: instance)
        let initiating = expectedPeer != nil
        if initiating {
            try await socket.send(handshake.hello)
        }
        let remote = try await socket.read(LANSyncHandshake.helloLength)
        let exchange = try handshake.exchange(with: remote, initiating: initiating, key: key)
        // Both devices enforce the same preference, including when only one has resolved endpoints.
        if let expectedPeer {
            guard expectedPeer == exchange.peer, instance.uuidString < expectedPeer.uuidString else { throw LANSyncError.authenticationFailed }
            try await socket.send(exchange.proof)
            try await exchange.authenticate(socket.read(32))
        } else {
            guard exchange.peer.uuidString < instance.uuidString else { throw LANSyncError.authenticationFailed }
            try await socket.send(handshake.hello)
            try await exchange.authenticate(socket.read(32))
            try await socket.send(exchange.proof)
        }
        return Self(socket: socket, initiating: initiating, frames: exchange.frames)
    }

    mutating func run(snapshot: Snapshot, apply: Apply) async throws {
        let local = try await snapshot()
        let manifest = try LANSyncManifest(local)
        let hello = manifest.headerDigest + manifest.digest + UInt32(manifest.revisions.count).lanBytes + Data([manifest.incomplete ? 1 : 0])
        if initiating {
            try await send(.hello, body: hello)
        }
        var reader = try await LANSyncReader(receive(.hello))
        guard try reader.bytes(32) == manifest.headerDigest else { throw LANSyncError.differentVault }
        let digest = try reader.bytes(32)
        let count = try Int(reader.integer(UInt32.self))
        let flag = try reader.integer(UInt8.self)
        guard count <= BackupLimits.maxRevisions, flag <= 1, reader.remaining == 0 else { throw LANSyncError.invalidMessage }
        if !initiating {
            try await send(.hello, body: hello)
        }

        if digest == manifest.digest {
            guard count == manifest.revisions.count, (flag == 1) == manifest.incomplete else { throw LANSyncError.invalidMessage }
            try await apply(local, [], Set(manifest.revisions.keys), flag == 1)
        } else {
            if initiating {
                try await sendManifest(manifest.fingerprints)
            }
            let remote = try await receiveManifest(count: count)
            guard LANSyncManifest.digest(remote) == digest else { throw LANSyncError.invalidMessage }
            if !initiating {
                try await sendManifest(manifest.fingerprints)
            }
            for (id, hash) in remote {
                if let localHash = manifest.fingerprints[id], hash != localHash {
                    throw LANSyncError.conflictingRevision
                }
            }
            let outgoing = manifest.revisions.values.filter { remote[$0.id] == nil }
            let expected = remote.filter { manifest.fingerprints[$0.key] == nil }
            // One role sends while the other reads, so large datasets cannot deadlock on TCP backpressure.
            if initiating {
                try await sendRevisions(outgoing)
            }
            let incoming = try await receiveRevisions(expected: expected, vaultID: local.header.vaultID)
            if !initiating {
                try await sendRevisions(outgoing)
            }
            // Keep the merged vault within the same limits needed for its next exchange.
            try LANSyncManifest.checkBudget(local.revisions + incoming)
            try await apply(local, incoming, Set(remote.keys), flag == 1)
        }

        if initiating {
            try await send(.done)
        }
        guard try await receive(.done).isEmpty else { throw LANSyncError.invalidMessage }
        if !initiating {
            try await send(.done)
        }
    }

    private mutating func sendManifest(_ manifest: [UUID: Data]) async throws {
        let ordered = manifest.sorted { $0.key.uuidString < $1.key.uuidString }
        for offset in stride(from: 0, to: ordered.count, by: Self.manifestChunk) {
            var bytes = Data()
            for (id, hash) in ordered[offset ..< min(offset + Self.manifestChunk, ordered.count)] {
                bytes.append(id.lanBytes); bytes.append(hash)
            }
            try await send(.manifest, body: bytes)
        }
    }

    private mutating func receiveManifest(count: Int) async throws -> [UUID: Data] {
        var result: [UUID: Data] = [:]
        var previous: String?
        for offset in stride(from: 0, to: count, by: Self.manifestChunk) {
            let size = min(Self.manifestChunk, count - offset)
            let data = try await receive(.manifest)
            guard data.count == size * 48 else { throw LANSyncError.invalidMessage }
            var reader = LANSyncReader(data)
            for _ in 0 ..< size {
                let id = try reader.uuid()
                let order = id.uuidString
                guard previous.map({ $0 < order }) ?? true else { throw LANSyncError.invalidMessage }
                result[id] = try reader.bytes(32)
                previous = order
            }
        }
        return result
    }

    private mutating func sendRevisions(_ revisions: [EncryptedRevision]) async throws {
        for revision in revisions {
            try await send(.revision, body: LANSyncManifest.encode(revision))
        }
        try await send(.end)
    }

    private mutating func receiveRevisions(expected: [UUID: Data], vaultID: UUID) async throws -> [EncryptedRevision] {
        var remaining = expected
        var revisions: [EncryptedRevision] = []
        var bytes = 0, parents = 0
        for _ in 0 ..< expected.count {
            let body = try await receive(.revision)
            bytes += body.count
            guard bytes <= BackupLimits.maxPayloadLength else { throw LANSyncError.limitExceeded }
            let revision = try LANSyncManifest.decode(body, vaultID: vaultID)
            parents += revision.parents.count
            guard parents <= BackupLimits.maxTotalParents else { throw LANSyncError.limitExceeded }
            guard remaining.removeValue(forKey: revision.id) == Data(SHA256.hash(data: body)) else { throw LANSyncError.invalidMessage }
            revisions.append(revision)
        }
        guard try await receive(.end).isEmpty else { throw LANSyncError.invalidMessage }
        return revisions
    }

    private mutating func send(_ message: Message, body: Data = Data()) async throws {
        try Task.checkCancellation()
        let frame = try frames.seal(Data([message.rawValue]) + body)
        try await socket.send(UInt32(frame.count).lanBytes + frame)
    }

    private mutating func receive(_ expected: Message) async throws -> Data {
        try Task.checkCancellation()
        var length = try await LANSyncReader(socket.read(4))
        let count = try Int(length.integer(UInt32.self))
        guard count > LANSyncFrames.tagLength, count <= LANSyncFrames.maxLength else { throw LANSyncError.limitExceeded }
        let frame = try await socket.read(count)
        let message = try frames.open(frame)
        guard message.first == expected.rawValue else { throw LANSyncError.invalidMessage }
        return message.dropFirst()
    }
}
