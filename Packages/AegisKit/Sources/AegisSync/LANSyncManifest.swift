import AegisCore
import AegisStorage
import CryptoKit
import Foundation

struct LANSyncManifest {
    let revisions: [UUID: EncryptedRevision]
    let fingerprints: [UUID: Data]
    let digest: Data
    let headerDigest: Data
    let incomplete: Bool

    init(_ snapshot: VaultSnapshot) throws {
        try snapshot.header.validate()
        guard snapshot.revisions.count <= BackupLimits.maxRevisions else { throw LANSyncError.limitExceeded }
        var revisions: [UUID: EncryptedRevision] = [:]
        var fingerprints: [UUID: Data] = [:]
        var bytes = 0, parents = 0
        for revision in snapshot.revisions {
            try Task.checkCancellation()
            guard revision.vaultID == snapshot.header.vaultID, revisions.updateValue(revision, forKey: revision.id) == nil else {
                throw LANSyncError.conflictingRevision
            }
            let encoded = try Self.encode(revision)
            bytes += encoded.count
            parents += revision.parents.count
            guard bytes <= BackupLimits.maxPayloadLength, parents <= BackupLimits.maxTotalParents else { throw LANSyncError.limitExceeded }
            fingerprints[revision.id] = Data(SHA256.hash(data: encoded))
        }
        self.revisions = revisions
        self.fingerprints = fingerprints
        digest = Self.digest(fingerprints)
        incomplete = snapshot.hasIncompleteHistory
        let header = snapshot.header
        var bytesToHash = Data([1]) + header.vaultID.lanBytes + header.salt
        bytesToHash.append(header.kdf.memoryKiB.lanBytes)
        bytesToHash.append(header.kdf.iterations.lanBytes)
        bytesToHash.append(header.kdf.parallelism.lanBytes)
        bytesToHash.append(header.wrappedKey)
        bytesToHash.append(header.recoveryWrappedKey)
        headerDigest = Data(SHA256.hash(data: bytesToHash))
    }

    static func checkBudget(_ revisions: [EncryptedRevision]) throws {
        guard revisions.count <= BackupLimits.maxRevisions else { throw LANSyncError.limitExceeded }
        var bytes = 0, parents = 0
        for revision in revisions {
            parents += revision.parents.count
            bytes += 55 + 16 * revision.parents.count + revision.ciphertext.count
            guard bytes <= BackupLimits.maxPayloadLength, parents <= BackupLimits.maxTotalParents else { throw LANSyncError.limitExceeded }
        }
    }

    static func digest(_ fingerprints: [UUID: Data]) -> Data {
        var hash = SHA256()
        hash.update(data: UInt32(fingerprints.count).lanBytes)
        for pair in fingerprints.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            hash.update(data: pair.key.lanBytes)
            hash.update(data: pair.value)
        }
        return Data(hash.finalize())
    }

    static func fingerprint(_ revision: EncryptedRevision) throws -> Data {
        try Data(SHA256.hash(data: encode(revision)))
    }

    static func encode(_ revision: EncryptedRevision) throws -> Data {
        guard revision.parents.count <= BackupLimits.maxParentsPerRevision,
              BackupLimits.sealedRevisionLength.contains(revision.ciphertext.count) else { throw LANSyncError.limitExceeded }
        // Preserve the same representation used by Equatable and the store CAS.
        guard revision.formatVersion == 1, orderedParents(revision.parents, child: revision.id) else { throw LANSyncError.invalidMessage }
        var data = Data([1]) + revision.vaultID.lanBytes + revision.itemID.lanBytes + revision.id.lanBytes
        data.append(UInt16(revision.parents.count).lanBytes)
        for parent in revision.parents {
            data.append(parent.lanBytes)
        }
        data.append(UInt32(revision.ciphertext.count).lanBytes)
        data.append(revision.ciphertext)
        return data
    }

    static func decode(_ data: Data, vaultID: UUID) throws -> EncryptedRevision {
        var reader = LANSyncReader(data)
        guard try reader.integer(UInt8.self) == 1, try reader.uuid() == vaultID else { throw LANSyncError.invalidMessage }
        let itemID = try reader.uuid(), id = try reader.uuid()
        let count = try Int(reader.integer(UInt16.self))
        guard count <= BackupLimits.maxParentsPerRevision, count <= reader.remaining / 16 else { throw LANSyncError.limitExceeded }
        var parents: [UUID] = []
        for _ in 0 ..< count {
            try parents.append(reader.uuid())
        }
        guard orderedParents(parents, child: id) else { throw LANSyncError.invalidMessage }
        let length = try Int(reader.integer(UInt32.self))
        guard length == reader.remaining, BackupLimits.sealedRevisionLength.contains(length) else { throw LANSyncError.invalidMessage }
        return try EncryptedRevision(vaultID: vaultID, itemID: itemID, id: id, parents: parents, ciphertext: reader.bytes(length))
    }

    private static func orderedParents(_ parents: [UUID], child: UUID) -> Bool {
        !parents.contains(child) && zip(parents, parents.dropFirst()).allSatisfy { $0.0.uuidString < $0.1.uuidString }
    }
}
