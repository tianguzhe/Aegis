import Foundation

public enum VaultError: Error, LocalizedError, Sendable {
    case invalidPassword, unsupportedFormat, invalidParameters, locked, damagedData, differentVault
    case randomFailure, derivationFailed, weakMasterPassword, invalidRecoveryKey, oversizedRecord, vaultChanged
    case retiredVaultHistory, deviceKeyMismatch

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
        case .vaultChanged: L10n.text("error.vaultChanged")
        case .retiredVaultHistory: L10n.text("rotation.error.retiredHistory")
        case .deviceKeyMismatch: L10n.text("error.deviceKeyMismatch")
        }
    }
}

public struct KDFParameters: Codable, Equatable, Sendable {
    public var memoryKiB: UInt32 = 65536
    public var iterations: UInt32 = 3
    public var parallelism: UInt32 = 1
    public init() {}
    public func validate() throws {
        guard (65536 ... 262_144).contains(memoryKiB), (3 ... 10).contains(iterations),
              (1 ... 4).contains(parallelism) else { throw VaultError.invalidParameters }
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
        formatVersion = 1; self.vaultID = vaultID; self.salt = salt; self.kdf = kdf
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
    public var id: String {
        rawValue
    }

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
    /// Login TOTP secret as a canonical `otpauth://totp` URI (raw input while editing). Optional, so
    /// records written before this field decode unchanged.
    public var oneTimePassword: String?
    public var cardholder: String
    public var cardNumber: String
    public var expiry: String
    public var securityCode: String
    // Cards can omit the network and type to use the neutral appearance.
    public var cardBrand: CardBrand?
    public var cardType: PaymentCardType?
    public var isFavorite: Bool
    /// Optional user labels; nil and empty are treated identically so older records decode unchanged.
    public var tags: [String]?
    /// Archived items stay encrypted and synced, but are hidden from main lists, AutoFill, and health audits.
    public var isArchived: Bool?
    public var deletedAt: Date?
    public var permanentlyDeletedAt: Date?
    public var modifiedAt: Date
    // Only the reserved internal record carries rotation lineage.
    var rotationLineage: VaultRotation.Lineage?

    public var tagList: [String] {
        tags ?? []
    }

    public var archived: Bool {
        isArchived == true
    }

    public static func normalizeTags(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    public static func parseTags(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;，；\r\n")
        return normalizeTags(text.components(separatedBy: separators))
    }

    public init(id: UUID = UUID(), kind: ItemKind = .login, title: String = "", username: String = "",
                password: String = "", website: String = "", notes: String = "", isFavorite: Bool = false,
                tags: [String]? = nil, isArchived: Bool? = nil)
    {
        self.id = id; self.kind = kind; self.title = title; self.username = username; self.password = password
        self.website = website; self.notes = notes; self.isFavorite = isFavorite
        let normalized = tags.map(Self.normalizeTags) ?? []
        self.tags = normalized.isEmpty ? nil : normalized
        self.isArchived = isArchived == true ? true : nil
        cardholder = ""; cardNumber = ""; expiry = ""; securityCode = ""; deletedAt = nil; modifiedAt = Date()
        cardBrand = kind == .card ? .unionPay : nil
        cardType = kind == .card ? .debit : nil
    }
}

public struct QuickCopyField: Equatable, Sendable {
    public let actionKey: String
    public let value: String
    public init(actionKey: String, value: String) {
        self.actionKey = actionKey; self.value = value
    }
}

public extension VaultItem {
    /// Fields copyable without opening the record. Order is part of the contract:
    /// the identifier comes first and the secret second, matching the macOS shortcuts.
    /// Empty values are kept so menus can show them disabled instead of shifting positions.
    var quickCopyFields: [QuickCopyField] {
        switch kind {
        case .login: [.init(actionKey: "action.copyUsername", value: username), .init(actionKey: "action.copyPassword", value: password)]
        case .card: [.init(actionKey: "action.copyCardNumber", value: cardNumber), .init(actionKey: "action.copySecurityCode", value: securityCode)]
        case .note: []
        }
    }
}

public enum TrashPolicy {
    public static let retentionDays = 7
    public static let retentionInterval: TimeInterval = .init(retentionDays * 24 * 60 * 60)

    public static func expirationDate(for item: VaultItem) -> Date? {
        item.deletedAt?.addingTimeInterval(retentionInterval)
    }

    /// Do not expire a conflict while any branch is active or still within its retention period.
    public static func expiredGroups(in entries: [VaultEntry], now: Date = Date()) -> [[VaultEntry]] {
        Dictionary(grouping: entries, by: \.item.id).values.filter { group in
            group.allSatisfy { expirationDate(for: $0.item).map { $0 <= now } ?? false }
        }
    }

    public static func deletionMarker(for item: VaultItem, now: Date = Date()) -> VaultItem {
        var marker = VaultItem(id: item.id, kind: item.kind)
        marker.deletedAt = item.deletedAt ?? now
        marker.permanentlyDeletedAt = now
        marker.modifiedAt = now
        return marker
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

public struct VaultEntry: Identifiable, Equatable, Sendable {
    public var id: UUID {
        revision.id
    }

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
