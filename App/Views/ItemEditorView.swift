import AegisCore
import AegisMarkdown
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ItemEditorView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var item: VaultItem
    @State private var baseline: VaultItem
    @State private var parents: [UUID]
    @State private var saving = false
    @State private var showPassword = false
    @State private var confirmClose = false
    @State private var loaded = false
    @State private var draftObserverID = UUID()
    @State private var expandedEditorActive = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private var isDirty: Bool { item != baseline }
    private var cardNumberValidation: CardNumberValidation { CardNumberRules.validate(item.cardNumber) }
    private var canSave: Bool {
        !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (item.kind != .card || cardNumberValidation.allowsSaving)
    }

    init(item: VaultItem, parents: [UUID]) {
        _item = State(initialValue: item)
        _baseline = State(initialValue: item)
        _parents = State(initialValue: parents)
    }

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text(parents.isEmpty ? "editor.new" : "editor.edit"), subtitle: L10n.text("ui.editorSubtitle"), symbol: item.kind.symbol, close: requestClose, closeDisabled: saving)
                .background(AegisTheme.background)
                .zIndex(1)
            Divider().overlay(AegisTheme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: item.kind == .card ? 20 : 26) {
                    typeChoiceLayout {
                        ForEach(ItemKind.allCases) { kind in
                            Button {
                                if kind == .card && item.kind != .card && item.cardBrand == nil && item.cardType == nil {
                                    item.cardBrand = .unionPay; item.cardType = .debit
                                }
                                item.kind = kind
                            } label: {
                                Label(kind.title, systemImage: kind.symbol).aegisFont(size: 12, weight: .medium)
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .foregroundStyle(item.kind == kind ? AegisTheme.teal : AegisTheme.secondary)
                                    .background(item.kind == kind ? AegisTheme.selected : AegisTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(item.kind == kind ? AegisTheme.teal.opacity(0.24) : AegisTheme.border))
                            }.buttonStyle(.plain).accessibilityAddTraits(item.kind == kind ? [.isSelected] : [])
                                .accessibilityIdentifier("itemKind-\(kind.rawValue)")
                        }
                    }
                    AegisInput(title: L10n.text("field.title")) {
                        TextField(L10n.text("editor.titlePlaceholder"), text: $item.title).accessibilityIdentifier("itemTitle")
                    }
                    if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label(L10n.text("editor.titleRequiredHint"), systemImage: "info.circle")
                            .aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
                    }
                    if item.kind == .login { loginFields }
                    if item.kind == .card { cardFields }
                    markdownEditor
                    Toggle(isOn: $item.isFavorite) {
                        Label(L10n.text("field.favorite"), systemImage: "star").aegisFont(size: 13).foregroundStyle(AegisTheme.text)
                    }.toggleStyle(.switch).tint(AegisTheme.teal).padding(16).aegisSurface()
                }.padding(24)
            }.scrollDismissesKeyboard(.interactively).disabled(saving).accessibilityIdentifier("itemEditorScroll")
            Divider().overlay(AegisTheme.border)
            footerLayout {
                Label(L10n.text(isDirty ? "draft.protected" : "ui.savedEncrypted"), systemImage: "lock").aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button(L10n.text("action.cancel"), action: requestClose).buttonStyle(AegisButtonStyle()).disabled(saving)
                Button {
                    guard !saving, canSave else { return }
                    saving = true
                    item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if item.kind == .card { item.cardNumber = CardNumberRules.digits(from: item.cardNumber) }
                    Task { if await session.save(item, parents: parents) { baseline = item; session.discardDraft(item.id); dismiss() }; saving = false }
                } label: {
                    HStack(spacing: 8) { if saving { ProgressView().controlSize(.small).tint(AegisTheme.disabledText) }; Text(L10n.text(saving ? "action.saving" : "action.save")) }
                }.buttonStyle(AegisButtonStyle(primary: true))
                    .disabled(!canSave || saving)
                    .accessibilityIdentifier("saveItemButton")
            }.padding(20).background(AegisTheme.surface)
        }.background(AegisTheme.background).aegisSheetSize(width: 620, height: 760)
            .interactiveDismissDisabled(saving || isDirty).privacySensitive().autocorrectionDisabled()
            .onAppear {
                if !loaded {
                    if let saved = session.recoverableDrafts.first(where: { $0.id == item.id }) {
                        item = saved.item; baseline = saved.original; parents = saved.parents
                    }
                    loaded = true
                }
                session.observeDraft(draftObserverID) { VaultDraft(item: item, original: baseline, parents: parents) }
            }
            .onDisappear { if !expandedEditorActive { session.stopObservingDraft(draftObserverID) } }
            .onChange(of: item) { _, _ in
                guard loaded, !saving else { return }
                session.retainDraft(VaultDraft(item: item, original: baseline, parents: parents))
                session.touch()
            }
            .confirmationDialog(L10n.text("draft.closeTitle"), isPresented: $confirmClose, titleVisibility: .visible) {
                Button(L10n.text("draft.keepAndClose")) {
                    session.retainDraft(VaultDraft(item: item, original: baseline, parents: parents)); dismiss()
                }
                Button(L10n.text("draft.discard"), role: .destructive) { session.discardDraft(item.id); dismiss() }
                Button(L10n.text("draft.continue"), role: .cancel) {}
            } message: { Text(L10n.text("draft.closeMessage")) }
            .vaultErrorPresenter()
            #if os(macOS)
            .onExitCommand(perform: requestClose)
            #else
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.text("composer.hideKeyboard")) {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }.accessibilityIdentifier("dismissEditorKeyboard")
                }
            }
            #endif
    }
    private func requestClose() {
        guard !saving else { return }
        if isDirty { confirmClose = true } else { dismiss() }
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
                    Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(AegisTheme.secondary).frame(width: 44, height: 44).contentShape(Rectangle()) }
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
                    }.aegisFont(size: 12, weight: .medium).foregroundStyle(AegisTheme.teal)
                }.buttonStyle(.plain).padding(.horizontal, 3)
            }
            AegisInput(title: L10n.text("field.website"), icon: "globe") {
                TextField(L10n.text("editor.websitePlaceholder"), text: $item.website).textContentType(.URL).aegisNoCapitalization()
            }
        }
    }
    private var cardFields: some View {
        VStack(spacing: 18) {
            CardAppearancePicker(item: $item)
            AegisInput(title: L10n.text("field.cardholder"), icon: "person") { TextField(L10n.text("field.cardholder"), text: $item.cardholder) }
            VStack(alignment: .leading, spacing: 8) {
                AegisInput(title: L10n.text("field.cardNumber"), icon: "creditcard") {
                    CardNumberField(text: $item.cardNumber)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(cardNumberValidation.message, systemImage: cardNumberValidation == .valid ? "checkmark.circle.fill" :
                            cardNumberValidation == .empty ? "info.circle" : "exclamationmark.circle")
                        .foregroundStyle(cardNumberValidation == .valid ? AegisTheme.teal :
                                            cardNumberValidation == .empty ? AegisTheme.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(L10n.format("card.number.count", Int64(CardNumberRules.digits(from: item.cardNumber).count), Int64(CardNumberRules.maximumLength)))
                        .monospacedDigit().foregroundStyle(cardNumberValidation == .tooLong ? Color.red : AegisTheme.secondary)
                        .fixedSize().accessibilityIdentifier("cardNumberCount")
                }.aegisFont(size: 11)
            }
            cardFieldLayout {
                AegisInput(title: L10n.text("field.expiry")) { TextField(L10n.text("field.expiry"), text: $item.expiry) }
                AegisInput(title: L10n.text("field.securityCode")) { SecureField(L10n.text("field.securityCode"), text: $item.securityCode) }
            }
        }
    }
    private var cardFieldLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 18)) : AnyLayout(HStackLayout(spacing: 14))
    }
    private var markdownEditor: some View {
        MarkdownComposer(text: $item.notes,
                         title: L10n.text(item.kind == .note ? "field.secureNote" : "field.notes"),
                         recordTitle: item.title, expanded: $expandedEditorActive)
    }
    private var typeChoiceLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
    }
    private var footerLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
    }
}
