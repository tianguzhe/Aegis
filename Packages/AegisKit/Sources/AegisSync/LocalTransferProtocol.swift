import AegisCore
import Foundation

public enum LocalTransferError: Error, LocalizedError, Sendable {
    case invalidMessage, connectionLost, authenticationFailed, expired, comparisonRejected

    public var errorDescription: String? {
        switch self {
        case .invalidMessage: L10n.text("lan.error.invalidMessage")
        case .connectionLost: L10n.text("lan.error.connectionLost")
        case .authenticationFailed: L10n.text("lan.error.authentication")
        case .expired: L10n.text("lan.error.expired")
        case .comparisonRejected: L10n.text("lan.pair.rejectError")
        }
    }
}
