import AegisCore
import SwiftUI

enum VaultFilter: String, CaseIterable, Identifiable {
    case all, favorites, login, card, note, trash
    var id: String { rawValue }
    var title: String { L10n.text(["all": "nav.all", "favorites": "nav.favorites", "login": "kind.login", "card": "kind.card", "note": "kind.note", "trash": "nav.trash"][rawValue]!) }
    var symbol: String {
        switch self { case .all: "square.grid.2x2"; case .favorites: "star"; case .login: "key.horizontal"; case .card: "creditcard"; case .note: "note.text"; case .trash: "trash" }
    }
    func includes(_ entry: VaultEntry) -> Bool {
        if self == .trash { return entry.item.deletedAt != nil }
        guard entry.item.deletedAt == nil else { return false }
        switch self { case .all: return true; case .favorites: return entry.item.isFavorite
        case .login: return entry.item.kind == .login; case .card: return entry.item.kind == .card
        case .note: return entry.item.kind == .note; case .trash: return false }
    }
}

struct VaultView: View {
    @Environment(VaultSession.self) private var session
    @State private var filter: VaultFilter = .all
    @State private var selection: UUID?
    @State private var selectedItem: UUID?
    @State private var search = ""
    @State private var showEditor = false
    @State private var showSettings = false
    @State private var showGenerator = false
    @State private var recentFirst = false
    @State private var mobilePath: [UUID] = []
    @State private var selectedTab = 0

    private var filtered: [VaultEntry] {
        session.entries.filter { entry in
            filter.includes(entry) && (search.isEmpty || [entry.item.title, entry.item.username, entry.item.website].contains { $0.localizedStandardContains(search) })
        }.sorted { recentFirst ? $0.item.modifiedAt > $1.item.modifiedAt : $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending }
    }
    private var selectedEntry: VaultEntry? {
        session.entries.first { $0.id == selection } ?? session.entries.first { $0.item.id == selectedItem }
    }

    var body: some View {
        Group {
            #if os(macOS)
            HSplitView {
                sidebar.frame(minWidth: 210, idealWidth: 228, maxWidth: 260)
                recordsColumn(mobile: false).frame(minWidth: 300, idealWidth: 330, maxWidth: 400)
                detail.frame(minWidth: 380, maxWidth: .infinity)
            }
            #else
            GeometryReader { geometry in
                if geometry.size.width >= 900 {
                    HStack(spacing: 0) {
                        sidebar.frame(width: 220)
                        Divider().overlay(AegisTheme.border)
                        recordsColumn(mobile: false).frame(width: 310)
                        Divider().overlay(AegisTheme.border)
                        detail.frame(maxWidth: .infinity)
                    }
                } else { mobileTabs }
            }
            #endif
        }
        .background(AegisTheme.background)
        .sheet(isPresented: $showEditor) { ItemEditorView(item: VaultItem(kind: newItemKind), parents: []).environment(session) }
        .sheet(isPresented: $showSettings) { SettingsView().environment(session) }
        .sheet(isPresented: $showGenerator) { GeneratorView().environment(session) }
        .onChange(of: filter) { _, _ in selection = nil; selectedItem = nil; session.touch() }
        .onChange(of: search) { _, _ in session.touch() }
        .onChange(of: session.entries.map(\.id)) { _, _ in
            if let entry = selectedEntry { selection = entry.id }
        }
    }

