import SwiftUI
import UniformTypeIdentifiers

struct EncryptedBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.aegisVaultBackup]
    }

    var data: Data
    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    /// ABB v1 binary backups (`.aegis`), the only format new exports produce.
    static let aegisVaultBackup = UTType(exportedAs: "app.aegis.backup", conformingTo: .data)
}
