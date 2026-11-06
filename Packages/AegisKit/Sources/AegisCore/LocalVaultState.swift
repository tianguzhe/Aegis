import CryptoKit
import Foundation

/// Device-local editing state. Never uploaded or included in an exported vault backup.
public struct VaultDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { item.id }
    public var item: VaultItem
    public let original: VaultItem
    public let parents: [UUID]
    public var isDirty: Bool { item != original }

    public init(item: VaultItem, original: VaultItem? = nil, parents: [UUID]) {
        self.item = item; self.original = original ?? item; self.parents = parents
    }
}

public struct LocalVaultState: Codable, Equatable, Sendable {
    public var drafts: [VaultDraft] = []
    public var pendingRecoveryKey: String?
    public init() {}

    public mutating func retain(_ draft: VaultDraft) {
        drafts.removeAll { $0.id == draft.id }
        if draft.isDirty { drafts.append(draft) }
    }
}

public enum LocalVaultStateCipher {
    public static func seal(_ state: LocalVaultState, key: SymmetricKey, vaultID: UUID) throws -> Data {
        var plaintext = try JSONEncoder().encode(state)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        return try AES.GCM.seal(plaintext, using: key, authenticating: aad(vaultID)).combined!
    }

    public static func open(_ ciphertext: Data, key: SymmetricKey, vaultID: UUID) throws -> LocalVaultState {
        var plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: aad(vaultID))
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        return try JSONDecoder().decode(LocalVaultState.self, from: plaintext)
    }
    private static func aad(_ id: UUID) -> Data { Data("aegis|local-state|1|\(id.uuidString)".utf8) }
}
