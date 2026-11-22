import AegisCore
import Foundation
import Testing

struct OneTimePasswordTests {
    private static let sha1Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    private static let sha256Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA"
    private static let sha512Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA"

    /// RFC 6238 Appendix B: time, SHA1, SHA256, SHA512 (8 digits, 30 seconds).
    private static let vectors: [(TimeInterval, String, String, String)] = [
        (59, "94287082", "46119246", "90693936"),
        (1_111_111_109, "07081804", "68084774", "25091201"),
        (1_111_111_111, "14050471", "67062674", "99943326"),
        (1_234_567_890, "89005924", "91819424", "93441116"),
        (2_000_000_000, "69279037", "90698825", "38618901"),
        (20_000_000_000, "65353130", "77737706", "47863826"),
    ]

    @Test func matchesRFC6238Vectors() throws {
        let sha1 = try OneTimePassword.parse("otpauth://totp/t?secret=\(Self.sha1Secret)&digits=8")
        let sha256 = try OneTimePassword.parse("otpauth://totp/t?secret=\(Self.sha256Secret)&digits=8&algorithm=SHA256")
        let sha512 = try OneTimePassword.parse("otpauth://totp/t?secret=\(Self.sha512Secret)&digits=8&algorithm=sha512")
        for (time, expected1, expected256, expected512) in Self.vectors {
            let date = Date(timeIntervalSince1970: time)
            #expect(sha1.code(at: date) == expected1)
            #expect(sha256.code(at: date) == expected256)
            #expect(sha512.code(at: date) == expected512)
        }
    }

    @Test func bareBase32UsesDefaults() throws {
        let otp = try OneTimePassword.parse("  gezd gnbv gy3t qojq gezd gnbv gy3t qojq== \n")
        #expect(otp.algorithm == .sha1)
        #expect(otp.digits == 6)
        #expect(otp.period == 30)
        #expect(otp.code(at: Date(timeIntervalSince1970: 59)) == "287082")
        #expect(otp.secondsRemaining(at: Date(timeIntervalSince1970: 59)) == 1)
        #expect(otp.secondsRemaining(at: Date(timeIntervalSince1970: 60)) == 30)
    }

    @Test func secretToleratesLineBreaksFromCopiedText() throws {
        let otp = try OneTimePassword.parse("GEZDGNBVGY3TQOJQ\nGEZDGNBV\tGY3TQOJQ")
        #expect(otp.code(at: Date(timeIntervalSince1970: 59)) == "287082")
    }

    @Test func canonicalURIRoundTrips() throws {
        let otp = try OneTimePassword.parse("otpauth://totp/Example%20Co:me@example.com?secret=\(Self.sha1Secret)&period=60&digits=8")
        #expect(otp.issuer == "Example Co")
        #expect(otp.account == "me@example.com")
        let reparsed = try OneTimePassword.parse(otp.uri)
        #expect(reparsed == otp)
        #expect(reparsed.uri == otp.uri)
        #expect(otp.uri.hasPrefix("otpauth://totp/"))
    }

    @Test func canonicalURIEscapesReservedCharacters() throws {
        let otp = try OneTimePassword.parse("otpauth://totp/x?secret=\(Self.sha1Secret)&issuer=AT%26T%3D1%2B2%23")
        #expect(otp.issuer == "AT&T=1+2#")
        // "+" must be escaped too: many authenticators decode it as a space.
        #expect(!otp.uri.contains("+") && !otp.uri.contains("#"))
        let reparsed = try OneTimePassword.parse(otp.uri)
        #expect(reparsed.issuer == "AT&T=1+2#")
    }

    @Test func labelColonInsideAccountSurvivesRoundTrip() throws {
        let otp = try OneTimePassword.parse("otpauth://totp/Corp%3AEU:team%3Ame?secret=\(Self.sha1Secret)")
        #expect(otp.issuer == "Corp:EU")
        #expect(otp.account == "team:me")
        let reparsed = try OneTimePassword.parse(otp.uri)
        #expect(reparsed.issuer == otp.issuer)
        #expect(reparsed.account == otp.account)
    }

    @Test func escapedSeparatorStillSplitsLabel() throws {
        let otp = try OneTimePassword.parse("otpauth://totp/Example%3Ame?secret=\(Self.sha1Secret)")
        #expect(otp.issuer == "Example")
        #expect(otp.account == "me")
    }

    @Test func issuerParameterWinsOverLabel() throws {
        let otp = try OneTimePassword.parse("otpauth://totp/Old:me?secret=\(Self.sha1Secret)&issuer=New")
        #expect(otp.issuer == "New")
        #expect(otp.account == "me")
    }

    @Test func rejectsHOTPExplicitly() {
        #expect(throws: OneTimePassword.Failure.unsupportedCounterBased) {
            try OneTimePassword.parse("otpauth://hotp/t?secret=\(Self.sha1Secret)&counter=1")
        }
    }

    @Test(arguments: [
        "",
        "not base32 !",
        "GEZDGNBV", // shorter than 80 bits
        "otpauth://totp/t",
        "otpauth://totp/t?secret=\(sha1Secret)&digits=5",
        "otpauth://totp/t?secret=\(sha1Secret)&digits=9",
        "otpauth://totp/t?secret=\(sha1Secret)&period=0",
        "otpauth://totp/t?secret=\(sha1Secret)&period=301",
        "otpauth://totp/t?secret=\(sha1Secret)&algorithm=MD5",
        "https://example.com/?secret=\(sha1Secret)",
    ])
    func rejectsInvalidInput(_ input: String) {
        #expect(throws: OneTimePassword.Failure.invalid) { try OneTimePassword.parse(input) }
    }

    @Test func itemExposesCodeOnlyForLogins() {
        var login = VaultItem(kind: .login)
        login.oneTimePassword = Self.sha1Secret
        #expect(login.oneTimeCode(at: Date(timeIntervalSince1970: 59)) == "287082")
        var card = VaultItem(kind: .card)
        card.oneTimePassword = Self.sha1Secret
        #expect(card.oneTimeCode(at: Date()) == nil)
        #expect(VaultItem(kind: .login).oneTimeCode(at: Date()) == nil)
    }
}
