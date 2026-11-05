import Foundation

public enum VaultError: Error, LocalizedError, Sendable {
    case invalidPassword, unsupportedFormat, invalidParameters, locked, damagedData, differentVault
    case randomFailure, derivationFailed, weakMasterPassword, invalidRecoveryKey, oversizedRecord

    public var errorDescription: String? {
        switch self {
        case .invalidPassword: L10n.text("error.invalidPassword")
        case .unsupportedFormat: L10n.text("error.unsupportedFormat")
        case .invalidParameters: L10n.text("error.invalidParameters")
        case .locked: L10n.text("error.locked")
        case .damagedData: L10n.text("error.damagedData")
        case .differentVault: L10n.text("error.differentVault")
        case .randomFailure: L10n.text("error.randomFailure")
        case .derivationFailed: L10n.text("error.derivationFailed")
        case .weakMasterPassword: L10n.text("error.weakMasterPassword")
        case .invalidRecoveryKey: L10n.text("error.invalidRecoveryKey")
        case .oversizedRecord: L10n.text("error.oversizedRecord")
        }
    }
}

public struct KDFParameters: Codable, Equatable, Sendable {
    public var memoryKiB: UInt32 = 65_536
    public var iterations: UInt32 = 3
    public var parallelism: UInt32 = 1
    public init() {}
    public func validate() throws {
        guard (65_536...262_144).contains(memoryKiB), (3...10).contains(iterations),
              (1...4).contains(parallelism) else { throw VaultError.invalidParameters }
    }
}

public struct VaultHeader: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let vaultID: UUID
    public let salt: Data
    public let kdf: KDFParameters
    public let wrappedKey: Data
    public let recoveryWrappedKey: Data

    public init(vaultID: UUID, salt: Data, kdf: KDFParameters, wrappedKey: Data, recoveryWrappedKey: Data) {
        self.formatVersion = 1; self.vaultID = vaultID; self.salt = salt; self.kdf = kdf
        self.wrappedKey = wrappedKey; self.recoveryWrappedKey = recoveryWrappedKey
    }
    public func validate() throws {
        guard formatVersion == 1 else { throw VaultError.unsupportedFormat }
        try kdf.validate()
        guard salt.count == 16, wrappedKey.count == 60, recoveryWrappedKey.count == 60 else {
            throw VaultError.damagedData
        }
    }
}

public enum ItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case login, card, note
    public var id: String { rawValue }
    public var title: String {
        switch self { case .login: L10n.text("kind.login"); case .card: L10n.text("kind.card"); case .note: L10n.text("kind.note") }
    }
    public var symbol: String {
        switch self { case .login: "key.horizontal"; case .card: "creditcard"; case .note: "note.text" }
    }
}

public struct VaultItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ItemKind
    public var title: String
    public var username: String
    public var password: String
    public var website: String
    public var notes: String
    public var cardholder: String
    public var cardNumber: String
    public var expiry: String
    public var securityCode: String
    public var isFavorite: Bool
    public var deletedAt: Date?
    public var modifiedAt: Date

    public init(id: UUID = UUID(), kind: ItemKind = .login, title: String = "", username: String = "",
                password: String = "", website: String = "", notes: String = "", isFavorite: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.username = username; self.password = password
        self.website = website; self.notes = notes; self.isFavorite = isFavorite
        cardholder = ""; cardNumber = ""; expiry = ""; securityCode = ""; deletedAt = nil; modifiedAt = Date()
    }
}

/// Immutable revisions preserve concurrent edits without last-writer-wins data loss.
public struct EncryptedRevision: Codable, Equatable, Identifiable, Sendable {
    public let formatVersion: Int
    public let vaultID: UUID
    public let itemID: UUID
    public let id: UUID
    public let parents: [UUID]
    public let ciphertext: Data

    public init(vaultID: UUID, itemID: UUID, id: UUID, parents: [UUID], ciphertext: Data) {
        formatVersion = 1; self.vaultID = vaultID; self.itemID = itemID; self.id = id
        self.parents = parents.sorted { $0.uuidString < $1.uuidString }; self.ciphertext = ciphertext
    }

    public var authenticatedData: Data {
        Self.aad(vaultID: vaultID, itemID: itemID, id: id, parents: parents)
    }

    public static func aad(vaultID: UUID, itemID: UUID, id: UUID, parents: [UUID]) -> Data {
        Data((["aegis", "revision", "1", vaultID.uuidString, itemID.uuidString, id.uuidString] +
              parents.map(\.uuidString).sorted()).joined(separator: "|").utf8)
    }
}

public struct VaultEntry: Identifiable, Sendable {
    public var id: UUID { revision.id }
    public let item: VaultItem
    public let revision: EncryptedRevision
    public let isConflict: Bool
    public init(item: VaultItem, revision: EncryptedRevision, isConflict: Bool) {
        self.item = item; self.revision = revision; self.isConflict = isConflict
    }
}

public enum RevisionGraph {
    public static func heads(in revisions: [EncryptedRevision]) -> [EncryptedRevision] {
        // Only authenticated revisions should reach this function.
        let superseded = Set(revisions.flatMap(\.parents))
        return revisions.filter { !superseded.contains($0.id) }
    }
}

public struct VaultBackup: Codable, Sendable {
    public let format: String
    public let version: Int
    public let header: VaultHeader
    public let revisions: [EncryptedRevision]
    public init(header: VaultHeader, revisions: [EncryptedRevision]) {
        format = "aegis-encrypted-backup"; version = 1; self.header = header; self.revisions = revisions
    }
    public func validate() throws {
        guard format == "aegis-encrypted-backup", version == 1 else { throw VaultError.unsupportedFormat }
        try header.validate()
        guard revisions.count <= 100_000,
              revisions.allSatisfy({ $0.vaultID == header.vaultID && $0.formatVersion == 1 && $0.ciphertext.count <= 300_000 })
        else { throw VaultError.damagedData }
    }
}
