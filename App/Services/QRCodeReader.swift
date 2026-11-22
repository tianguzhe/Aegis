import AegisCore
import Foundation
import ImageIO
import Vision

/// Reads a two-factor QR code from an image the user picked. No camera access is needed.
enum QRCodeReader {
    enum Failure: Error, LocalizedError {
        case unreadableImage, noCode
        var errorDescription: String? {
            switch self {
            case .unreadableImage: L10n.text("totp.error.image")
            case .noCode: L10n.text("totp.error.noQRCode")
            }
        }
    }

    /// Screenshots are a few MB at most; the cap bounds memory for arbitrary user files.
    static let maxImageBytes = 30 * 1024 * 1024

    /// Returns the first `otpauth://` payload, or else the first QR payload, so the parser can report why it is unusable.
    static func payload(in data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard data.count <= maxImageBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadableImage }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
            guard let payload = payloads.first(where: { $0.lowercased().hasPrefix("otpauth://") }) ?? payloads.first else { throw Failure.noCode }
            return payload
        }.value
    }

    static func payload(at url: URL) async throws -> String {
        let data = try await Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxImageBytes else { throw Failure.unreadableImage }
            return try Data(contentsOf: url)
        }.value
        return try await payload(in: data)
    }
}
