import AegisCore
import AegisMarkdown
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
    import PhotosUI
#endif
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
    @State private var showOneTimePassword = false
    @State private var readingQRCode = false
    #if os(iOS)
        @State private var qrPhoto: PhotosPickerItem?
    #else
        @State private var showQRImporter = false
    #endif
    @State private var confirmClose = false
    @State private var loaded = false
    @State private var draftObserverID = UUID()
    @State private var expandedEditorActive = false
    @State private var tagInput = ""
    private let onSaved: (UUID) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    private var isDirty: Bool {
        item != baseline || !tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var cardNumberValidation: CardNumberValidation {
        CardNumberRules.validate(item.cardNumber)
    }

    private var canSave: Bool {
        !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (item.kind != .card || cardNumberValidation.allowsSaving) &&
            (item.kind != .login || oneTimePasswordError == nil) && !readingQRCode
    }

    /// While editing the field holds raw input; saving stores the canonical URI.
    private var oneTimePasswordText: Binding<String> {
        Binding(get: { item.oneTimePassword ?? "" }, set: { item.oneTimePassword = $0.isEmpty ? nil : $0 })
    }

    private var oneTimePasswordError: String? {
        guard let raw = item.oneTimePassword else { return nil }
        do { _ = try OneTimePassword.parse(raw); return nil } catch { return error.localizedDescription }
    }

    init(item: VaultItem, parents: [UUID], onSaved: @escaping (UUID) -> Void = { _ in }) {
        _item = State(initialValue: item)
        _baseline = State(initialValue: item)
        _parents = State(initialValue: parents)
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text(parents.isEmpty ? "editor.new" : "editor.edit"), subtitle: L10n.text("editor.formHint"), symbol: item.kind.symbol, close: requestClose, closeDisabled: saving)
                .background(AegisTheme.background)
                .zIndex(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    #if os(macOS)
                        Picker(L10n.text("editor.itemType"), selection: $item.kind) {
                            ForEach(ItemKind.allCases) { kind in
                                Label(kind.title, systemImage: kind.symbol).tag(kind)
                            }
                        }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("itemTypePicker")
                    #else
                        typeChoiceLayout {
                            ForEach(ItemKind.allCases) { kind in
                                Button {
                                    if kind == .card, item.kind != .card, item.cardBrand == nil, item.cardType == nil {
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
                    #endif
                    AegisInput(title: L10n.text("field.title")) {
                        TextField(L10n.text("editor.titlePlaceholder"), text: $item.title).accessibilityIdentifier("itemTitle")
                    }
                    if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label(L10n.text("editor.titleRequiredHint"), systemImage: "info.circle")
                            .aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
                    }
                    if item.kind == .login {
                        loginFields
                    }
                    if item.kind == .card {
                        cardFields
                    }
                    markdownEditor
                    tagsEditor
                    Toggle(isOn: $item.isFavorite) {
                        Label(L10n.text("field.favorite"), systemImage: "star").aegisFont(size: 13).foregroundStyle(AegisTheme.text)
                    }.toggleStyle(.switch).tint(AegisTheme.accentFill).padding(16).aegisSurface()
                }.padding(24)
            }.scrollDismissesKeyboard(.interactively).disabled(saving).accessibilityIdentifier("itemEditorScroll")
            Divider().overlay(AegisTheme.border)
            footerLayout {
                Label(L10n.text(isDirty ? "draft.protected" : "ui.savedEncrypted"), systemImage: "lock").aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                }
                Button(L10n.text("action.cancel"), action: requestClose).buttonStyle(AegisButtonStyle()).disabled(saving)
                Button {
                    guard !saving, canSave else { return }
                    saving = true
                    commitTagInput()
                    item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if item.kind == .card {
                        item.cardNumber = CardNumberRules.digits(from: item.cardNumber)
                    }
                    // Only logins carry a secret; canSave already rejected unparsable input.
                    item.oneTimePassword = item.kind == .login ? item.oneTimePassword.flatMap { try? OneTimePassword.parse($0).uri } : nil
                    Task {
                        if await session.save(item, parents: parents) {
                            baseline = item; session.discardDraft(item.id); onSaved(item.id); dismiss()
                        }
                        saving = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if saving {
                            ProgressView().controlSize(.small).tint(AegisTheme.disabledText)
                        }; Text(L10n.text(saving ? "action.saving" : "action.save"))
                    }
                }.buttonStyle(AegisButtonStyle(primary: true))
                    .disabled(!canSave || saving)
                    .accessibilityIdentifier("saveItemButton")
                    .keyboardShortcut("s", modifiers: .command)
            }.padding(.horizontal, 24).padding(.vertical, 16).background(AegisTheme.surface)
        }.background(AegisTheme.background).aegisSheetSize(width: 660, height: 760)
            .interactiveDismissDisabled(saving || isDirty).privacySensitive().autocorrectionDisabled()
            .onAppear {
                if !loaded {
                    if let saved = session.recoverableDrafts.first(where: { $0.id == item.id }) {
                        item = saved.item; baseline = saved.original; parents = saved.parents
                    }
                    loaded = true
                }
                session.observeDraft(draftObserverID) {
                    var draftItem = item
                    let pending = VaultItem.parseTags(tagInput)
                    if !pending.isEmpty {
                        draftItem.tags = VaultItem.normalizeTags(draftItem.tagList + pending)
                    }
                    return VaultDraft(item: draftItem, original: baseline, parents: parents)
                }
            }
            .onDisappear {
                if !expandedEditorActive {
                    session.stopObservingDraft(draftObserverID)
                }
            }
            .onChange(of: item) { _, _ in
                guard loaded, !saving else { return }
                session.retainDraftSoon(VaultDraft(item: item, original: baseline, parents: parents))
                session.touch()
            }
            .onChange(of: item.kind) { _, kind in
                if kind == .card, item.cardBrand == nil, item.cardType == nil {
                    item.cardBrand = .unionPay; item.cardType = .debit
                }
            }
            .alert(L10n.text("draft.closeTitle"), isPresented: $confirmClose) {
                Button(L10n.text("draft.keepAndClose")) {
                    commitTagInput()
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
        if isDirty {
            confirmClose = true
        } else {
            dismiss()
        }
    }

    private var oneTimePasswordField: some View {
        VStack(alignment: .leading, spacing: 8) {
            AegisInput(title: L10n.text("field.oneTimePassword"), icon: "clock.badge.checkmark") {
                Group {
                    if showOneTimePassword {
                        TextField(L10n.text("editor.otpPlaceholder"), text: oneTimePasswordText)
                    } else {
                        SecureField(L10n.text("editor.otpPlaceholder"), text: oneTimePasswordText)
                    }
                }.aegisNoCapitalization().autocorrectionDisabled().accessibilityIdentifier("oneTimePassword")
                Button { showOneTimePassword.toggle() } label: { Image(systemName: showOneTimePassword ? "eye.slash" : "eye").foregroundStyle(AegisTheme.secondary).frame(width: AegisMetrics.controlHeight, height: AegisMetrics.controlHeight).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text(showOneTimePassword ? "action.hide" : "action.show"))
                qrButton
            }
            if let oneTimePasswordError {
                Label(oneTimePasswordError, systemImage: "exclamationmark.circle").aegisFont(size: 11).foregroundStyle(AegisTheme.danger)
            } else if item.oneTimePassword != nil {
                Label(L10n.text("editor.otpNote"), systemImage: "info.circle").aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
            }
        }
    }

    private var qrButton: some View {
        let label = Image(systemName: "qrcode.viewfinder").foregroundStyle(AegisTheme.secondary)
            .frame(width: AegisMetrics.controlHeight, height: AegisMetrics.controlHeight).contentShape(Rectangle())
        #if os(iOS)
            return PhotosPicker(selection: $qrPhoto, matching: .images) { label }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("editor.otpScan")).disabled(readingQRCode)
                .onChange(of: qrPhoto) { _, photo in
                    guard let photo else { return }
                    qrPhoto = nil
                    readQRCode { guard let data = try await photo.loadTransferable(type: Data.self) else { throw QRCodeReader.Failure.unreadableImage }
                        return try await QRCodeReader.payload(in: data)
                    }
                }
        #else
            return Button { showQRImporter = true } label: { label }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("editor.otpScan")).disabled(readingQRCode)
                .fileImporter(isPresented: $showQRImporter, allowedContentTypes: [.image]) { result in
                    switch result {
                    case let .success(url): readQRCode { try await QRCodeReader.payload(at: url) }
                    case let .failure(error): session.error = error.localizedDescription
                    }
                }
        #endif
    }

    /// The decoded payload goes into the field as-is so the normal validation explains unusable codes (e.g. HOTP).
    private func readQRCode(_ read: @escaping @MainActor () async throws -> String) {
        readingQRCode = true
        Task {
            defer { readingQRCode = false }
            do { item.oneTimePassword = try await read() } catch { session.error = error.localizedDescription }
        }
    }

    private var loginFields: some View {
        VStack(spacing: 16) {
            loginIdentityLayout {
                AegisInput(title: L10n.text("field.username"), icon: "person") {
                    TextField(L10n.text("field.username"), text: $item.username).textContentType(.username).aegisNoCapitalization()
                }
                AegisInput(title: L10n.text("field.website"), icon: "globe") {
                    TextField(L10n.text("editor.websitePlaceholder"), text: $item.website).textContentType(.URL).aegisNoCapitalization()
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                AegisInput(title: L10n.text("field.password"), icon: "key.horizontal") {
                    Group {
                        if showPassword {
                            TextField(L10n.text("field.password"), text: $item.password)
                        } else {
                            SecureField(L10n.text("field.password"), text: $item.password).textContentType(.newPassword)
                        }
                    }.aegisNoCapitalization()
                    Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(AegisTheme.secondary).frame(width: AegisMetrics.controlHeight, height: AegisMetrics.controlHeight).contentShape(Rectangle()) }
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
                        Text(session.passwordOptions.mode == .passphrase
                            ? L10n.format("generator.words", Int64(session.passwordOptions.wordCount))
                            : L10n.format("generator.characters", Int64(session.passwordOptions.length)))
                            .foregroundStyle(AegisTheme.secondary)
                    }.aegisFont(size: 12, weight: .medium).foregroundStyle(AegisTheme.teal)
                }.buttonStyle(.plain).padding(.horizontal, 3)
                if !item.password.isEmpty {
                    PasswordStrengthMeter(password: item.password, showsSuggestions: false)
                }
            }
            oneTimePasswordField
        }
    }

    private var loginIdentityLayout: AnyLayout {
        #if os(macOS)
            AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        #else
            AnyLayout(VStackLayout(spacing: 16))
        #endif
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

    private var tagsEditor: some View {
        let currentTags = item.tagList
        let suggestions = session.allTags.filter { candidate in
            !currentTags.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }.prefix(8)
        return VStack(alignment: .leading, spacing: 10) {
            AegisInput(title: L10n.text("field.tags"), icon: "tag") {
                TextField(L10n.text("editor.tagsPlaceholder"), text: $tagInput)
                    .aegisNoCapitalization()
                    .onSubmit(commitTagInput)
                    .accessibilityIdentifier("itemTagsInput")
                    .onChange(of: tagInput) { _, value in
                        if value.contains(where: { ",;，；".contains($0) }) {
                            commitTagInput()
                        }
                    }
                if !tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(L10n.text("editor.addTag"), action: commitTagInput)
                        .aegisFont(size: 12, weight: .medium).buttonStyle(.plain).foregroundStyle(AegisTheme.teal)
                }
            }
            if !currentTags.isEmpty {
                AegisFlowLayout(spacing: 6) {
                    ForEach(currentTags, id: \.self) { tag in
                        HStack(spacing: 5) {
                            Text(tag).aegisFont(size: 11, weight: .medium)
                            Button { removeTag(tag) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                            }.buttonStyle(.plain).accessibilityLabel(L10n.format("editor.removeTag", tag))
                        }
                        .foregroundStyle(AegisTheme.teal)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(AegisTheme.teal.opacity(0.08), in: Capsule())
                    }
                }
            }
            if !suggestions.isEmpty {
                AegisFlowLayout(spacing: 6) {
                    ForEach(Array(suggestions), id: \.self) { tag in
                        Button { appendTags([tag]) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                                Text(tag).aegisFont(size: 11)
                            }
                            .foregroundStyle(AegisTheme.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(AegisTheme.inset, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func commitTagInput() {
        let parsed = VaultItem.parseTags(tagInput)
        tagInput = ""
        guard !parsed.isEmpty else { return }
        appendTags(parsed)
    }

    private func appendTags(_ additions: [String]) {
        let merged = VaultItem.normalizeTags(item.tagList + additions)
        item.tags = merged.isEmpty ? nil : merged
    }

    private func removeTag(_ tag: String) {
        let remaining = item.tagList.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
        item.tags = remaining.isEmpty ? nil : remaining
    }

    private var typeChoiceLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
    }

    private var footerLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
    }
}
