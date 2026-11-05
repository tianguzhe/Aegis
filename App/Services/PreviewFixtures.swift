#if DEBUG
import AegisCore

/// Synthetic in-memory data for visual QA; never used by a release build or synchronized.
enum PreviewFixtures {
    static var items: [VaultItem] {
        var card = VaultItem(kind: .card, title: L10n.text("preview.cardTitle"), notes: L10n.text("preview.cardNotes"))
        card.cardholder = "AEGIS DEMO"; card.cardNumber = "4242 4242 4242 4242"; card.expiry = "12/30"; card.securityCode = "123"
        return [
            VaultItem(title: "Apple", username: "hello@example.com", password: "Preview-Only-Not-A-Credential", website: "https://apple.com", isFavorite: true),
            VaultItem(title: "GitHub", username: "aegis-demo", password: "Preview-Only-Not-A-Credential", website: "https://github.com", isFavorite: true),
            VaultItem(title: "Figma", username: "design@example.com", password: "Preview-Only-Not-A-Credential", website: "https://figma.com"),
            VaultItem(title: "Notion", username: "hello@example.com", password: "Preview-Only-Not-A-Credential", website: "https://notion.so"),
            VaultItem(title: "Linear", username: "work@example.com", password: "Preview-Only-Not-A-Credential", website: "https://linear.app"),
            card,
            VaultItem(kind: .note, title: L10n.text("preview.noteTitle"), notes: L10n.text("preview.noteBody"))
        ]
    }
}
#endif
