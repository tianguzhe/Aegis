import AegisCore
import AegisMarkdown
import SwiftUI

struct ItemDetailView: View {
    @Environment(VaultSession.self) private var session
    let entry: VaultEntry
    @State private var showEditor = false
    @State private var confirmResolution = false
    @State private var confirmTrash = false
    @State private var copiedNotes = false
    @ScaledMetric(relativeTo: .body) private var titleSize = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if entry.isConflict {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L10n.text("list.conflict"), systemImage: "exclamationmark.triangle").font(.system(size: 14, weight: .semibold))
                        Text(L10n.text("list.conflictDetail")).font(.system(size: 13)).lineSpacing(4)
                        Button(L10n.text("list.resolve")) { confirmResolution = true }.buttonStyle(AegisButtonStyle())
                    }.foregroundStyle(AegisTheme.text).aegisCard()
                }
                if entry.item.kind == .card { cardPreview }
                if entry.item.kind != .note {
                    AegisSection(title: L10n.text("field.details")) {
                        if entry.item.kind == .login {
                            SecretField(label: "field.username", value: entry.item.username)
                            fieldDivider
                            SecretField(label: "field.password", value: entry.item.password, secret: true)
                            if !entry.item.website.isEmpty { fieldDivider; SecretField(label: "field.website", value: entry.item.website) }
                        } else {
                            SecretField(label: "field.cardholder", value: entry.item.cardholder)
                            fieldDivider; SecretField(label: "field.cardNumber", value: entry.item.cardNumber, secret: true)
                            fieldDivider; SecretField(label: "field.expiry", value: entry.item.expiry)
                            fieldDivider; SecretField(label: "field.securityCode", value: entry.item.securityCode, secret: true)
                        }
                    }
                }
                if !entry.item.notes.isEmpty { notes }
                HStack(spacing: 7) {
                    Image(systemName: "clock").font(.system(size: 11))
                    Text(L10n.text("field.modified"))
                    Text(entry.item.modifiedAt, format: .dateTime.year().month().day().hour().minute())
                }.font(.system(size: 11)).foregroundStyle(AegisTheme.secondary).padding(.horizontal, 2)
                if entry.item.deletedAt != nil {
                    Button { Task { await session.restore(entry) } } label: {
                        Label(L10n.text("action.restore"), systemImage: "arrow.uturn.backward")
                    }.buttonStyle(AegisButtonStyle(primary: true))
                }
            }.padding(.horizontal, horizontalPadding).padding(.vertical, 30)
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.background(AegisTheme.background)
        #if os(iOS)
        .navigationTitle(entry.item.kind.title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .sheet(isPresented: $showEditor) { ItemEditorView(item: entry.item, parents: [entry.id]).environment(session) }
        .confirmationDialog(L10n.text("list.resolveConfirm"), isPresented: $confirmResolution, titleVisibility: .visible) {
            Button(L10n.text("list.resolve")) { Task { await session.resolve(entry) } }
        } message: { Text(L10n.text("list.resolveMessage")) }
        .confirmationDialog(L10n.text("action.trash"), isPresented: $confirmTrash, titleVisibility: .visible) {
            Button(L10n.text("action.trash"), role: .destructive) { Task { await session.trash(entry) } }
        }
        .privacySensitive()
    }
    private var horizontalPadding: CGFloat {
        #if os(macOS)
        34
        #else
        22
        #endif
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                AegisPill(title: entry.item.kind.title, symbol: entry.item.kind.symbol)
                Spacer()
                AegisIconButton(symbol: entry.item.isFavorite ? "star.fill" : "star", label: L10n.text(entry.item.isFavorite ? "action.unfavorite" : "action.favorite")) {
                    Task { await session.toggleFavorite(entry) }
                }
                Menu {
                    if entry.item.deletedAt == nil {
                        Button(L10n.text("action.trash"), role: .destructive) { confirmTrash = true }
                    } else { Button(L10n.text("action.restore")) { Task { await session.restore(entry) } } }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18)).foregroundStyle(AegisTheme.secondary).frame(width: 28, height: 36)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L10n.text("ui.moreActions"))
            }
            HStack(alignment: .center, spacing: 18) {
                ItemIcon(item: entry.item, size: 64)
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.item.title).font(.system(size: titleSize, weight: .semibold)).tracking(-0.7)
                        .foregroundStyle(AegisTheme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let host = displayHost {
                        Text(host).font(.system(size: 13)).foregroundStyle(AegisTheme.secondary).lineLimit(1)
                    } else { Text(L10n.text("ui.privateItem")).font(.system(size: 13)).foregroundStyle(AegisTheme.secondary) }
                }
            }
            HStack(spacing: 10) {
                Button { showEditor = true } label: { Label(L10n.text("action.edit"), systemImage: "square.and.pencil") }
                    .buttonStyle(AegisButtonStyle()).disabled(entry.item.deletedAt != nil).accessibilityIdentifier("editItemButton")
                Spacer()
                Image(systemName: "lock.shield").font(.system(size: 13)).foregroundStyle(AegisTheme.secondary.opacity(0.7)).accessibilityHidden(true)
            }
        }
    }
    private var displayHost: String? {
        guard entry.item.kind == .login, !entry.item.website.isEmpty else { return nil }
        return URL(string: entry.item.website.contains("://") ? entry.item.website : "https://" + entry.item.website)?.host
    }
    private var fieldDivider: some View { Rectangle().fill(AegisTheme.border).frame(height: 1).padding(.horizontal, 20) }
    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text(entry.item.kind == .note ? "field.secureNote" : "field.notes"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(AegisTheme.text)
                Spacer()
                Button {
                    SecureClipboard.copy(entry.item.notes); session.touch(); copiedNotes = true
                } label: { Label(L10n.text(copiedNotes ? "action.copied" : "markdown.copySource"), systemImage: copiedNotes ? "checkmark" : "doc.on.doc") }
                    .font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(AegisTheme.teal)
                    .task(id: copiedNotes) {
                        guard copiedNotes else { return }
                        try? await Task.sleep(for: .seconds(2)); copiedNotes = false
                    }
            }.padding(.horizontal, 2)
            MarkdownContent(entry.item.notes, accent: AegisTheme.teal).padding(24).aegisSurface()
        }
    }
    private var cardPreview: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                Image(systemName: "simcard").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(Color(red: 0.85, green: 0.73, blue: 0.48))
                Spacer()
                Text("Aegis").font(.system(size: 19, weight: .medium, design: .serif)).foregroundStyle(.white.opacity(0.6))
            }
            Text("••••  ••••  ••••  " + (entry.item.cardNumber.isEmpty ? "••••" : String(entry.item.cardNumber.filter(\.isNumber).suffix(4))))
                .font(.system(size: 20, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                .minimumScaleFactor(0.65).lineLimit(1)
            HStack {
                Text(entry.item.cardholder.isEmpty ? L10n.text("field.cardholder") : entry.item.cardholder).lineLimit(1)
                Spacer()
                Text(entry.item.expiry)
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.72))
        }.padding(26).background(LinearGradient(colors: [AegisTheme.navy, Color(red: 0.19, green: 0.33, blue: 0.29)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct SecretField: View {
    @Environment(VaultSession.self) private var session
    let label: String
    let value: String
    var secret = false
    @State private var revealed = false
    @State private var copied = false
    @ScaledMetric(relativeTo: .body) private var valueSize = 15
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.text(label)).font(.system(size: 11, weight: .medium)).foregroundStyle(AegisTheme.secondary)
                Text(secret && !revealed ? "••••••••••••" : value.isEmpty ? "—" : value)
                    .font(.system(size: valueSize, design: secret ? .monospaced : .default)).foregroundStyle(AegisTheme.text)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if secret {
                AegisIconButton(symbol: revealed ? "eye.slash" : "eye", label: L10n.text(revealed ? "action.hide" : "action.show")) { revealed.toggle(); session.touch() }
            }
            AegisIconButton(symbol: copied ? "checkmark" : "doc.on.doc", label: L10n.text("action.copy") + " " + L10n.text(label)) {
                SecureClipboard.copy(value); copied = true; session.touch()
            }.disabled(value.isEmpty).task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2)); copied = false
            }
        }.padding(.horizontal, 20).padding(.vertical, 19)
    }
}
