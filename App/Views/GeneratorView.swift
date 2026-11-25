import AegisCore
import SwiftUI

struct GeneratorView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    @State private var password = ""
    @State private var copied = false
    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("nav.generator"), subtitle: L10n.text("generator.subtitle"), symbol: "wand.and.stars", close: embedded ? nil : { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker(L10n.text("generator.mode"), selection: $session.passwordOptions.mode) {
                        ForEach(PasswordMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("generatorMode")
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            AegisPill(title: L10n.text(session.passwordOptions.mode == .passphrase ? "generator.mode.passphrase" : "ui.randomPassword"), symbol: "sparkles")
                            Spacer()
                            Image(systemName: "key.horizontal").font(.system(size: 16)).foregroundStyle(AegisTheme.secondary).accessibilityHidden(true)
                        }
                        Text(styledPassword).aegisFont(size: 23, weight: .medium, design: .monospaced)
                            .tracking(0.3).lineSpacing(6).textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("generatedPassword")
                        PasswordStrengthMeter(password: password, showsSuggestions: false)
                    }.padding(20).aegisSurface()
                    AegisSection(title: L10n.text("ui.generatorRules"), subtitle: L10n.text("ui.generatorShared")) {
                        if session.passwordOptions.mode == .random {
                            randomRules
                        } else {
                            passphraseRules
                        }
                    }
                    Label(L10n.format("generator.footer", session.securitySettings.clipboardClear.title), systemImage: "clock.arrow.circlepath")
                        .aegisFont(size: 11).foregroundStyle(AegisTheme.secondary).frame(maxWidth: .infinity)
                }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                Button(action: regenerate) { Label(L10n.text("generator.regenerate"), systemImage: "arrow.clockwise") }
                    .buttonStyle(AegisButtonStyle())
                Spacer(minLength: 8)
                Button {
                    SecureClipboard.copy(password); copied = true; session.touch()
                } label: {
                    Label(L10n.text(copied ? "action.copied" : "generator.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(AegisButtonStyle(primary: true)).disabled(password.isEmpty)
            }.padding(.horizontal, 24).padding(.vertical, 16).background(AegisTheme.surface)
                .overlay(alignment: .top) { Rectangle().fill(AegisTheme.border).frame(height: 0.5) }
        }.background(AegisTheme.background).modifier(UtilitySize(embedded: embedded, height: 720)).vaultErrorPresenter()
            .onAppear(perform: regenerate).onChange(of: session.passwordOptions) { _, _ in regenerate() }
            .task(id: copied) {
                if copied {
                    try? await Task.sleep(for: .seconds(2)); copied = false
                }
            }.privacySensitive()
    }

    @ViewBuilder private var randomRules: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 20) {
            stepper(title: "generator.length", detail: "ui.lengthRange", value: session.passwordOptions.length, range: 12 ... 64,
                    decreaseID: "decreasePasswordLength", increaseID: "increasePasswordLength") { session.passwordOptions.length = $0 }
            Slider(value: Binding(get: { Double(session.passwordOptions.length) }, set: { session.passwordOptions.length = Int($0) }), in: 12 ... 64, step: 1)
                .tint(AegisTheme.teal).accessibilityLabel(L10n.text("generator.length"))
        }.padding(20)
        settingDivider
        generatorToggle("generator.uppercase", sample: "A–Z", value: $session.passwordOptions.uppercase)
        settingDivider
        generatorToggle("generator.digits", sample: "0–9", value: $session.passwordOptions.digits)
        settingDivider
        generatorToggle("generator.symbols", sample: "# & %", value: $session.passwordOptions.symbols)
    }

    @ViewBuilder private var passphraseRules: some View {
        @Bindable var session = session
        stepper(title: "generator.wordCount", detail: "generator.wordRange", value: session.passwordOptions.wordCount, range: 4 ... 8,
                decreaseID: "decreaseWordCount", increaseID: "increaseWordCount") { session.passwordOptions.wordCount = $0 }
            .padding(20)
        settingDivider
        HStack {
            Text(L10n.text("generator.separator")).aegisFont(size: 13).foregroundStyle(AegisTheme.text)
            Spacer()
            Picker(L10n.text("generator.separator"), selection: $session.passwordOptions.separator) {
                ForEach(PassphraseSeparator.allCases) { separator in Text(separator.title).tag(separator) }
            }.labelsHidden().fixedSize().accessibilityIdentifier("passphraseSeparator")
        }.padding(.horizontal, 18).padding(.vertical, 9)
        settingDivider
        generatorToggle("generator.capitalize", sample: "Aa", value: $session.passwordOptions.capitalizeWords)
        settingDivider
        generatorToggle("generator.includeNumber", sample: "0–9", value: $session.passwordOptions.includeNumber)
    }

    private func stepper(title: String, detail: String, value: Int, range: ClosedRange<Int>, decreaseID: String, increaseID: String,
                         set: @escaping (Int) -> Void) -> some View
    {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text(title)).aegisFont(size: 14, weight: .medium).foregroundStyle(AegisTheme.text)
                Text(L10n.text(detail)).aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                AegisIconButton(symbol: "minus", label: L10n.text("ui.lengthDecrease")) { set(value - 1) }
                    .disabled(value <= range.lowerBound).accessibilityIdentifier(decreaseID)
                Text(value, format: .number).aegisFont(size: 24, weight: .semibold).monospacedDigit().foregroundStyle(AegisTheme.teal).frame(minWidth: 40)
                AegisIconButton(symbol: "plus", label: L10n.text("ui.lengthIncrease")) { set(value + 1) }
                    .disabled(value >= range.upperBound).accessibilityIdentifier(increaseID)
            }
        }
    }

    private var styledPassword: AttributedString {
        password.reduce(into: AttributedString()) { result, character in
            var value = AttributedString(String(character))
            value.foregroundColor = character.isNumber ? AegisTheme.gold : character.isLetter ? AegisTheme.text : AegisTheme.teal
            result += value
        }
    }

    private func generatorToggle(_ key: String, sample: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            HStack {
                Text(L10n.text(key)).aegisFont(size: 13).foregroundStyle(AegisTheme.text)
                Spacer()
                Text(sample).aegisFont(size: 11, design: .monospaced).foregroundStyle(AegisTheme.secondary).padding(.trailing, 12)
            }
        }.toggleStyle(.switch).tint(AegisTheme.teal).padding(.horizontal, 18).padding(.vertical, 13)
    }

    private var settingDivider: some View {
        Rectangle().fill(AegisTheme.border).frame(height: 1).padding(.horizontal, 20)
    }

    private func regenerate() {
        do { password = try PasswordGenerator.generate(options: session.passwordOptions); copied = false; session.touch() }
        catch { session.error = error.localizedDescription }
    }
}

struct UtilitySize: ViewModifier {
    let embedded: Bool
    let height: CGFloat
    func body(content: Content) -> some View {
        if embedded {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.aegisSheetSize(width: 580, height: height)
        }
    }
}
