import AegisCore
import AegisMarkdown
import SwiftUI

struct ItemEditorView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var item: VaultItem
    let parents: [UUID]
    @State private var saving = false
    @State private var showPassword = false

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text(parents.isEmpty ? "editor.new" : "editor.edit"), subtitle: L10n.text("ui.editorSubtitle"), symbol: item.kind.symbol, close: { dismiss() })
            Divider().overlay(AegisTheme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 8) {
                        ForEach(ItemKind.allCases) { kind in
                            Button { item.kind = kind } label: {
                                Label(kind.title, systemImage: kind.symbol).font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .foregroundStyle(item.kind == kind ? AegisTheme.teal : AegisTheme.secondary)
                                    .background(item.kind == kind ? AegisTheme.selected : AegisTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(item.kind == kind ? AegisTheme.teal.opacity(0.24) : AegisTheme.border))
                            }.buttonStyle(.plain).accessibilityAddTraits(item.kind == kind ? [.isSelected] : [])
                        }
                    }
                    AegisInput(title: L10n.text("field.title")) {
                        TextField(L10n.text("editor.titlePlaceholder"), text: $item.title).accessibilityIdentifier("itemTitle")
                    }
                    if item.kind == .login { loginFields }
                    if item.kind == .card { cardFields }
                    markdownEditor
                    Toggle(isOn: $item.isFavorite) {
                        Label(L10n.text("field.favorite"), systemImage: "star").font(.system(size: 13)).foregroundStyle(AegisTheme.text)
                    }.toggleStyle(.switch).tint(AegisTheme.teal).padding(16).aegisSurface()
                }.padding(24)
            }.scrollDismissesKeyboard(.interactively)
            Divider().overlay(AegisTheme.border)
            HStack(spacing: 12) {
                Label(L10n.text("ui.savedEncrypted"), systemImage: "lock").font(.system(size: 11)).foregroundStyle(AegisTheme.secondary)
                Spacer(minLength: 0)
                Button(L10n.text("action.cancel")) { dismiss() }.buttonStyle(AegisButtonStyle()).disabled(saving)
                Button {
                    saving = true
                    item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { if await session.save(item, parents: parents) { dismiss() }; saving = false }
                } label: {
                    HStack(spacing: 8) { if saving { ProgressView().controlSize(.small).tint(.white) }; Text(L10n.text("action.save")) }
                }.buttonStyle(AegisButtonStyle(primary: true))
                    .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    .accessibilityIdentifier("saveItemButton")
            }.padding(20).background(AegisTheme.surface)
        }.background(AegisTheme.background).aegisSheetSize(width: 620, height: 760)
            .interactiveDismissDisabled(saving).privacySensitive().autocorrectionDisabled()
            .onChange(of: item) { _, _ in session.touch() }
    }
    private var loginFields: some View {
        VStack(spacing: 18) {
            AegisInput(title: L10n.text("field.username"), icon: "person") {
                TextField(L10n.text("field.username"), text: $item.username).textContentType(.username).aegisNoCapitalization()
            }
            VStack(alignment: .leading, spacing: 10) {
                AegisInput(title: L10n.text("field.password"), icon: "key.horizontal") {
                    Group {
                        if showPassword { TextField(L10n.text("field.password"), text: $item.password) }
                        else { SecureField(L10n.text("field.password"), text: $item.password).textContentType(.newPassword) }
                    }.aegisNoCapitalization()
                    Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(AegisTheme.secondary) }
                        .buttonStyle(.plain).accessibilityLabel(L10n.text(showPassword ? "action.hide" : "action.show"))
                }
                Button {
                    do { item.password = try PasswordGenerator.generate(options: session.passwordOptions) }
                    catch { session.error = error.localizedDescription }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                        Text(L10n.text("editor.generate"))
                        Spacer()
                        Text(L10n.format("generator.characters", Int64(session.passwordOptions.length))).foregroundStyle(AegisTheme.secondary)
                    }.font(.system(size: 12, weight: .medium)).foregroundStyle(AegisTheme.teal)
                }.buttonStyle(.plain).padding(.horizontal, 3)
            }
            AegisInput(title: L10n.text("field.website"), icon: "globe") {
                TextField(L10n.text("editor.websitePlaceholder"), text: $item.website).textContentType(.URL).aegisNoCapitalization()
            }
        }
    }
    private var cardFields: some View {
        VStack(spacing: 18) {
            AegisInput(title: L10n.text("field.cardholder"), icon: "person") { TextField(L10n.text("field.cardholder"), text: $item.cardholder) }
            AegisInput(title: L10n.text("field.cardNumber"), icon: "creditcard") { TextField(L10n.text("field.cardNumber"), text: $item.cardNumber).textContentType(.creditCardNumber) }
            HStack(spacing: 14) {
                AegisInput(title: L10n.text("field.expiry")) { TextField(L10n.text("field.expiry"), text: $item.expiry) }
                AegisInput(title: L10n.text("field.securityCode")) { SecureField(L10n.text("field.securityCode"), text: $item.securityCode) }
            }
        }
    }
    private var markdownEditor: some View {
        MarkdownComposer(text: $item.notes,
                         title: L10n.text(item.kind == .note ? "field.secureNote" : "field.notes"),
                         recordTitle: item.title)
    }
}
