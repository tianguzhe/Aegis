import AegisCore
import AegisMarkdown
import SwiftUI

private enum ComposerMode: String, CaseIterable {
    case write, preview, split
    var title: String { L10n.text(self == .write ? "composer.write" : self == .preview ? "markdown.preview" : "composer.split") }
    var symbol: String { self == .write ? "square.and.pencil" : self == .preview ? "eye" : "rectangle.split.2x1" }
}

struct MarkdownComposer: View {
    @Binding var text: String
    let title: String
    let recordTitle: String
    @State private var mode: ComposerMode = .write
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var focused = false
    @State private var command: MarkdownEditorCommand?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft").font(.system(size: 13, weight: .medium)).foregroundStyle(AegisTheme.teal)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AegisTheme.text)
                Spacer()
                ComposerModePicker(mode: $mode)
            }
            VStack(spacing: 0) {
                ComposerFormatBar(previewing: mode == .preview) { action in
                    command = MarkdownEditorCommand(action: .format(action))
                }
                Rectangle().fill(AegisTheme.border.opacity(0.75)).frame(height: 1)
                Group {
                    if mode == .write {
                        ZStack(alignment: .topLeading) {
                            MarkdownSourceEditor(text: $text, selection: $selection, isFocused: $focused, command: command, identifier: "markdownNotes", fontSize: 15)
                            if text.isEmpty { ComposerPlaceholder().padding(.horizontal, 20).padding(.top, 22).allowsHitTesting(false) }
                        }
                    } else {
                        ComposerPreview(text: text, compact: true)
                    }
                }.frame(height: 220)
                HStack(spacing: 8) {
                    ComposerStatistics(text: text)
                    Spacer(minLength: 4)
                    Button {
                        command = MarkdownEditorCommand(action: .dismissKeyboard)
                        expanded = true
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                            Text(L10n.text("composer.expand")).font(.system(size: 12, weight: .semibold))
                        }.foregroundStyle(AegisTheme.teal).padding(.horizontal, 13).frame(height: expandHeight)
                            .background(AegisTheme.selected, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AegisTheme.teal.opacity(0.10)))
                    }.buttonStyle(.plain).accessibilityIdentifier("expandMarkdownEditor")
                        #if os(macOS)
                        .help(L10n.text("composer.expandHint"))
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        #endif
                }.padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 10)
                    .background(AegisTheme.surface)
            }
            .background(AegisTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(focused && mode == .write ? AegisTheme.teal.opacity(0.45) : AegisTheme.border, lineWidth: 1))
            .shadow(color: AegisTheme.navy.opacity(0.035), radius: 12, x: 0, y: 5)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: mode)
        }
        .accessibilityHidden(expanded)
        #if os(macOS)
        .sheet(isPresented: $expanded) {
            ExpandedMarkdownEditor(text: $text, selection: $selection, recordTitle: recordTitle, fieldTitle: title)
        }
        #else
        .fullScreenCover(isPresented: $expanded) {
            ExpandedMarkdownEditor(text: $text, selection: $selection, recordTitle: recordTitle, fieldTitle: title)
        }
        #endif
    }
    private var expandHeight: CGFloat {
        #if os(iOS)
        44
        #else
        34
        #endif
    }
}

private struct ComposerModePicker: View {
    @Binding var mode: ComposerMode
    var supportsSplit = false
    var identifierPrefix = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            ForEach(supportsSplit ? ComposerMode.allCases : [.write, .preview], id: \.rawValue) { value in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { mode = value }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: value.symbol).font(.system(size: 12, weight: .medium))
                        Text(value.title).font(.system(size: 12, weight: .semibold))
                    }.foregroundStyle(mode == value ? AegisTheme.teal : AegisTheme.secondary)
                        .padding(.horizontal, 12).frame(height: controlHeight)
                        .background(mode == value ? AegisTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        .shadow(color: .black.opacity(mode == value ? 0.04 : 0), radius: 3, y: 1)
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityLabel(value.title)
                    .accessibilityIdentifier("\(identifierPrefix)composerMode-\(value.rawValue)")
                    .accessibilityAddTraits(mode == value ? [.isSelected] : [])
            }
        }.padding(4).background(AegisTheme.inset, in: RoundedRectangle(cornerRadius: 12))
    }
    private var controlHeight: CGFloat {
        #if os(iOS)
        36
        #else
        30
        #endif
    }
}

