import Foundation

public enum PasswordCSVImport {
    public static let maxFileBytes = 10 * 1024 * 1024
    private static let maxDataRows = 10000
    private static let maxColumns = 64

    public enum Source: String, Sendable {
        case onePassword, chrome

        public var name: String {
            switch self {
            case .onePassword: "1Password"
            case .chrome: "Chrome"
            }
        }
    }

    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case invalidEncoding, unsupportedHeader, limitExceeded
        case malformed(line: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidEncoding: L10n.text("csv.error.encoding")
            case .unsupportedHeader: L10n.text("csv.error.header")
            case .limitExceeded: L10n.text("csv.error.limit")
            case let .malformed(line): L10n.format("csv.error.malformed", Int64(line))
            }
        }
    }

    public enum SkipReason: String, Sendable {
        case wrongColumnCount, unsupportedType, missingPassword, archived, oversized, duplicate

        public var message: String {
            switch self {
            case .wrongColumnCount: L10n.text("csv.skip.columns")
            case .unsupportedType: L10n.text("csv.skip.type")
            case .missingPassword: L10n.text("csv.skip.password")
            case .archived: L10n.text("csv.skip.archived")
            case .oversized: L10n.text("csv.skip.oversized")
            case .duplicate: L10n.text("csv.skip.duplicate")
            }
        }
    }

    public struct Issue: Equatable, Sendable {
        public let line: Int
        public let reason: SkipReason

        public init(line: Int, reason: SkipReason) {
            self.line = line
            self.reason = reason
        }
    }

    public struct Row: Sendable {
        public let line: Int
        public let item: VaultItem
    }

    public struct Parsed: Sendable {
        public let source: Source
        public let rows: [Row]
        public let issues: [Issue]
        public let hasUnsupportedFields: Bool
    }

    public struct Candidate: Identifiable, Sendable {
        public let title: String
        public let username: String
        public let host: String
        public let revision: EncryptedRevision

        public var id: UUID {
            revision.itemID
        }
    }

    public struct Preview: Sendable {
        public let source: Source
        public let candidates: [Candidate]
        public let issues: [Issue]
        public let hasUnsupportedFields: Bool
    }

    /// Prepares encrypted candidates using the unlocked key and authenticated entries from the target vault.
    /// Plaintext passwords and notes are discarded when preparation returns.
    public static func prepare(_ parsed: Parsed, existing: [VaultEntry], crypto: VaultCrypto) async throws -> Preview {
        var seen = Set(existing.lazy.filter { $0.item.kind == .login }.map { MatchKey($0.item) })
        var candidates: [Candidate] = []
        var issues = parsed.issues
        for row in parsed.rows {
            try Task.checkCancellation()
            let item = row.item
            let match = MatchKey(item)
            guard seen.insert(match).inserted else {
                issues.append(Issue(line: row.line, reason: .duplicate))
                continue
            }
            do {
                let revision = try await crypto.encrypt(item, parents: [])
                let host = URLComponents(string: item.website)?.host ?? ""
                candidates.append(Candidate(title: item.title, username: item.username, host: host, revision: revision))
            } catch VaultError.oversizedRecord {
                issues.append(Issue(line: row.line, reason: .oversized))
            }
        }
        return Preview(source: parsed.source, candidates: candidates, issues: issues.sorted { $0.line < $1.line },
                       hasUnsupportedFields: parsed.hasUnsupportedFields)
    }

    /// In-memory comparison only. UTF-8 byte comparison distinguishes canonically equivalent passwords.
    public struct MatchKey: Hashable {
        private let fields: [Data]
        private let isFavorite: Bool

        public init(_ item: VaultItem) {
            fields = [item.title, item.website, item.username, item.password, item.notes].map { Data($0.utf8) }
            isFavorite = item.isFavorite
        }
    }

    /// Parses a bounded UTF-8 export and reports semantic row failures. Throws on malformed CSV or an unknown header.
    public static func parse(_ data: Data) throws -> Parsed {
        guard data.count <= maxFileBytes else { throw Failure.limitExceeded }
        var header: Header?
        var rows: [Row] = []
        var issues: [Issue] = []
        var hasUnsupportedFields = false
        try readRecords(Array(data)) { columns, line in
            guard let layout = header else {
                header = try Header(columns)
                return
            }
            guard columns.count == layout.indices.count else {
                issues.append(Issue(line: line, reason: .wrongColumnCount))
                return
            }
            func value(_ name: String) -> String {
                layout.indices[name].map { columns[$0] } ?? ""
            }
            func flag(_ name: String) -> Bool {
                ["true", "1"].contains(normalized(value(name)))
            }
            if layout.source == .onePassword {
                let type = normalized(value("type"))
                if !type.isEmpty, !["login", "password"].contains(type) {
                    issues.append(Issue(line: line, reason: .unsupportedType))
                    return
                }
                if flag("archived") {
                    issues.append(Issue(line: line, reason: .archived))
                    return
                }
                if !value("tags").isEmpty {
                    hasUnsupportedFields = true
                }
            }
            let password = value("password")
            guard !password.isEmpty else {
                issues.append(Issue(line: line, reason: .missingPassword))
                return
            }
            let website = value(layout.website)
            let rawTitle = value(layout.title)
            let host = URLComponents(string: website)?.host ?? ""
            let fallbackTitle = host.isEmpty ? L10n.text("list.untitled") : host
            var item = VaultItem(title: rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackTitle : rawTitle,
                                 username: value("username"), password: password, website: website, notes: value(layout.notes))
            item.isFavorite = layout.source == .onePassword && flag("favorite")
            if layout.source == .onePassword {
                // Newer exports use "OTPAuth"; older ones put the same URI in "first one-time password".
                let rawOTP = ["otpauth", "first one-time password"].lazy.map(value).first { !$0.isEmpty }
                if let rawOTP {
                    // Keep the row but report it, so HOTP or malformed secrets are never dropped silently.
                    if let otp = try? OneTimePassword.parse(rawOTP) {
                        item.oneTimePassword = otp.uri
                    } else {
                        hasUnsupportedFields = true
                    }
                }
            }
            rows.append(Row(line: line, item: item))
        }
        guard let header else { throw Failure.unsupportedHeader }
        return Parsed(source: header.source, rows: rows, issues: issues, hasUnsupportedFields: hasUnsupportedFields)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct Header {
        let source: Source
        let indices: [String: Int]
        let title: String
        let website: String
        let notes: String

        init(_ columns: [String]) throws {
            var indices: [String: Int] = [:]
            for (index, name) in columns.enumerated() {
                let key = normalized(name)
                guard !key.isEmpty, indices.updateValue(index, forKey: key) == nil else { throw Failure.unsupportedHeader }
            }
            let hasTitle = indices["title"] != nil
            let hasName = indices["name"] != nil
            let hasURL = indices["url"] != nil
            let hasWebsite = indices["website"] != nil
            guard hasTitle != hasName, indices["username"] != nil, indices["password"] != nil,
                  hasTitle ? (hasURL != hasWebsite) : (hasURL && !hasWebsite) else { throw Failure.unsupportedHeader }
            self.indices = indices
            source = hasTitle ? .onePassword : .chrome
            title = hasTitle ? "title" : "name"
            website = hasURL ? "url" : "website"
            notes = hasTitle ? "notes" : "note"
        }
    }

    private enum FieldState { case start, unquoted, quoted, closedQuote }

    private static func readRecords(_ bytes: [UInt8], receive: ([String], Int) throws -> Void) throws {
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var line = 1
        var recordLine = 1
        var recordCount = 0
        var fields: [String] = []
        var field: [UInt8] = []
        var state = FieldState.start

        func finishField() throws {
            guard fields.count < maxColumns else { throw Failure.limitExceeded }
            guard let value = String(bytes: field, encoding: .utf8) else { throw Failure.invalidEncoding }
            fields.append(value)
            field.removeAll(keepingCapacity: true)
            state = .start
        }

        func finishRecord() throws {
            try finishField()
            if fields != [""] {
                recordCount += 1
                guard recordCount <= maxDataRows + 1 else { throw Failure.limitExceeded }
                try receive(fields, recordLine)
            }
            fields.removeAll(keepingCapacity: true)
        }

        // Count physical line breaks while preserving the original bytes inside quoted passwords or notes.
        while index < bytes.count {
            if index % 4096 == 0 {
                try Task.checkCancellation()
            }
            let byte = bytes[index]
            index += 1
            if byte == 0x0D || byte == 0x0A {
                let crlf = byte == 0x0D && index < bytes.count && bytes[index] == 0x0A
                if crlf {
                    index += 1
                }
                if state == .quoted {
                    field.append(byte)
                    if crlf {
                        field.append(0x0A)
                    }
                } else {
                    try finishRecord()
                    recordLine = line + 1
                }
                line += 1
                continue
            }
            switch (state, byte) {
            case (.start, 0x22): state = .quoted
            case (.quoted, 0x22): state = .closedQuote
            case (.closedQuote, 0x22): field.append(byte); state = .quoted
            case (.start, 0x2C), (.unquoted, 0x2C), (.closedQuote, 0x2C): try finishField()
            case (.unquoted, 0x22), (.closedQuote, _): throw Failure.malformed(line: recordLine)
            case (.quoted, _), (.unquoted, _): field.append(byte)
            case (.start, _): field.append(byte); state = .unquoted
            }
        }
        guard state != .quoted else { throw Failure.malformed(line: recordLine) }
        if state != .start || !fields.isEmpty {
            try finishRecord()
        }
    }
}
