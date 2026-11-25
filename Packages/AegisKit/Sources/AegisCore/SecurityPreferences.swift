import Foundation

public enum AutoLockTimeout: Int, Codable, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1800

    public var id: Int {
        rawValue
    }

    public var seconds: Int {
        rawValue
    }

    public var minutes: Int {
        rawValue / 60
    }

    public var title: String {
        L10n.format("security.minutes", Int64(minutes))
    }
}

public enum ClipboardTimeout: Int, Codable, CaseIterable, Identifiable, Sendable {
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case sixtySeconds = 60
    case twoMinutes = 120

    public var id: Int {
        rawValue
    }

    public var seconds: Int {
        rawValue
    }

    public var title: String {
        if seconds >= 60, seconds % 60 == 0 {
            return L10n.format("security.minutes", Int64(seconds / 60))
        }
        return L10n.format("security.seconds", Int64(seconds))
    }
}

public struct SecuritySettings: Codable, Equatable, Sendable {
    public var autoLock: AutoLockTimeout
    public var clipboardClear: ClipboardTimeout

    public init(autoLock: AutoLockTimeout = .fiveMinutes, clipboardClear: ClipboardTimeout = .thirtySeconds) {
        self.autoLock = autoLock
        self.clipboardClear = clipboardClear
    }

    enum CodingKeys: String, CodingKey {
        case autoLock, clipboardClear
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoLock = (try? container.decodeIfPresent(AutoLockTimeout.self, forKey: .autoLock)) ?? .fiveMinutes
        clipboardClear = (try? container.decodeIfPresent(ClipboardTimeout.self, forKey: .clipboardClear)) ?? .thirtySeconds
    }
}

public enum SecurityPreferences {
    private static let key = "aegis.security-settings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> SecuritySettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(SecuritySettings.self, from: data)
        else { return .init() }
        return settings
    }

    public static func save(_ settings: SecuritySettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