    #if os(iOS)
    private var mobileTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $mobilePath) {
                recordsColumn(mobile: true)
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: UUID.self) { id in
                        if let entry = session.entries.first(where: { $0.id == id }) ?? selectedEntry {
                            ItemDetailView(entry: entry).id(entry.id)
                        }
                    }
            }.tabItem { Label(L10n.text("nav.library"), systemImage: "square.grid.2x2") }.tag(0)
            GeneratorView(embedded: true).tabItem { Label(L10n.text("nav.generator"), systemImage: "wand.and.stars") }.tag(1)
            SettingsView(embedded: true).tabItem { Label(L10n.text("action.settings"), systemImage: "slider.horizontal.3") }.tag(2)
        }.tint(AegisTheme.teal)
    }
    #endif

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            AegisBrand().padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 30)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    sidebarSection("nav.library", values: [.all, .favorites])
                    sidebarSection("nav.categories", values: [.login, .card, .note])
                    VStack(spacing: 4) { sidebarRow(.trash) }
                    VStack(alignment: .leading, spacing: 10) {
                        sectionCaption("nav.tools")
                        sidebarAction("nav.generator", symbol: "wand.and.stars") { showGenerator = true }
                        sidebarAction("nav.settings", symbol: "slider.horizontal.3") { showSettings = true }
                    }
                }.padding(.horizontal, 14).padding(.bottom, 20)
            }.scrollIndicators(.hidden)
            Spacer(minLength: 12)
            VStack(spacing: 16) {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.shield").font(.system(size: 15)).foregroundStyle(AegisTheme.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("ui.protected")).font(.system(size: 12, weight: .medium)).foregroundStyle(AegisTheme.text)
                        Text(session.syncTitle).font(.system(size: 10)).foregroundStyle(AegisTheme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Button { session.lock() } label: {
                    Label(L10n.text("action.lock"), systemImage: "lock").frame(maxWidth: .infinity)
                }.buttonStyle(AegisButtonStyle()).keyboardShortcut("l", modifiers: [.command, .shift])
            }.padding(20)
        }.frame(maxHeight: .infinity).background(AegisTheme.sidebar)
    }
    private func sidebarSection(_ title: String, values: [VaultFilter]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionCaption(title)
            VStack(spacing: 4) { ForEach(values) { sidebarRow($0) } }
        }
    }
    private func sectionCaption(_ key: String) -> some View {
        Text(L10n.text(key)).font(.system(size: 10, weight: .semibold)).foregroundStyle(AegisTheme.secondary)
            .padding(.horizontal, 12).tracking(1)
    }
    private func sidebarRow(_ value: VaultFilter) -> some View {
        let active = filter == value
        let count = session.entries.filter { value.includes($0) }.count
        return Button { filter = value } label: {
            HStack(spacing: 12) {
                Image(systemName: value.symbol).font(.system(size: 16, weight: active ? .semibold : .regular)).frame(width: 20)
                Text(value.title).font(.system(size: 13, weight: active ? .semibold : .regular))
                Spacer(minLength: 0)
                if count > 0 { Text(count, format: .number).font(.system(size: 11, weight: .medium)).monospacedDigit().opacity(active ? 1 : 0.65) }
            }.foregroundStyle(active ? AegisTheme.teal : AegisTheme.text.opacity(0.8))
                .padding(.horizontal, 12).padding(.vertical, 12).frame(maxWidth: .infinity)
                .background(active ? AegisTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected] : [])
    }
    private func sidebarAction(_ key: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(L10n.text(key), systemImage: symbol).font(.system(size: 13)).foregroundStyle(AegisTheme.text.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func recordsColumn(mobile: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                if mobile {
                    HStack {
                        AegisBrand(compact: true)
                        Spacer()
                        AegisIconButton(symbol: "lock", label: L10n.text("action.lock")) { session.lock() }
                    }
                }
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mobile ? L10n.text("app.vault") : filter.title)
                            .font(.system(size: mobile ? 28 : 23, weight: .semibold)).tracking(-0.6).foregroundStyle(AegisTheme.text)
                        Text(L10n.format("list.count", Int64(filtered.count))).font(.system(size: 12)).foregroundStyle(AegisTheme.secondary)
                    }
                    Spacer(minLength: 8)
                    AegisIconButton(symbol: "plus", label: L10n.text("action.add"), prominent: true) { showEditor = true }
                        .keyboardShortcut("n", modifiers: .command).accessibilityIdentifier("addItemButton")
                }
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(AegisTheme.secondary)
                    TextField(L10n.text("action.search"), text: $search).textFieldStyle(.plain).font(.system(size: 13))
                        .aegisNoCapitalization().autocorrectionDisabled().accessibilityIdentifier("vaultSearch")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(AegisTheme.secondary) }.buttonStyle(.plain).accessibilityLabel(L10n.text("ui.clearSearch"))
                    }
                }.padding(12).background(AegisTheme.inset, in: RoundedRectangle(cornerRadius: 11))
                if mobile {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(VaultFilter.allCases) { value in
                                Button { filter = value } label: {
                                    Label(value.title, systemImage: value.symbol).font(.system(size: 12, weight: filter == value ? .semibold : .medium))
                                        .padding(.horizontal, 13).padding(.vertical, 10)
                                        .foregroundStyle(filter == value ? Color.white : AegisTheme.secondary)
                                        .background(filter == value ? AegisTheme.navy : AegisTheme.inset, in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            }.padding(mobile ? 22 : 24)
            HStack {
                Text(L10n.text(recentFirst ? "ui.recentOrder" : "ui.nameOrder")).font(.system(size: 10, weight: .medium)).foregroundStyle(AegisTheme.secondary)
                Spacer()
                Menu {
                    Button(L10n.text("ui.nameOrder")) { recentFirst = false }
                    Button(L10n.text("ui.recentOrder")) { recentFirst = true }
                } label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 11)).frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(AegisTheme.secondary).accessibilityLabel(L10n.text("ui.sort"))
            }.padding(.horizontal, 26).padding(.bottom, 12)
            if filtered.isEmpty {
                VStack(spacing: 0) {
                    AegisEmptyState(title: L10n.text(emptyTitle), message: L10n.text(emptyDescription), symbol: search.isEmpty ? filter.symbol : "magnifyingglass")
                    if filter != .trash && search.isEmpty {
                        Button(L10n.text("action.add")) { showEditor = true }.buttonStyle(AegisButtonStyle(primary: true)).padding(.bottom, 32)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filtered) { entry in
                                VaultRecordRow(entry: entry, selected: !mobile && selectedEntry?.id == entry.id) {
                                    select(entry)
                                    if mobile { mobilePath.append(entry.id) }
                                }.id(entry.id)
                                .contextMenu {
                                    Button(L10n.text(entry.item.isFavorite ? "action.unfavorite" : "action.favorite")) { Task { await session.toggleFavorite(entry) } }
                                    if entry.item.deletedAt == nil {
                                        Button(L10n.text("action.trash"), role: .destructive) { Task { await session.trash(entry) } }
                                    } else { Button(L10n.text("action.restore")) { Task { await session.restore(entry) } } }
                                }
                            }
                        }.padding(.horizontal, 12).padding(.bottom, 20)
                    }.onChange(of: filter) { _, _ in if let first = filtered.first { proxy.scrollTo(first.id, anchor: .top) } }
                    #if os(macOS)
                    .focusable().focusEffectDisabled().onMoveCommand { direction in
                        let index = filtered.firstIndex { $0.id == selection } ?? -1
                        if direction == .down, index + 1 < filtered.count { select(filtered[index + 1]); proxy.scrollTo(selection) }
                        if direction == .up, index > 0 { select(filtered[index - 1]); proxy.scrollTo(selection) }
                    }
                    #endif
                }
            }
            if !mobile {
                HStack(spacing: 6) {
                    Circle().fill(AegisTheme.teal).frame(width: 5, height: 5)
                    Text(session.syncTitle).font(.system(size: 11)).foregroundStyle(AegisTheme.secondary)
                    Spacer()
                }.padding(.horizontal, 24).padding(.vertical, 17)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AegisTheme.surface)
    }

    private var detail: some View {
        Group {
            if let entry = selectedEntry { ItemDetailView(entry: entry).id(entry.id) }
            else {
                VStack(spacing: 22) {
                    ZStack {
                        Circle().stroke(AegisTheme.border, lineWidth: 1).frame(width: 176, height: 176)
                        Circle().stroke(AegisTheme.border.opacity(0.6), lineWidth: 1).frame(width: 224, height: 224)
                        AegisMark(size: 88).rotationEffect(.degrees(-7))
                    }.accessibilityHidden(true)
                    VStack(spacing: 10) {
                        Text(L10n.text("list.selectTitle")).font(.system(size: 25, weight: .medium, design: .serif)).foregroundStyle(AegisTheme.text)
                        Text(L10n.text("list.selectDescription")).font(.system(size: 13)).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                    }.multilineTextAlignment(.center)
                    AegisPill(title: L10n.text("ui.protected"), symbol: "checkmark.shield")
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(AegisTheme.background)
            }
        }
    }
    private func select(_ entry: VaultEntry) { selection = entry.id; selectedItem = entry.item.id; session.touch() }
    private var newItemKind: ItemKind { switch filter { case .card: .card; case .note: .note; default: .login } }
    private var emptyTitle: String {
        if !search.isEmpty { return "list.noResults" }
        switch filter { case .trash: return "list.trashEmpty"; case .favorites: return "list.favoritesEmpty"; default: return "list.emptyTitle" }
    }
    private var emptyDescription: String {
        if !search.isEmpty { return "list.noResultsDescription" }
        switch filter { case .trash: return "list.trashDescription"; case .favorites: return "list.favoritesDescription"; default: return "list.emptyDescription" }
    }
}

private struct VaultRecordRow: View {
    let entry: VaultEntry
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    @ScaledMetric(relativeTo: .body) private var titleSize = 14
    @ScaledMetric(relativeTo: .caption) private var subtitleSize = 12
    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ItemIcon(item: entry.item, isSelected: selected, size: 42)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.item.title).font(.system(size: titleSize, weight: .semibold)).foregroundStyle(AegisTheme.text).lineLimit(1)
                    Text(entry.item.kind == .login && !entry.item.username.isEmpty ? entry.item.username : entry.item.kind.title)
                        .font(.system(size: subtitleSize)).foregroundStyle(selected ? AegisTheme.teal : AegisTheme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if entry.isConflict { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityLabel(L10n.text("list.conflict")) }
                if entry.item.isFavorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(AegisTheme.gold) }
            }.padding(.horizontal, 13).padding(.vertical, 15).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? AegisTheme.selected : hovered ? AegisTheme.inset : Color.clear, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? AegisTheme.teal.opacity(0.12) : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain).onHover { hovered = $0 }.accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("record-\(entry.item.title)")
    }
}
