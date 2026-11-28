import Foundation
import Observation

/// Only the most recently presented surface owns the alert.
@MainActor @Observable
final class VaultPresentationStack {
    private var surfaces: [UUID] = []
    func register(_ id: UUID) {
        surfaces.removeAll { $0 == id }; surfaces.append(id)
    }

    func remove(_ id: UUID) {
        surfaces.removeAll { $0 == id }
    }

    func isTop(_ id: UUID) -> Bool {
        surfaces.last == id
    }
}