private struct ComposerFormatBar: View {
    var previewing = false
    var allowsKeyboardDismiss = false
    var identifierPrefix = ""
    let apply: (MarkdownFormatAction) -> Void
    var dismissKeyboard: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 0) {
            if previewing {
                Label(L10n.text("composer.previewHint"), systemImage: "eye")
                    .font(.system(size: 11)).foregroundStyle(AegisTheme.secondary).padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(MarkdownFormatAction.allCases, id: \.rawValue) { action in
                            ComposerToolButton(action: action, identifierPrefix: identifierPrefix) { apply(action) }
                            if action == .italic || action == .quote {
                                Rectangle().fill(AegisTheme.border).frame(width: 1, height: 16).padding(.horizontal, 5)
                            }
                        }
                    }.padding(.horizontal, 8)
                }.scrollIndicators(.hidden)
                if allowsKeyboardDismiss, let dismissKeyboard {
                    Button(action: dismissKeyboard) {
                        Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 15)).foregroundStyle(AegisTheme.secondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(L10n.text("composer.hideKeyboard"))
                }
            }
        }.frame(height: barHeight).background(AegisTheme.inset.opacity(0.5))
    }
    private var barHeight: CGFloat {
        #if os(iOS)
        50
        #else
        42
        #endif
    }
}

private struct ComposerToolButton: View {
    let action: MarkdownFormatAction
    var identifierPrefix = ""
    let apply: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: apply) {
            Group {
                if action == .heading { Text("H₂").font(.system(size: 14, weight: .semibold, design: .rounded)) }
                else { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
            }.foregroundStyle(hovering ? AegisTheme.teal : AegisTheme.text.opacity(0.75))
                .frame(width: targetSize, height: targetSize)
                .background(hovering ? AegisTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel(title)
            .accessibilityIdentifier("\(identifierPrefix)markdownFormat-\(action.rawValue)")
            .help(title)
    }
    private var title: String {
        switch action {
        case .heading: L10n.text("composer.format.heading")
        case .bold: L10n.text("composer.format.bold")
        case .italic: L10n.text("composer.format.italic")
        case .bullet: L10n.text("composer.format.bullet")
        case .task: L10n.text("composer.format.task")
        case .quote: L10n.text("composer.format.quote")
        case .code: L10n.text("composer.format.code")
        case .link: L10n.text("composer.format.link")
        }
    }
    private var symbol: String {
        switch action {
        case .heading: "textformat.size"
        case .bold: "bold"
        case .italic: "italic"
        case .bullet: "list.bullet"
        case .task: "checklist"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        }
    }
    private var targetSize: CGFloat {
        #if os(iOS)
        44
        #else
        32
        #endif
    }
}

private struct ComposerStatistics: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Text("Markdown").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(AegisTheme.secondary.opacity(0.8))
            Circle().fill(AegisTheme.border).frame(width: 3, height: 3)
            Text(L10n.format("composer.characterCount", Int64(text.count))).font(.system(size: 10)).monospacedDigit().foregroundStyle(AegisTheme.secondary)
        }.lineLimit(1)
    }
}

private struct ComposerPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.text("composer.placeholder")).font(.system(size: 15)).foregroundStyle(AegisTheme.secondary.opacity(0.8))
            Text(L10n.text("composer.placeholderHint")).font(.system(size: 12)).foregroundStyle(AegisTheme.secondary.opacity(0.55))
        }
    }
}

