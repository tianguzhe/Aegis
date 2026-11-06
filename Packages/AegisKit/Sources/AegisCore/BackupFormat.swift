import Foundation

// Byte layout of the ABB v1 backup file. Docs/BACKUP_FORMAT_DESIGN_V1.md §6–§8 is the
// normative specification; this file only encodes and parses bytes and never handles
// key derivation or encryption.

/// Failures while reading or writing ABB v1 bytes; each case maps to distinct user guidance.
public enum BackupError: Error, LocalizedError, Sendable, Equatable {
    /// The bytes do not start with the ABB magic value.
    case notABackup
    /// A newer format version this build cannot read.
    case unsupportedVersion
    /// Lengths, reserved bytes, ordering or other structure is invalid.
    case malformed
    /// KDF parameters outside the supported set.
    case unsupportedParameters
    /// The file exceeds the resource limits shared by import and export.
    case limitExceeded
    /// No slot opened. Includes edits to the fixed header, which every slot authenticates.
    case wrongCredential
    /// A slot opened but the commitment, a slot proven by the credential, or the payload failed authentication.
    case tampered
    /// The payload decrypted but its vault identity, keys, records or version graph are inconsistent.
    case invalidContent
    /// A new backup password is shorter than 12 characters or longer than 4096 UTF-8 bytes.
    case passwordPolicy

    public var errorDescription: String? {
        switch self {
        case .notABackup: L10n.text("backup.error.notABackup")
        case .unsupportedVersion: L10n.text("backup.error.unsupportedVersion")
        case .malformed: L10n.text("backup.error.malformed")
        case .unsupportedParameters: L10n.text("backup.error.unsupportedParameters")
        case .limitExceeded: L10n.text("backup.error.limitExceeded")
        case .wrongCredential: L10n.text("backup.error.wrongCredential")
        case .tampered: L10n.text("backup.error.tampered")
        case .invalidContent: L10n.text("backup.error.invalidContent")
        case .passwordPolicy: L10n.text("backup.error.passwordPolicy")
        }
    }
}

/// Resource limits shared by export and import, so export never writes a file import rejects.
public enum BackupLimits {
    /// Payload plaintext is padded to a multiple of this, hiding the approximate record count.
    public static let paddingBlock = 65_536
    public static let maxPayloadLength = 33_554_432
    public static let maxRevisions = 100_000
    public static let maxParentsPerRevision = 1_000
    public static let maxTotalParents = 250_000
    public static let sealedRevisionLength = 28...300_000
    /// Largest possible file: fixed header, both slots, maximum payload and its tag.
    public static let maxFileLength = BackupHeader.fixedLength + PasswordSlotLayout.length + VaultSlotLayout.length
        + maxPayloadLength + BackupContainer.tagLength

    /// The only Argon2id profile a password slot may declare in format version 1.
    public static var passwordSlotKDF: KDFParameters {
        var parameters = KDFParameters()
        parameters.memoryKiB = 65_536; parameters.iterations = 3; parameters.parallelism = 1
        return parameters
    }
}

/// The 32-byte file key sealed with AES-GCM inside a slot.
public struct WrappedFileKey: Equatable, Sendable {
    public static let nonceLength = 12, ciphertextLength = 32, tagLength = 16
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    public init(nonce: Data, ciphertext: Data, tag: Data) throws {
        guard nonce.count == Self.nonceLength, ciphertext.count == Self.ciphertextLength, tag.count == Self.tagLength
        else { throw BackupError.malformed }
        self.nonce = nonce; self.ciphertext = ciphertext; self.tag = tag
    }
}

/// A credential entry that unwraps the file key.
public enum BackupSlot: Equatable, Sendable {
    /// Opened with a backup password through Argon2id.
    case password(kdf: KDFParameters, salt: Data, wrap: WrappedFileKey)
    /// Opened with the vault key, which the master password or recovery key unwraps from `header`.
    case vault(header: VaultHeader, hkdfSalt: Data, wrap: WrappedFileKey)

    var typeCode: UInt8 {
        switch self { case .password: PasswordSlotLayout.type; case .vault: VaultSlotLayout.type }
    }
}

