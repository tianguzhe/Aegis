import Foundation

/// All product copy is owned by the package String Catalog. Add locales there, not in views.
public enum L10n {
    public static func text(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .module)
    }
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: .current, arguments: arguments)
    }
}