private struct ComposerPreview: View {
    let text: String
    var compact = false
    var body: some View {
        if text.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.richtext").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(AegisTheme.teal.opacity(0.6))
                Text(L10n.text("markdown.empty")).font(.system(size: 13)).foregroundStyle(AegisTheme.secondary)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                MarkdownContent(text, accent: AegisTheme.teal).padding(compact ? 20 : 30)
                    .frame(maxWidth: 760).frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

private struct ExpandedMarkdownEditor: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    @Binding var selection: NSRange
    let recordTitle: String
    let fieldTitle: String
    @State private var focused = false
    @State private var command: MarkdownEditorCommand?
    #if os(macOS)
    @State private var mode: ComposerMode = .split
    #else
    @State private var mode: ComposerMode = .write
    #endif

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 780
            VStack(spacing: 0) {
                header(wide: wide)
                HStack {
                    ComposerModePicker(mode: $mode, supportsSplit: wide, identifierPrefix: "expanded-")
                    Spacer()
                    #if os(macOS)
                    Label(L10n.text("composer.focusHint"), systemImage: "text.alignleft")
                        .font(.system(size: 11)).foregroundStyle(AegisTheme.secondary)
                    #endif
                }.padding(.horizontal, pagePadding).padding(.bottom, 18)
                VStack(spacing: 0) {
                    ComposerFormatBar(previewing: mode == .preview, allowsKeyboardDismiss: showsKeyboardDismiss, identifierPrefix: "expanded-", apply: { action in
                        command = MarkdownEditorCommand(action: .format(action))
                    }, dismissKeyboard: { command = MarkdownEditorCommand(action: .dismissKeyboard) })
                    Rectangle().fill(AegisTheme.border).frame(height: 1)
                    if mode == .split && wide {
                        HStack(spacing: 0) {
                            sourceColumn
                            Rectangle().fill(AegisTheme.border).frame(width: 1)
                            VStack(spacing: 0) {
                                columnLabel(L10n.text("markdown.preview"), symbol: "eye")
                                ComposerPreview(text: text)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if mode == .preview { ComposerPreview(text: text) }
                    else { sourceColumn }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AegisTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(AegisTheme.border))
                    .padding(.horizontal, pagePadding)
                HStack(spacing: 10) {
                    ComposerStatistics(text: text)
                    Spacer(minLength: 0)
                    #if os(macOS)
                    Text(L10n.text("composer.draftHint")).font(.system(size: 11)).foregroundStyle(AegisTheme.secondary)
                    #endif
                }.padding(.horizontal, pagePadding + 2).padding(.vertical, 16)
            }.background(AegisTheme.background)
                .onChange(of: wide) { _, value in if !value && mode == .split { mode = .write } }
        }
        #if os(macOS)
        .frame(minWidth: 860, idealWidth: 1040, maxWidth: .infinity, minHeight: 580, idealHeight: 760, maxHeight: .infinity)
        #endif
        .privacySensitive()
        .onChange(of: mode) { _, value in
            if value == .preview { command = MarkdownEditorCommand(action: .dismissKeyboard) }
            session.touch()
        }
        .onChange(of: text) { _, _ in session.touch() }
        .onChange(of: session.phase) { _, phase in if phase != .unlocked { dismiss() } }
    }
    private var pagePadding: CGFloat {
        #if os(macOS)
        26
        #else
        16
        #endif
    }
    private var showsKeyboardDismiss: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
    private func header(wide: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.pencil").font(.system(size: 20, weight: .medium)).foregroundStyle(AegisTheme.teal)
                .frame(width: 44, height: 44).background(AegisTheme.selected, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("composer.focusTitle")).font(.system(size: wide ? 23 : 20, weight: .semibold)).foregroundStyle(AegisTheme.text)
                Text(recordTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fieldTitle : recordTitle)
                    .font(.system(size: 12)).foregroundStyle(AegisTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { dismiss() } label: {
                Label(L10n.text("action.done"), systemImage: "checkmark")
            }.buttonStyle(AegisButtonStyle(primary: true)).accessibilityIdentifier("doneExpandedMarkdown")
                #if os(macOS)
                .keyboardShortcut(.return, modifiers: .command)
                #endif
        }.padding(.horizontal, pagePadding).padding(.top, 22).padding(.bottom, 22)
    }
    private var sourceColumn: some View {
        VStack(spacing: 0) {
            columnLabel(L10n.text("composer.source"), symbol: "text.alignleft")
            ZStack(alignment: .topLeading) {
                MarkdownSourceEditor(text: $text, selection: $selection, isFocused: $focused, command: command, identifier: "expandedMarkdownNotes", fontSize: 16)
                if text.isEmpty { ComposerPlaceholder().padding(.horizontal, 22).padding(.top, 24).allowsHitTesting(false) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func columnLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(title).font(.system(size: 10, weight: .semibold))
            Spacer()
        }.foregroundStyle(AegisTheme.secondary).padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 4)
    }
}
