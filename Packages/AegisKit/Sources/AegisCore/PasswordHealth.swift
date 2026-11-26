import CryptoKit
import Foundation

/// Offline password health audit across active login entries.
public enum PasswordHealth {
    public static let agedThresholdDays = 180

    public struct WeakEntry: Identifiable, Equatable, Sendable {
        public var id: UUID {
            entry.id
        }

        public let entry: VaultEntry
        public let evaluation: PasswordStrength.Evaluation

        public init(entry: VaultEntry, evaluation: PasswordStrength.Evaluation) {
            self.entry = entry
            self.evaluation = evaluation
        }
    }

    public struct ReusedGroup: Identifiable, Equatable, Sendable {
        public let id: String
        public let entries: [VaultEntry]

        public init(id: String, entries: [VaultEntry]) {
            self.id = id
            self.entries = entries
        }
    }

    public struct AgedEntry: Identifiable, Equatable, Sendable {
        public var id: UUID {
            entry.id
        }

        public let entry: VaultEntry
        public let ageDays: Int

        public init(entry: VaultEntry, ageDays: Int) {
            self.entry = entry
            self.ageDays = ageDays
        }
    }

    public struct Report: Equatable, Sendable {
        public let totalLogins: Int
        public let loginsWithPassword: Int
        public let weak: [WeakEntry]
        public let reusedGroups: [ReusedGroup]
        public let aged: [AgedEntry]
        public let score: Int
        public let affectedEntryCount: Int

        public var reusedEntryCount: Int {
            reusedGroups.reduce(0) { $0 + $1.entries.count }
        }

        public var isHealthy: Bool {
            weak.isEmpty && reusedGroups.isEmpty && aged.isEmpty
        }

        public init(totalLogins: Int, loginsWithPassword: Int, weak: [WeakEntry],
                    reusedGroups: [ReusedGroup], aged: [AgedEntry], score: Int, affectedEntryCount: Int)
        {
            self.totalLogins = totalLogins
            self.loginsWithPassword = loginsWithPassword
            self.weak = weak
            self.reusedGroups = reusedGroups
            self.aged = aged
            self.score = score
            self.affectedEntryCount = affectedEntryCount
        }
    }

    public static func analyze(_ entries: [VaultEntry], now: Date = Date(),
                               agedThresholdDays: Int = agedThresholdDays) -> Report
    {
        let activeLogins = entries.filter { $0.item.kind == .login && $0.item.deletedAt == nil && !$0.item.archived }
        let withPassword = activeLogins.filter { !$0.item.password.isEmpty }
        guard !withPassword.isEmpty else {
            return Report(totalLogins: activeLogins.count, loginsWithPassword: 0,
                          weak: [], reusedGroups: [], aged: [], score: 100, affectedEntryCount: 0)
        }

        var weakEntries: [WeakEntry] = []
        var byPassword: [String: [VaultEntry]] = [:]
        var agedEntries: [AgedEntry] = []
        var affectedIDs: Set<UUID> = []

        let secondsPerDay = 86400.0
        for entry in withPassword {
            let evaluation = PasswordStrength.evaluate(entry.item.password)
            if evaluation.level == .weak {
                weakEntries.append(WeakEntry(entry: entry, evaluation: evaluation))
                affectedIDs.insert(entry.id)
            }
            byPassword[entry.item.password, default: []].append(entry)

            let elapsed = now.timeIntervalSince(entry.item.modifiedAt)
            let days = Int(floor(elapsed / secondsPerDay))
            if days >= agedThresholdDays {
                agedEntries.append(AgedEntry(entry: entry, ageDays: days))
                affectedIDs.insert(entry.id)
            }
        }

        let reusedGroups: [ReusedGroup] = byPassword.values
            .filter { $0.count >= 2 }
            .map { group in
                let sorted = group.sorted { $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending }
                for entry in sorted {
                    affectedIDs.insert(entry.id)
                }
                // Identify the group deterministically by its member IDs without retaining the raw password as an ID.
                let material = sorted.map(\.id.uuidString).joined(separator: "|")
                let digest = SHA256.hash(data: Data(material.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                return ReusedGroup(id: digest, entries: sorted)
            }
            .sorted { lhs, rhs in
                if lhs.entries.count != rhs.entries.count {
                    return lhs.entries.count > rhs.entries.count
                }
                return (lhs.entries.first?.item.title ?? "") < (rhs.entries.first?.item.title ?? "")
            }

        weakEntries.sort { lhs, rhs in
            if lhs.evaluation.score != rhs.evaluation.score {
                return lhs.evaluation.score < rhs.evaluation.score
            }
            return lhs.entry.item.title.localizedStandardCompare(rhs.entry.item.title) == .orderedAscending
        }

        agedEntries.sort { lhs, rhs in
            if lhs.ageDays != rhs.ageDays {
                return lhs.ageDays > rhs.ageDays
            }
            return lhs.entry.item.title.localizedStandardCompare(rhs.entry.item.title) == .orderedAscending
        }

        let total = Double(withPassword.count)
        let weakPenalty = (Double(weakEntries.count) / total) * 45.0
        let reusedCount = reusedGroups.reduce(0) { $0 + $1.entries.count }
        let reusedPenalty = (Double(reusedCount) / total) * 40.0
        let agedPenalty = (Double(agedEntries.count) / total) * 15.0
        let score = max(0, min(100, Int((100.0 - weakPenalty - reusedPenalty - agedPenalty).rounded())))

        return Report(
            totalLogins: activeLogins.count,
            loginsWithPassword: withPassword.count,
            weak: weakEntries,
            reusedGroups: reusedGroups,
            aged: agedEntries,
            score: score,
            affectedEntryCount: affectedIDs.count
        )
    }
}
