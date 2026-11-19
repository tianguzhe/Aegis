import AegisCore
import CryptoKit
import Foundation

/// Portable LAN join protocol; see Docs/LOCAL_TRANSFER.md for the byte specification.
public enum LocalTransferProtocol {
    public static let serviceType = "_aegis-join._tcp"
    public static let magic = Data("AEGISLN1".utf8)
    public static let challengeLength = 32
    public static let proofLength = 32
    public static let offerLifetime: TimeInterval = 300

    /// 128 random bits, carried out of band. Never a short numeric PIN or a vault password.
    public static func makeCode() throws -> String {
        try SecureRandom.bytes(count: 16).map { String(format: "%02X", $0) }.joined()
    }

    public static func normalizeCode(_ input: String) throws -> String {
        let value = input.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
        guard value.utf8.count == 32, value.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 70).contains($0) })
        else { throw LocalTransferError.invalidCode }
        return value
    }

    public static func displayCode(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { String(code.dropFirst($0).prefix(4)) }.joined(separator: "-")
    }

    public static func proof(code: String, challenge: Data, receivedFile: Data? = nil) throws -> Data {
        let normalized = try normalizeCode(code)
        guard challenge.count == challengeLength else { throw LocalTransferError.invalidMessage }
        var message = Data((receivedFile == nil ? "aegis.lan.v1.request" : "aegis.lan.v1.received").utf8)
        message.append(magic)
        message.append(challenge)
        if let receivedFile {
            message.append(contentsOf: SHA256.hash(data: receivedFile))
        }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(normalized.utf8))))
    }

    public static func verify(_ proof: Data, code: String, challenge: Data, receivedFile: Data? = nil) throws -> Bool {
        let expected = try self.proof(code: code, challenge: challenge, receivedFile: receivedFile)
        guard proof.count == expected.count else { return false }
        return zip(proof, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func lengthBytes(_ count: Int) throws -> Data {
        guard count > 0, count <= BackupLimits.maxFileLength else { throw LocalTransferError.invalidMessage }
        let value = UInt32(count)
        return Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                     UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    public static func fileLength(_ bytes: Data) throws -> Int {
        guard bytes.count == 4 else { throw LocalTransferError.invalidMessage }
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard value > 0, value <= BackupLimits.maxFileLength else { throw LocalTransferError.invalidMessage }
        return Int(value)
    }
}

public enum LocalTransferError: Error, LocalizedError, Sendable {
    case invalidCode, invalidMessage, connectionLost, authenticationFailed, expired
    public var errorDescription: String? {
        switch self {
        case .invalidCode: L10n.text("lan.error.invalidCode")
        case .invalidMessage: L10n.text("lan.error.invalidMessage")
        case .connectionLost: L10n.text("lan.error.connectionLost")
        case .authenticationFailed: L10n.text("lan.error.authentication")
        case .expired: L10n.text("lan.error.expired")
        }
    }
}
