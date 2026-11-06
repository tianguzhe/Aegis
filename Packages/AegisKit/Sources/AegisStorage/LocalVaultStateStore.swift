import AegisCore
import CryptoKit
import Foundation

/// Atomic encrypted writes are synchronous so locking cannot outrun draft persistence.
@MainActor
public final class LocalVaultStateStore {
    private let directory: URL?
    private var memory: [UUID: Data] = [:]
    private var key: SymmetricKey?
    private var vaultID: UUID?
    public private(set) var state = LocalVaultState()

    public init(directory: URL?) { self.directory = directory }

    public func unlock(key: Data, vaultID: UUID) throws {
        let symmetricKey = SymmetricKey(data: key)
        let ciphertext: Data?
        if let file = file(for: vaultID), FileManager.default.fileExists(atPath: file.path) {
            ciphertext = try Data(contentsOf: file)
        } else { ciphertext = memory[vaultID] }
        let opened = try ciphertext.map { try LocalVaultStateCipher.open($0, key: symmetricKey, vaultID: vaultID) } ?? LocalVaultState()
        self.key = symmetricKey; self.vaultID = vaultID; state = opened
    }

    public func write(_ updated: LocalVaultState) throws {
        guard let key, let vaultID else { throw VaultError.locked }
        let ciphertext = try LocalVaultStateCipher.seal(updated, key: key, vaultID: vaultID)
        if let file = file(for: vaultID) {
            #if os(iOS)
            try ciphertext.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try ciphertext.write(to: file, options: .atomic)
            #endif
        } else { memory[vaultID] = ciphertext }
        state = updated
    }

    public func lock() { key = nil; vaultID = nil; state = LocalVaultState() }
    private func file(for id: UUID) -> URL? { directory?.appendingPathComponent("local-state-\(id.uuidString).aegis") }
}