enum PasswordSlotLayout {
    static let type: UInt8 = 0x01, length = 92, wrapOffset = 32
}

enum VaultSlotLayout {
    static let type: UInt8 = 0x02, length = 244, wrapOffset = 184
}

/// The public file header: fixed fields followed by one or two slots.
public struct BackupHeader: Equatable, Sendable {
    public static let magic = Data([0x89, 0x41, 0x45, 0x47, 0x49, 0x53, 0x0D, 0x0A])
    public static let version: UInt16 = 1
    public static let fixedLength = 60
    public static let nonceLength = 12, commitmentLength = 32, saltLength = 16

    public let payloadLength: UInt32
    public let payloadNonce: Data
    public let commitment: Data
    public let slots: [BackupSlot]

    public init(payloadLength: UInt32, payloadNonce: Data, commitment: Data, slots: [BackupSlot]) throws {
        self.payloadLength = payloadLength; self.payloadNonce = payloadNonce
        self.commitment = commitment; self.slots = slots
        try validate()
    }

    /// Exact header bytes; also the AAD of the payload.
    public func encoded() -> Data {
        var data = fixedBytes()
        for slot in slots { data.append(Self.slotBytes(slot)) }
        return data
    }

    /// AAD for the file-key wrap in slot `index`: fixed header, slot index and the slot's public fields.
    public func slotAAD(at index: Int) throws -> Data {
        guard slots.indices.contains(index) else { throw BackupError.malformed }
        var data = fixedBytes()
        data.append(UInt8(index))
        let slot = Self.slotBytes(slots[index])
        let wrapOffset = slots[index].typeCode == PasswordSlotLayout.type ? PasswordSlotLayout.wrapOffset : VaultSlotLayout.wrapOffset
        data.append(slot.prefix(wrapOffset))
        return data
    }

    private func validate() throws {
        guard payloadNonce.count == Self.nonceLength, commitment.count == Self.commitmentLength else { throw BackupError.malformed }
        let types = slots.map(\.typeCode)
        guard types == [PasswordSlotLayout.type] || types == [VaultSlotLayout.type]
                || types == [PasswordSlotLayout.type, VaultSlotLayout.type] else { throw BackupError.malformed }
        for slot in slots {
            switch slot {
            case let .password(kdf, salt, _):
                guard kdf == BackupLimits.passwordSlotKDF else { throw BackupError.unsupportedParameters }
                guard salt.count == Self.saltLength else { throw BackupError.malformed }
            case let .vault(header, hkdfSalt, _):
                do { try header.kdf.validate() } catch { throw BackupError.unsupportedParameters }
                guard header.formatVersion == 1, header.salt.count == Self.saltLength, header.wrappedKey.count == 60,
                      header.recoveryWrappedKey.count == 60, hkdfSalt.count == Self.saltLength else { throw BackupError.malformed }
            }
        }
        let length = Int(payloadLength)
        guard length <= BackupLimits.maxPayloadLength else { throw BackupError.limitExceeded }
        guard length > 0, length % BackupLimits.paddingBlock == 0 else { throw BackupError.malformed }
    }

    private func fixedBytes() -> Data {
        var data = Self.magic
        data.appendLE(Self.version)
        data.append(UInt8(slots.count))
        data.append(0)
        data.appendLE(payloadLength)
        data.append(payloadNonce)
        data.append(commitment)
        return data
    }

    private static func slotBytes(_ slot: BackupSlot) -> Data {
        var data = Data([slot.typeCode, 0, 0, 0])
        switch slot {
        case let .password(kdf, salt, wrap):
            data.appendKDF(kdf); data.append(salt); data.append(wrap)
        case let .vault(header, hkdfSalt, wrap):
            data.append(header.vaultID); data.append(header.salt); data.appendKDF(header.kdf)
            data.append(header.wrappedKey); data.append(header.recoveryWrappedKey)
            data.append(hkdfSalt); data.append(wrap)
        }
        return data
    }

