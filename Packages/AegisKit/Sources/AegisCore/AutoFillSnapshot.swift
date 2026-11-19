import Foundation

public struct AutoFillCredential: Codable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let username: String
    public let password: String
    public let website: String

    init(entry: VaultEntry) {
        id = entry.id
        title = entry.item.title
        username = entry.item.username
        password = entry.item.password
        website = entry.item.website
    }

    public static func includes(_ entry: VaultEntry) -> Bool {
        entry.item.kind == .login && entry.item.deletedAt == nil && entry.item.permanentlyDeletedAt == nil
    }
}

/// A derived cache for the extension. The header unwraps the same key as the main vault.
public struct AutoFillSnapshot: Codable, Sendable {
    public static let filename = "autofill-logins-v1.aegis"
    public static let legacyFilename = "autofill.aegis"
    public static let maxFileSize = 32 * 1024 * 1024

    let version: Int
    public let header: VaultHeader
    let ciphertext: Data

    init(header: VaultHeader, ciphertext: Data) {
        version = 1
        self.header = header
        self.ciphertext = ciphertext
    }

    var authenticatedData: Data {
        Self.authenticatedData(vaultID: header.vaultID)
    }

    static func authenticatedData(vaultID: UUID) -> Data {
        Data("aegis|autofill|1|\(vaultID.uuidString)".utf8)
    }

    public static func read(from directory: URL) throws -> AutoFillSnapshot {
        let file = try FileHandle(forReadingFrom: directory.appendingPathComponent(filename))
        defer { try? file.close() }
        guard let data = try file.read(upToCount: maxFileSize + 1), data.count <= maxFileSize else {
            throw VaultError.oversizedRecord
        }
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.version == 1 else { throw VaultError.unsupportedFormat }
        try snapshot.header.validate()
        return snapshot
    }
}
