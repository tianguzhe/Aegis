import AegisCore
@testable import AegisStorage
import Foundation
import Testing

struct PasswordCSVImportTests {
    @Test func onePasswordHeadersPreserveSecrets() throws {
        let csv = "\u{FEFF}Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\r\n" +
            "Example,,user,\" secret,\"\"quoted\"\" \",,true,false,work,\"first\r\nsecond\"\r\n" +
            "Archived,https://archive.example,,secret,,false,true,,\r\n"
        let result = try PasswordCSVImport.parse(Data(csv.utf8))
        #expect(result.source == .onePassword)
        let item = try #require(result.rows.first?.item)
        #expect(item.password == " secret,\"quoted\" ")
        #expect(item.website.isEmpty)
        #expect(item.notes == "first\r\nsecond")
        #expect(item.isFavorite)
        #expect(result.hasUnsupportedFields)
        #expect(result.issues == [.init(line: 4, reason: .archived)])
    }

    @Test func chromeAcceptsReorderedColumnsAndAndroidURLs() throws {
        let csv = " Username ,NAME,password,URL,note\n,Example,pw,android://hash@com.example/,\"one,two\"\n"
        let result = try PasswordCSVImport.parse(Data(csv.utf8))
        #expect(result.source == .chrome)
        let item = try #require(result.rows.first?.item)
        #expect(item.username.isEmpty)
        #expect(item.website == "android://hash@com.example/")
        #expect(item.notes == "one,two")
        let old = try PasswordCSVImport.parse(Data("name,url,username,password\nOld,https://example.test,me,pw".utf8))
        #expect(old.rows.count == 1)
    }

    @Test func badRowsAndMalformedFilesAreDistinguished() throws {
        let csv = "Title,Website,Username,Password,Type\nWrong width\nBank,,,pw,Credit Card\nLogin,https://example.test,me,,Login\nGood,,,pw,Password"
        let result = try PasswordCSVImport.parse(Data(csv.utf8))
        #expect(result.rows.map(\.line) == [5])
        #expect(result.issues == [.init(line: 2, reason: .wrongColumnCount), .init(line: 3, reason: .unsupportedType), .init(line: 4, reason: .missingPassword)])
        #expect(throws: PasswordCSVImport.Failure.malformed(line: 2)) {
            try PasswordCSVImport.parse(Data("name,url,username,password\nX,https://example.test,,\"unfinished".utf8))
        }
        #expect(throws: PasswordCSVImport.Failure.unsupportedHeader) {
            try PasswordCSVImport.parse(Data("name,title,url,username,password\n".utf8))
        }
        #expect(throws: PasswordCSVImport.Failure.invalidEncoding) { try PasswordCSVImport.parse(Data([0xFF])) }
        #expect(throws: PasswordCSVImport.Failure.limitExceeded) {
            try PasswordCSVImport.parse(Data(repeating: 0, count: PasswordCSVImport.maxFileBytes + 1))
        }
    }

    @Test func duplicateComparisonPreservesPasswordBytesAndFullURLs() {
        let item = VaultItem(title: "Login", username: "user", password: "é", website: "https://example.test/a")
        var changed = item
        changed.password = "e\u{301}"
        #expect(PasswordCSVImport.MatchKey(item) != PasswordCSVImport.MatchKey(changed))
        changed = item
        changed.website = "https://example.test/b"
        #expect(PasswordCSVImport.MatchKey(item) != PasswordCSVImport.MatchKey(changed))
        changed = item
        changed.id = UUID()
        #expect(PasswordCSVImport.MatchKey(item) == PasswordCSVImport.MatchKey(changed))
    }

    @Test func preparationSkipsDuplicatesAndOversizeWithoutPublishingPasswords() async throws {
        let crypto = VaultCrypto()
        _ = try await crypto.create(password: "a synthetic CSV test password")
        let input = "name,url,username,password,note\nA,https://example.test,me,pw,\nA,https://example.test,me,pw,\nA,https://example.test,me,changed,\nBig,,,pw," + String(repeating: "n", count: 262_144)
        let parsed = try PasswordCSVImport.parse(Data(input.utf8))
        let first = try await PasswordCSVImport.prepare(parsed, existing: [], crypto: crypto)
        #expect(first.candidates.count == 2)
        #expect(first.issues == [.init(line: 3, reason: .duplicate), .init(line: 5, reason: .oversized)])
        let existing = try await crypto.entries(from: first.candidates.map(\.revision))
        #expect(Set(existing.map(\.item.password)) == ["pw", "changed"])
        let repeated = try await PasswordCSVImport.prepare(parsed, existing: existing, crypto: crypto)
        #expect(repeated.candidates.isEmpty)
        #expect(repeated.issues.count == 4)
    }

    @Test func appendChecksTheSnapshotAndWritesOnlySelectedRevisions() async throws {
        let store = try VaultStore.make(inMemory: true)
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: "a synthetic CSV test password")
        try await store.saveHeader(created.header)
        let snapshot = try await store.snapshot()
        let selected = try await crypto.encrypt(VaultItem(title: "Selected"), parents: [])
        let unselected = try await crypto.encrypt(VaultItem(title: "Unselected"), parents: [])
        let result = try await store.appendImportedRevisions([selected], expected: snapshot)
        #expect(result.insertedRevisions == 1)
        await #expect(throws: VaultError.vaultChanged) {
            try await store.appendImportedRevisions([unselected], expected: snapshot)
        }
        #expect(try await store.revisions() == [selected])
    }
}