    static func parse(_ reader: inout ByteReader) throws -> BackupHeader {
        guard reader.remaining >= Self.magic.count, try reader.bytes(Self.magic.count) == Self.magic else {
            throw BackupError.notABackup
        }
        guard try reader.uint16() == Self.version else { throw BackupError.unsupportedVersion }
        let slotCount = try reader.uint8()
        try reader.zeros(1)
        let payloadLength = try reader.uint32()
        let nonce = try reader.bytes(Self.nonceLength)
        let commitment = try reader.bytes(Self.commitmentLength)
        guard (1...2).contains(slotCount) else { throw BackupError.malformed }
        var slots: [BackupSlot] = []
        for _ in 0..<slotCount { slots.append(try parseSlot(&reader)) }
        return try BackupHeader(payloadLength: payloadLength, payloadNonce: nonce, commitment: commitment, slots: slots)
    }

    private static func parseSlot(_ reader: inout ByteReader) throws -> BackupSlot {
        let type = try reader.uint8()
        try reader.zeros(3)
        switch type {
        case PasswordSlotLayout.type:
            let kdf = try reader.kdf(), salt = try reader.bytes(saltLength)
            return .password(kdf: kdf, salt: salt, wrap: try reader.wrappedFileKey())
        case VaultSlotLayout.type:
            let id = try reader.uuid(), salt = try reader.bytes(saltLength), kdf = try reader.kdf()
            let wrappedKey = try reader.bytes(60), recoveryWrappedKey = try reader.bytes(60)
            let hkdfSalt = try reader.bytes(saltLength)
            let header = VaultHeader(vaultID: id, salt: salt, kdf: kdf, wrappedKey: wrappedKey, recoveryWrappedKey: recoveryWrappedKey)
            return .vault(header: header, hkdfSalt: hkdfSalt, wrap: try reader.wrappedFileKey())
        default:
            throw BackupError.malformed
        }
    }
}

/// A complete ABB v1 file: header, payload ciphertext and its AES-GCM tag.
public struct BackupContainer: Sendable {
    public static let tagLength = 16
    public let header: BackupHeader
    public let ciphertext: Data
    public let tag: Data

    public init(header: BackupHeader, ciphertext: Data, tag: Data) throws {
        guard ciphertext.count == Int(header.payloadLength), tag.count == Self.tagLength else { throw BackupError.malformed }
        self.header = header; self.ciphertext = ciphertext; self.tag = tag
    }

    public func encoded() -> Data {
        var data = header.encoded()
        data.append(ciphertext); data.append(tag)
        return data
    }

    /// Parses untrusted file bytes. Rejects oversized input before reading any structure and
    /// requires the file length to match the header exactly, so truncation and appended bytes fail.
    public static func parse(_ data: Data) throws -> BackupContainer {
        guard data.count <= BackupLimits.maxFileLength else { throw BackupError.limitExceeded }
        var reader = ByteReader(data)
        let header = try BackupHeader.parse(&reader)
        guard reader.remaining == Int(header.payloadLength) + tagLength else { throw BackupError.malformed }
        let ciphertext = try reader.bytes(Int(header.payloadLength))
        return try BackupContainer(header: header, ciphertext: ciphertext, tag: try reader.bytes(tagLength))
    }
}

/// Decrypted payload: the vault identity, vault key and every committed revision.
public struct BackupPayload: Equatable, Sendable {
    /// Latest representable instant, 9999-12-31T23:59:59.999Z.
    public static let maxExportedAtMillis: Int64 = 253_402_300_799_999
    static let incompleteHistoryFlag: UInt32 = 1
    /// Smallest record: two UUIDs, an empty parent list and the shortest sealed revision.
    static let minRecordLength = 16 + 16 + 2 + 4 + BackupLimits.sealedRevisionLength.lowerBound

    public let exportedAtMillis: Int64
    /// The exporting device lacked some parent revisions, so the history is not closed.
    public let incompleteHistory: Bool
    public let vaultKey: Data
    public let header: VaultHeader
    /// Revisions in canonical order: ascending revision ID bytes.
    public let revisions: [EncryptedRevision]

