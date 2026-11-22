import CryptoKit
import Foundation

/// Time-based one-time password (RFC 6238) parsed from an `otpauth://totp` URI or a bare Base32 secret.
///
/// HOTP (RFC 4226 counters) is rejected on purpose: the counter is mutable state, so every
/// use would write a new revision and two devices advancing the same counter would create
/// conflicts that cannot be merged.
public struct OneTimePassword: Equatable, Sendable {
    public enum Algorithm: String, Sendable, CaseIterable {
        case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case invalid, unsupportedCounterBased
        public var errorDescription: String? {
            switch self {
            case .invalid: L10n.text("totp.error.invalid")
            case .unsupportedCounterBased: L10n.text("totp.error.hotp")
            }
        }
    }

    public let secret: Data
    public let algorithm: Algorithm
    public let digits: Int
    public let period: Int
    public let issuer: String
    public let account: String

    static let digitRange = 6 ... 8
    static let periodRange = 1 ... 300
    /// 80 bits is the shortest secret in common use; anything shorter is almost certainly a typo.
    static let minimumSecretBytes = 10

    /// Accepts an `otpauth://totp/...` URI or a bare Base32 secret (case, whitespace and padding ignored).
    /// - Throws: `Failure.unsupportedCounterBased` for `otpauth://hotp`, otherwise `Failure.invalid`.
    public static func parse(_ input: String) throws -> OneTimePassword {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("otpauth://") else {
            return try OneTimePassword(secret: base32Decode(text), algorithm: .sha1, digits: 6, period: 30, issuer: "", account: "")
        }
        guard let components = URLComponents(string: text) else { throw Failure.invalid }
        switch components.host?.lowercased() {
        case "totp": break
        case "hotp": throw Failure.unsupportedCounterBased
        default: throw Failure.invalid
        }
        func query(_ name: String) -> String? {
            components.queryItems?.first { $0.name.lowercased() == name }?.value
        }
        guard let rawSecret = query("secret") else { throw Failure.invalid }
        var algorithm = Algorithm.sha1
        if let raw = query("algorithm") {
            guard let parsed = Algorithm(rawValue: raw.uppercased()) else { throw Failure.invalid }
            algorithm = parsed
        }
        let digits = try query("digits").map { try integer($0) } ?? 6
        let period = try query("period").map { try integer($0) } ?? 30
        // The label is "Issuer:account" or just "account"; the issuer parameter takes precedence.
        // Split on a literal ":" before decoding so an escaped colon inside the issuer or account
        // survives; labels that only use an escaped "%3A" separator fall back to the decoded form.
        let encodedLabel = String(components.percentEncodedPath.drop { $0 == "/" })
        let rawParts = encodedLabel.contains(":")
            ? encodedLabel.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map { $0.removingPercentEncoding ?? String($0) }
            : (encodedLabel.removingPercentEncoding ?? encodedLabel).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let parts = rawParts.map { $0.trimmingCharacters(in: .whitespaces) }
        let account = parts.last ?? ""
        let issuer = query("issuer") ?? (parts.count == 2 ? parts[0] : "")
        return try OneTimePassword(secret: base32Decode(rawSecret), algorithm: algorithm, digits: digits, period: period,
                                   issuer: issuer, account: account)
    }

    private init(secret: Data, algorithm: Algorithm, digits: Int, period: Int, issuer: String, account: String) throws {
        guard secret.count >= Self.minimumSecretBytes, Self.digitRange.contains(digits), Self.periodRange.contains(period) else {
            throw Failure.invalid
        }
        self.secret = secret; self.algorithm = algorithm; self.digits = digits; self.period = period
        self.issuer = issuer; self.account = account
    }

    /// Canonical form stored in the vault. Every parameter is explicit so future defaults cannot change existing codes.
    /// Values are escaped with RFC 3986 unreserved characters only: Foundation leaves "+" unescaped,
    /// and many authenticators decode "+" as a space, so the default query encoding is not portable.
    public var uri: String {
        let label = [issuer, account].filter { !$0.isEmpty }.map(Self.escape).joined(separator: ":")
        let query: [(String, String)?] = [
            ("secret", Self.base32Encode(secret)),
            issuer.isEmpty ? nil : ("issuer", issuer),
            ("algorithm", algorithm.rawValue),
            ("digits", String(digits)),
            ("period", String(period)),
        ]
        let encoded = query.compactMap(\.self).map { "\($0.0)=\(Self.escape($0.1))" }.joined(separator: "&")
        return "otpauth://totp/\(label)?\(encoded)"
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    public func code(at date: Date) -> String {
        // Clamp pre-1970 clocks to counter 0 instead of trapping on a negative conversion.
        let counter = UInt64(max(0, date.timeIntervalSince1970) / Double(period))
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac: [UInt8] = switch algorithm {
        case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        // Dynamic truncation, RFC 4226 section 5.3.
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16) |
            (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        let value = binary % UInt32(pow(10, Double(digits)))
        let text = String(value)
        return String(repeating: "0", count: digits - text.count) + text
    }

    public func secondsRemaining(at date: Date) -> Int {
        let elapsed = Int(max(0, date.timeIntervalSince1970)) % period
        return period - elapsed
    }

    private static func integer(_ text: String) throws -> Int {
        guard let value = Int(text) else { throw Failure.invalid }
        return value
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func base32Decode(_ text: String) throws -> Data {
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        // Secrets copied from PDFs or web pages often carry line breaks or tabs between groups.
        for character in text.uppercased() where !character.isWhitespace && character != "=" {
            guard let index = alphabet.firstIndex(of: character) else { throw Failure.invalid }
            buffer = (buffer << 5) | UInt32(index)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return Data(bytes)
    }

    static func base32Encode(_ data: Data) -> String {
        var output = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 {
            output.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
        }
        return output
    }
}

public extension VaultItem {
    /// Current code for a login with a valid secret; nil for other kinds, missing or unreadable secrets.
    /// Saved values are validated by the editor, so nil on a login with a secret means the data was damaged
    /// or came from a newer format; the detail view surfaces that case instead of hiding it.
    func oneTimeCode(at date: Date) -> String? {
        guard kind == .login, let oneTimePassword, let otp = try? OneTimePassword.parse(oneTimePassword) else { return nil }
        return otp.code(at: date)
    }
}
