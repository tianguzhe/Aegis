import Foundation

public struct VaultHistoryEntry: Identifiable, Equatable, Sendable {
    public var id: UUID {
        revision.id
    }

    public let item: VaultItem
    public let revision: EncryptedRevision
    public let isCurrentHead: Bool
    public let isConflictHead: Bool

    public init(item: VaultItem, revision: EncryptedRevision, isCurrentHead: Bool, isConflictHead: Bool) {
        self.item = item
        self.revision = revision
        self.isCurrentHead = isCurrentHead
        self.isConflictHead = isConflictHead
    }
}

public enum VaultHistoryChange: String, Equatable, Sendable {
    case created
    case title
    case username
    case password
    case website
    case oneTimePassword
    case card
    case notes
    case favorite
    case trashed
    case restored

    public var label: String {
        switch self {
        case .created: L10n.text("history.change.created")
        case .title: L10n.text("field.title")
        case .username: L10n.text("field.username")
        case .password: L10n.text("field.password")
        case .website: L10n.text("field.website")
        case .oneTimePassword: L10n.text("field.oneTimePassword")
        case .card: L10n.text("kind.card")
        case .notes: L10n.text("field.notes")
        case .favorite: L10n.text("field.favorite")
        case .trashed: L10n.text("history.change.trashed")
        case .restored: L10n.text("history.change.restored")
        }
    }
}

public enum VaultHistoryDiff {
    public static func changes(from previous: VaultItem?, to current: VaultItem) -> [VaultHistoryChange] {
        guard let previous else { return [.created] }
        var result: [VaultHistoryChange] = []
        if previous.deletedAt == nil, current.deletedAt != nil {
            result.append(.trashed)
        } else if previous.deletedAt != nil, current.deletedAt == nil {
            result.append(.restored)
        }
        if previous.title != current.title {
            result.append(.title)
        }
        if previous.username != current.username {
            result.append(.username)
        }
        if previous.password != current.password {
            result.append(.password)
        }
        if previous.website != current.website {
            result.append(.website)
        }
        if previous.oneTimePassword != current.oneTimePassword {
            result.append(.oneTimePassword)
        }
        if previous.cardholder != current.cardholder ||
            previous.cardNumber != current.cardNumber ||
            previous.expiry != current.expiry ||
            previous.securityCode != current.securityCode ||
            previous.cardBrand != current.cardBrand ||
            previous.cardType != current.cardType
        {
            result.append(.card)
        }
        if previous.notes != current.notes {
            result.append(.notes)
        }
        if previous.isFavorite != current.isFavorite {
            result.append(.favorite)
        }
        return result
    }
}

public extension VaultCrypto {
    /// Returns authenticated historical revisions for a single item, ordered newest first.
    /// Unauthenticated or structurally invalid revisions are ignored and never affect head state.
    func itemHistory(for itemID: UUID, in revisions: [EncryptedRevision]) throws -> [VaultHistoryEntry] {
        // `decrypt` throws `VaultError.locked` without a key; that error is intentionally not caught below.
        var authenticated: [UUID: (revision: EncryptedRevision, item: VaultItem)] = [:]
        var conflictingIDs: Set<UUID> = []

        for revision in revisions where revision.itemID == itemID {
            let id = revision.id
            if let existing = authenticated[id] {
                if existing.revision != revision {
                    conflictingIDs.insert(id)
                }
                continue
            }
            do {
                let item = try decrypt(revision)
                authenticated[id] = (revision, item)
            } catch VaultError.damagedData, VaultError.differentVault, VaultError.unsupportedFormat, VaultError.oversizedRecord {
                continue
            }
        }

        let validRecords = authenticated.values.filter { record in
            guard !conflictingIDs.contains(record.revision.id), !record.revision.parents.contains(record.revision.id), !record.revision.parents.contains(where: { conflictingIDs.contains($0) }) else { return false }
            return true
        }

        let validRevisions = validRecords.map(\.revision)
        let headIDs = Set(RevisionGraph.heads(in: validRevisions).map(\.id))
        let isConflict = headIDs.count > 1

        return validRecords
            .filter { $0.item.permanentlyDeletedAt == nil }
            .map { record in
                let isHead = headIDs.contains(record.revision.id)
                return VaultHistoryEntry(
                    item: record.item,
                    revision: record.revision,
                    isCurrentHead: isHead,
                    isConflictHead: isHead && isConflict
                )
            }
            .sorted { lhs, rhs in
                if lhs.item.modifiedAt != rhs.item.modifiedAt {
                    return lhs.item.modifiedAt > rhs.item.modifiedAt
                }
                if lhs.isCurrentHead != rhs.isCurrentHead {
                    return lhs.isCurrentHead
                }
                return lhs.revision.id.uuidString > rhs.revision.id.uuidString
            }
    }
}