    public init(exportedAtMillis: Int64, incompleteHistory: Bool, vaultKey: Data, header: VaultHeader,
                revisions: [EncryptedRevision]) throws {
        guard (0...Self.maxExportedAtMillis).contains(exportedAtMillis), vaultKey.count == 32 else { throw BackupError.malformed }
        do { try header.kdf.validate() } catch { throw BackupError.unsupportedParameters }
        guard header.formatVersion == 1, header.salt.count == BackupHeader.saltLength, header.wrappedKey.count == 60,
              header.recoveryWrappedKey.count == 60 else { throw BackupError.malformed }
        guard revisions.count <= BackupLimits.maxRevisions,
              revisions.reduce(0, { $0 + $1.parents.count }) <= BackupLimits.maxTotalParents else { throw BackupError.limitExceeded }
        let sorted = revisions.sorted { $0.id.precedesBytes(of: $1.id) }
        for (index, revision) in sorted.enumerated() {
            guard revision.formatVersion == 1, revision.vaultID == header.vaultID,
                  !revision.parents.contains(revision.id), Set(revision.parents).count == revision.parents.count,
                  index == 0 || sorted[index - 1].id.precedesBytes(of: revision.id) else { throw BackupError.malformed }
            guard revision.parents.count <= BackupLimits.maxParentsPerRevision,
                  revision.ciphertext.count <= BackupLimits.sealedRevisionLength.upperBound else { throw BackupError.limitExceeded }
            guard revision.ciphertext.count >= BackupLimits.sealedRevisionLength.lowerBound else { throw BackupError.malformed }
        }
        self.exportedAtMillis = exportedAtMillis; self.incompleteHistory = incompleteHistory
        self.vaultKey = vaultKey; self.header = header; self.revisions = sorted
    }

    /// Plaintext padded with zeros to a multiple of `BackupLimits.paddingBlock`.
    public func encoded() throws -> Data {
        var data = Data()
        data.appendLE(UInt64(bitPattern: exportedAtMillis))
        data.appendLE(incompleteHistory ? Self.incompleteHistoryFlag : 0)
        data.append(header.vaultID); data.append(vaultKey); data.append(header.salt); data.appendKDF(header.kdf)
        data.append(header.wrappedKey); data.append(header.recoveryWrappedKey)
        data.appendLE(UInt32(revisions.count))
        for revision in revisions {
            data.append(revision.itemID); data.append(revision.id)
            data.appendLE(UInt16(revision.parents.count))
            for parent in revision.parents.sorted(by: { $0.precedesBytes(of: $1) }) { data.append(parent) }
            data.appendLE(UInt32(revision.ciphertext.count))
            data.append(revision.ciphertext)
        }
        let block = BackupLimits.paddingBlock
        let padded = max(block, (data.count + block - 1) / block * block)
        guard padded <= BackupLimits.maxPayloadLength else { throw BackupError.limitExceeded }
        data.append(Data(count: padded - data.count))
        return data
    }

