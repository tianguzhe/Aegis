import AegisCore
import Testing

struct QuickCopyTests {
    @Test func loginOffersUsernameThenPassword() {
        let item = VaultItem(kind: .login, username: "me", password: "pw")
        #expect(item.quickCopyFields == [
            .init(actionKey: "action.copyUsername", value: "me"),
            .init(actionKey: "action.copyPassword", value: "pw"),
        ])
    }

    @Test func cardOffersNumberThenSecurityCode() {
        var item = VaultItem(kind: .card, username: "ignored", password: "ignored")
        item.cardNumber = "4242"; item.securityCode = "123"
        #expect(item.quickCopyFields == [
            .init(actionKey: "action.copyCardNumber", value: "4242"),
            .init(actionKey: "action.copySecurityCode", value: "123"),
        ])
    }

    @Test func noteOffersNothing() {
        #expect(VaultItem(kind: .note, password: "ignored").quickCopyFields.isEmpty)
    }
}