    /// Parses authenticated plaintext. Every count and length is checked against the limits and
    /// the bytes actually remaining before anything is allocated.
    public static func decode(_ plaintext: Data) throws -> BackupPayload {
        guard plaintext.count <= BackupLimits.maxPayloadLength else { throw BackupError.limitExceeded }
        guard plaintext.count > 0, plaintext.count % BackupLimits.paddingBlock == 0 else { throw BackupError.malformed }
        var reader = ByteReader(plaintext)
        let exportedAt = Int64(bitPattern: try reader.uint64())
        let flags = try reader.uint32()
        guard flags & ~incompleteHistoryFlag == 0 else { throw BackupError.malformed }
        let vaultID = try reader.uuid(), vaultKey = try reader.bytes(32), salt = try reader.bytes(BackupHeader.saltLength)
        let kdf = try reader.kdf(), wrappedKey = try reader.bytes(60), recoveryWrappedKey = try reader.bytes(60)
        let header = VaultHeader(vaultID: vaultID, salt: salt, kdf: kdf, wrappedKey: wrappedKey, recoveryWrappedKey: recoveryWrappedKey)
        let count = Int(try reader.uint32())
        guard count <= BackupLimits.maxRevisions else { throw BackupError.limitExceeded }
        guard count <= reader.remaining / minRecordLength else { throw BackupError.malformed }
        var revisions: [EncryptedRevision] = []
        revisions.reserveCapacity(count)
        var totalParents = 0
        var previousID: UUID?
        for _ in 0..<count {
            let itemID = try reader.uuid(), id = try reader.uuid()
            guard previousID.map({ $0.precedesBytes(of: id) }) ?? true else { throw BackupError.malformed }
            previousID = id
            let parentCount = Int(try reader.uint16())
            totalParents += parentCount
            guard parentCount <= BackupLimits.maxParentsPerRevision, totalParents <= BackupLimits.maxTotalParents else {
                throw BackupError.limitExceeded
            }
            guard parentCount <= reader.remaining / 16 else { throw BackupError.malformed }
            var parents: [UUID] = []
            parents.reserveCapacity(parentCount)
            for _ in 0..<parentCount {
                let parent = try reader.uuid()
                guard parent != id, parents.last.map({ $0.precedesBytes(of: parent) }) ?? true else { throw BackupError.malformed }
                parents.append(parent)
            }
            let sealedLength = Int(try reader.uint32())
            guard sealedLength <= BackupLimits.sealedRevisionLength.upperBound else { throw BackupError.limitExceeded }
            guard sealedLength >= BackupLimits.sealedRevisionLength.lowerBound else { throw BackupError.malformed }
            revisions.append(EncryptedRevision(vaultID: vaultID, itemID: itemID, id: id, parents: parents,
                                               ciphertext: try reader.bytes(sealedLength)))
        }
        let padding = reader.remaining
        try reader.zeros(padding)
        return try BackupPayload(exportedAtMillis: exportedAt, incompleteHistory: flags & incompleteHistoryFlag != 0,
                                 vaultKey: vaultKey, header: header, revisions: revisions)
    }
}

// MARK: - Byte helpers

/// Bounds-checked little-endian reader; every overrun is reported as `BackupError.malformed`.
struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) { self.data = data; offset = data.startIndex }

    var remaining: Int { data.endIndex - offset }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw BackupError.malformed }
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    mutating func zeros(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw BackupError.malformed }
        guard data[offset..<offset + count].allSatisfy({ $0 == 0 }) else { throw BackupError.malformed }
        offset += count
    }

    mutating func uint8() throws -> UInt8 { try bytes(1)[0] }
    mutating func uint16() throws -> UInt16 { UInt16(try littleEndian(2)) }
    mutating func uint32() throws -> UInt32 { UInt32(try littleEndian(4)) }
    mutating func uint64() throws -> UInt64 { try littleEndian(8) }

    mutating func uuid() throws -> UUID {
        try bytes(16).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    mutating func kdf() throws -> KDFParameters {
        var parameters = KDFParameters()
        parameters.memoryKiB = try uint32(); parameters.iterations = try uint32(); parameters.parallelism = try uint32()
        return parameters
    }

    mutating func wrappedFileKey() throws -> WrappedFileKey {
        try WrappedFileKey(nonce: bytes(WrappedFileKey.nonceLength), ciphertext: bytes(WrappedFileKey.ciphertextLength),
                           tag: bytes(WrappedFileKey.tagLength))
    }

    private mutating func littleEndian(_ width: Int) throws -> UInt64 {
        try bytes(width).reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// RFC 4122 byte order, the order `UUID.uuidString` prints.
    mutating func append(_ id: UUID) {
        Swift.withUnsafeBytes(of: id.uuid) { append(contentsOf: $0) }
    }

    mutating func appendKDF(_ kdf: KDFParameters) {
        appendLE(kdf.memoryKiB); appendLE(kdf.iterations); appendLE(kdf.parallelism)
    }

    mutating func append(_ wrap: WrappedFileKey) {
        append(wrap.nonce); append(wrap.ciphertext); append(wrap.tag)
    }
}

extension UUID {
    /// Canonical ABB ordering: lexicographic over the 16 RFC 4122 bytes.
    func precedesBytes(of other: UUID) -> Bool {
        withUnsafeBytes(of: uuid) { lhs in withUnsafeBytes(of: other.uuid) { rhs in lhs.lexicographicallyPrecedes(rhs) } }
    }
}
