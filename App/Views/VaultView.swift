import AegisCore
import SwiftUI

enum VaultFilter: String, CaseIterable, Identifiable {
    case all, favorites, login, card, note, trash
    var id: String {
        rawValue
    }

    var title: String {
        L10n.text(["all": "nav.all", "favorites": "nav.favorites", "login": "kind.login", "card": "kind.card", "note": "kind.note", "trash": "nav.trash"][rawValue]!)
    }

    var symbol: String {
        switch self { case .all: "square.grid.2x2"; case .favorites: "star"; case .login: "key.horizontal"; case .card: "creditcard"; case .note: "note.text"; case .trash: "trash" }
    }

    func includes(_ entry: VaultEntry) -> Bool {
        if self == .trash {
            return entry.item.deletedAt != nil
        }
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
    @State private var presentedSheet: VaultSheet?
    @FocusState private var searchFocused: Bool
    @State private var recentFirst = false
    @State private var mobilePath: [UUID] = []
    @State private var selectedTab = 0
    @State private var pendingDeletion: VaultEntry?
    @State private var pendingTrash: VaultEntry?

    private var filtered: [VaultEntry] {
        session.entries.filter { entry in
            filter.includes(entry) && entry.matchesSearch(search)
        }.sorted { recentFirst ? $0.item.modifiedAt > $1.item.modifiedAt : $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending }
    }

    private var selectedEntry: VaultEntry? {
        session.entries.first { $0.id == selection } ?? session.entries.first { $0.item.id == selectedItem }
    }

    var body: some View {
        Group {
            #if os(macOS)
                HSplitView {
                    sidebar.frame(minWidth: 190, idealWidth: 208, maxWidth: 228)
                    recordsColumn(mobile: false).frame(minWidth: 290, idealWidth: 312, maxWidth: 350)
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
                    } else {
                        mobileTabs
                    }
                }
            #endif
        }
        .background(AegisTheme.background)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case let .editor(item, parents):
                ItemEditorView(item: item, parents: parents, onSaved: selectSavedItem).environment(session)
            case .settings: SettingsView().environment(session)
            case .generator: GeneratorView().environment(session)
            }
        }
        .onAppear { reconcileSelection() }
        .onChange(of: filter) { _, _ in session.touch() }
        .onChange(of: search) { _, _ in session.touch() }
        .onChange(of: filtered.map(\.id)) { previous, _ in reconcileSelection(previousIDs: previous) }
        #if os(macOS)
            .focusedSceneValue(\.vaultMenuActions, menuActions)
        #endif
            .alert(L10n.text("action.trash"), isPresented: Binding(
                get: { pendingTrash != nil }, set: {
                    if !$0 {
                        pendingTrash = nil
                    }
                }
            ), presenting: pendingTrash) { entry in
                Button(L10n.text("action.cancel"), role: .cancel) {}
                Button(L10n.text("action.trash"), role: .destructive) { Task { await session.trash(entry) } }
            } message: { _ in Text(L10n.format("trash.retention", Int64(TrashPolicy.retentionDays))) }
            .alert(L10n.text("trash.deleteConfirm"), isPresented: Binding(
                get: { pendingDeletion != nil }, set: {
                    if !$0 {
                        pendingDeletion = nil
                    }
                }
            ), presenting: pendingDeletion) { entry in
                Button(L10n.text("action.deleteImmediately"), role: .destructive) { Task { await session.deleteImmediately(entry) } }
                Button(L10n.text("action.cancel"), role: .cancel) {}
            } message: { entry in Text(L10n.format("trash.deleteMessage", entry.item.title)) }
    }

    #if os(iOS)
        private var mobileTabs: some View {
            TabView(selection: $selectedTab) {
                NavigationStack(path: $mobilePath) {
                    recordsColumn(mobile: true)
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(for: UUID.self) { id in
                            if let entry = session.entries.first(where: { $0.item.id == id && $0.id == selection }) ?? session.entries.first(where: { $0.item.id == id }) {
                                ItemDetailView(entry: entry, onEdit: { edit(entry) }).id(entry.item.id)
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
            AegisBrand(compact: true).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).frame(height: AegisMetrics.toolbarHeight).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sidebarSection("nav.library", values: [.all, .favorites, .trash])
                    sidebarSection("nav.categories", values: [.login, .card, .note])
                    VStack(alignment: .leading, spacing: 10) {
                        sectionCaption("nav.tools")
                        sidebarAction("nav.generator", symbol: "wand.and.stars") { presentedSheet = .generator }
                        sidebarAction("nav.settings", symbol: "slider.horizontal.3") { presentedSheet = .settings }
                    }
                }.padding(.horizontal, 14).padding(.bottom, 20)
            }.scrollIndicators(.hidden)
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(AegisTheme.teal)
                    .frame(width: 34, height: 34).background(AegisTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                Text(L10n.text("ui.personalVault")).aegisFont(size: 12, weight: .medium).foregroundStyle(AegisTheme.text)
                Spacer(minLength: 0)
                AegisIconButton(symbol: "lock", label: L10n.text("action.lock")) { session.lock() }
            }.padding(14)
                .overlay(alignment: .top) { Rectangle().fill(AegisTheme.border).frame(height: 0.5) }
        }.frame(maxHeight: .infinity).background(AegisTheme.sidebar)
    }

    private func sidebarSection(_ title: String, values: [VaultFilter]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionCaption(title)
            VStack(spacing: 4) { ForEach(values) { sidebarRow($0) } }
        }
    }

    private func sectionCaption(_ key: String) -> some View {
        Text(L10n.text(key)).aegisFont(size: 10, weight: .semibold).foregroundStyle(AegisTheme.secondary)
            .padding(.horizontal, 10).tracking(0.3)
    }

    private func sidebarRow(_ value: VaultFilter) -> some View {
        let active = filter == value
        let count = session.entries.filter { value.includes($0) }.count
        return Button { filter = value } label: {
            HStack(spacing: 12) {
                Image(systemName: value.symbol).font(.system(size: 14, weight: active ? .semibold : .regular)).frame(width: 20)
                Text(value.title).aegisFont(size: 13, weight: active ? .semibold : .regular)
                Spacer(minLength: 0)
                if count > 0 {
                    Text(count, format: .number).aegisFont(size: 10, weight: .medium).monospacedDigit()
                        .foregroundStyle(active ? AegisTheme.teal : AegisTheme.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(active ? AegisTheme.surface.opacity(0.65) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                }
            }.foregroundStyle(active ? AegisTheme.teal : AegisTheme.text)
                .padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity)
                .background(active ? AegisTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: AegisMetrics.controlRadius))
                .contentShape(Rectangle())
        }.buttonStyle(AegisNavigationButtonStyle()).accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func sidebarAction(_ key: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(L10n.text(key), systemImage: symbol).aegisFont(size: 13).foregroundStyle(AegisTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(AegisNavigationButtonStyle())
    }

    private func recordsColumn(mobile: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if mobile {
                    HStack {
                        AegisBrand(compact: true)
                        Spacer()
                        AegisIconButton(symbol: "lock", label: L10n.text("action.lock")) { session.lock() }
                    }.padding(.horizontal, 20).padding(.top, 12)
                }
                HStack(spacing: 8) {
                    Text(filter.title).aegisFont(size: mobile ? 24 : 16, weight: .semibold).foregroundStyle(AegisTheme.text)
                        .accessibilityIdentifier("vaultListTitle")
                    Text(filtered.count, format: .number).aegisFont(size: 11, weight: .medium).monospacedDigit()
                        .foregroundStyle(AegisTheme.secondary).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(AegisTheme.inset, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel(L10n.format("list.count", Int64(filtered.count)))
                    Spacer(minLength: 4)
                    if filter != .trash {
                        #if os(macOS)
                            Button(action: addItem) { Label(L10n.text("action.new"), systemImage: "plus") }
                                .buttonStyle(.bordered).controlSize(.regular).accessibilityIdentifier("addItemButton")
                                .disabled(session.unreadableRevisionCount > 0)
                                .help(L10n.text("action.add") + " (⌘N)")
                        #else
                            AegisIconButton(symbol: "plus", label: L10n.text("action.add"), prominent: true, action: addItem)
                                .accessibilityIdentifier("addItemButton")
                                .disabled(session.unreadableRevisionCount > 0)
                        #endif
                    }
                }.padding(.horizontal, 18).frame(minHeight: AegisMetrics.toolbarHeight)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(AegisTheme.secondary)
                    TextField(L10n.text("action.search"), text: $search).textFieldStyle(.plain).aegisFont(size: 13)
                        .aegisNoCapitalization().autocorrectionDisabled().accessibilityIdentifier("vaultSearch")
                        .focused($searchFocused)
                    if !search.isEmpty {
                        AegisIconButton(symbol: "xmark.circle.fill", label: L10n.text("ui.clearSearch")) { search = "" }
                    }
                    #if os(macOS)
                        if search.isEmpty {
                            Text("⌘F").font(.system(size: 10)).foregroundStyle(AegisTheme.secondary).accessibilityHidden(true)
                        }
                    #endif
                }
                .padding(.leading, 11).padding(.trailing, search.isEmpty ? 11 : 2)
                .frame(minHeight: AegisMetrics.controlHeight + 4)
                .background(AegisTheme.inset, in: RoundedRectangle(cornerRadius: AegisMetrics.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: AegisMetrics.controlRadius)
                    .strokeBorder(searchFocused ? AegisTheme.teal.opacity(0.6) : Color.clear, lineWidth: 1))
                .padding(.horizontal, 16).padding(.bottom, 12)
                if mobile {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(VaultFilter.allCases) { value in
                                Button { filter = value } label: {
                                    Label(value.title, systemImage: value.symbol).aegisFont(size: 12, weight: .medium)
                                        .padding(.horizontal, 12).frame(minHeight: 44)
                                        .foregroundStyle(filter == value ? AegisTheme.teal : AegisTheme.secondary)
                                        .background(filter == value ? AegisTheme.selected : AegisTheme.inset,
                                                    in: RoundedRectangle(cornerRadius: AegisMetrics.controlRadius))
                                }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
                            }
                        }.padding(.horizontal, 16)
                    }.scrollIndicators(.hidden).padding(.bottom, 12)
                }
            }
            if session.unreadableRevisionCount > 0 {
                Label(L10n.format("list.damagedHistory", Int64(session.unreadableRevisionCount)), systemImage: "exclamationmark.triangle")
                    .aegisFont(size: 12).foregroundStyle(AegisTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(AegisTheme.inset, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .accessibilityIdentifier("vaultIntegrityWarning")
            }
            if filter == .trash {
                Label(L10n.format("trash.retention", Int64(TrashPolicy.retentionDays)), systemImage: "clock")
                    .aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if !session.recoverableDrafts.isEmpty {
                Menu {
                    ForEach(session.recoverableDrafts) { draft in
                        Button(draft.item.title.isEmpty ? L10n.text("list.untitled") : draft.item.title) { presentedSheet = .editor(draft.original, draft.parents) }
                    }
                } label: {
                    Label(L10n.format("draft.resumeCount", Int64(session.recoverableDrafts.count)), systemImage: "square.and.pencil")
                        .font(.callout).foregroundStyle(AegisTheme.teal).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(AegisTheme.selected, in: RoundedRectangle(cornerRadius: 10))
                }.menuStyle(.borderlessButton).padding(.horizontal, 22).padding(.bottom, 14)
                    .accessibilityIdentifier("resumeDrafts")
            }
            HStack {
                Text(L10n.text("menu.record")).aegisFont(size: 11, weight: .medium).foregroundStyle(AegisTheme.secondary)
                Spacer()
                Menu {
                    Picker(L10n.text("ui.sort"), selection: $recentFirst) {
                        Text(L10n.text("ui.nameOrder")).tag(false)
                        Text(L10n.text("ui.recentOrder")).tag(true)
                    }
                } label: {
                    Label(L10n.text(recentFirst ? "ui.recentOrder" : "ui.nameOrder"), systemImage: "arrow.up.arrow.down")
                        .aegisFont(size: 10).frame(minHeight: AegisMetrics.controlHeight)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(AegisTheme.secondary).accessibilityLabel(L10n.text("ui.sort"))
            }.padding(.horizontal, 18).padding(.bottom, 4)
            if filtered.isEmpty {
                VStack(spacing: 0) {
                    AegisEmptyState(title: L10n.text(emptyTitle), message: L10n.text(emptyDescription), symbol: search.isEmpty ? filter.symbol : "magnifyingglass")
                    if filter != .trash, search.isEmpty, session.unreadableRevisionCount == 0 {
                        Button(L10n.text("action.add")) { addItem() }.buttonStyle(AegisButtonStyle(primary: true)).padding(.bottom, 32)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(filtered) { entry in
                                VaultRecordRow(entry: entry, selected: !mobile && selectedEntry?.id == entry.id) {
                                    select(entry)
                                    if mobile {
                                        mobilePath.append(entry.item.id)
                                    }
                                }.id(entry.id)
                                    .contextMenu {
                                        // Copying is read-only, so it stays available on partially readable vaults.
                                        let copyFields = entry.item.quickCopyFields
                                        ForEach(copyFields, id: \.actionKey) { field in
                                            Button(L10n.text(field.actionKey)) { quickCopy(field) }.disabled(field.value.isEmpty)
                                        }
                                        if entry.item.oneTimePassword != nil {
                                            Button(L10n.text("action.copyOneTimeCode")) { copyOneTimeCode(entry.item) }
                                                .disabled(entry.item.oneTimeCode(at: Date()) == nil)
                                        }
                                        if !copyFields.isEmpty, session.unreadableRevisionCount == 0 {
                                            Divider()
                                        }
                                        if session.unreadableRevisionCount > 0 {
                                            EmptyView()
                                        } else if entry.item.deletedAt == nil {
                                            Button(L10n.text("action.edit")) { edit(entry) }
                                            Button(L10n.text(entry.item.isFavorite ? "action.unfavorite" : "action.favorite")) { Task { await session.toggleFavorite(entry) } }
                                            Divider()
                                            Button(L10n.text("action.trash"), role: .destructive) { pendingTrash = entry }
                                        } else {
                                            Button(L10n.text("action.restore")) { Task { await session.restore(entry) } }
                                            Button(L10n.text("action.deleteImmediately"), role: .destructive) { pendingDeletion = entry }
                                        }
                                    }.disabled(session.pendingItemIDs.contains(entry.item.id))
                            }
                        }.padding(.horizontal, 10).padding(.bottom, 16)
                    }.onChange(of: selection) {
                        _, id in if let id {
                            proxy.scrollTo(id)
                        }
                    }
                    #if os(macOS)
                    .focusable().focusEffectDisabled().onMoveCommand { direction in
                        let index = filtered.firstIndex { $0.id == selection } ?? -1
                        if direction == .down, index + 1 < filtered.count {
                            select(filtered[index + 1]); proxy.scrollTo(selection)
                        }
                        if direction == .up, index > 0 {
                            select(filtered[index - 1]); proxy.scrollTo(selection)
                        }
                    }
                    #endif
                }
            }
            if let notice = session.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .aegisFont(size: 12).foregroundStyle(AegisTheme.teal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(AegisTheme.selected, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .accessibilityIdentifier("operationNotice")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AegisTheme.surface)
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            ItemDetailView(entry: entry, onEdit: { edit(entry) }).id(entry.item.id)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Label(L10n.text("app.vault"), systemImage: "lock.shield")
                        .aegisFont(size: 12, weight: .medium).foregroundStyle(AegisTheme.secondary)
                    Spacer()
                }.padding(.horizontal, 24).frame(height: AegisMetrics.toolbarHeight)
                    .background(AegisTheme.surface)
                    .overlay(alignment: .bottom) { Rectangle().fill(AegisTheme.border).frame(height: 0.5) }
                AegisEmptyState(title: L10n.text(search.isEmpty ? "list.selectTitle" : "list.noResults"),
                                message: L10n.text(search.isEmpty ? "list.selectDescription" : "list.noResultsDescription"),
                                symbol: search.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass")
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AegisTheme.background)
        }
    }

    private func addItem() {
        guard session.unreadableRevisionCount == 0 else { return }
        presentedSheet = .editor(VaultItem(kind: newItemKind), [])
    }

    private func edit(_ entry: VaultEntry) {
        guard session.unreadableRevisionCount == 0, entry.item.deletedAt == nil else { return }
        presentedSheet = .editor(entry.item, [entry.id])
    }

    private func quickCopy(_ field: QuickCopyField) {
        guard !field.value.isEmpty else { return }
        SecureClipboard.copy(field.value); session.touch()
    }

    /// Computed at click time: TOTP codes roll over every period.
    private func copyOneTimeCode(_ item: VaultItem) {
        guard let code = item.oneTimeCode(at: Date()) else { return }
        SecureClipboard.copy(code); session.touch()
    }

    private func selectSavedItem(_ id: UUID) {
        guard let entry = session.entries.first(where: { $0.item.id == id }) else { return }
        search = ""
        if !filter.includes(entry) {
            filter = .all
        }
        select(entry)
    }

    private func reconcileSelection(previousIDs: [UUID] = []) {
        if let entry = filtered.first(where: { $0.id == selection }) ?? filtered.first(where: { $0.item.id == selectedItem }) {
            selection = entry.id; selectedItem = entry.item.id
            return
        }
        let index = previousIDs.firstIndex(where: { $0 == selection }) ?? 0
        selection = nil; selectedItem = nil
        #if os(macOS)
            if !filtered.isEmpty {
                let next = filtered[min(index, filtered.count - 1)]
                selection = next.id; selectedItem = next.item.id
            }
        #else
            mobilePath = []
        #endif
    }

    #if os(macOS)
        private var menuActions: VaultMenuActions? {
            guard presentedSheet == nil, pendingTrash == nil, pendingDeletion == nil,
                  session.error == nil, session.recoveryKey == nil else { return nil }
            let entry = selectedEntry
            let available = session.unreadableRevisionCount == 0 &&
                (entry.map { !session.pendingItemIDs.contains($0.item.id) } ?? false)
            return VaultMenuActions(
                add: addItem, search: { searchFocused = true },
                settings: { presentedSheet = .settings }, generator: { presentedSheet = .generator },
                edit: {
                    if let entry {
                        edit(entry)
                    }
                },
                trash: {
                    if let entry {
                        if entry.item.deletedAt == nil {
                            pendingTrash = entry
                        } else {
                            pendingDeletion = entry
                        }
                    }
                },
                restore: {
                    if let entry {
                        Task { await session.restore(entry) }
                    }
                },
                favorite: {
                    if let entry {
                        Task { await session.toggleFavorite(entry) }
                    }
                },
                hasSelection: available, isTrashed: entry?.item.deletedAt != nil, isFavorite: entry?.item.isFavorite == true,
                // Copy ignores `available`: it is read-only and allowed on partially readable vaults.
                quickCopyFields: entry?.item.quickCopyFields ?? [], copy: quickCopy,
                hasOneTimeCode: entry?.item.oneTimeCode(at: Date()) != nil,
                copyOneTimeCode: {
                    if let entry {
                        copyOneTimeCode(entry.item)
                    }
                }
            )
        }
    #endif
    private func select(_ entry: VaultEntry) {
        selection = entry.id; selectedItem = entry.item.id; session.touch()
    }

    private var newItemKind: ItemKind {
        switch filter { case .card: .card; case .note: .note; default: .login }
    }

    private var emptyTitle: String {
        if !search.isEmpty {
            return "list.noResults"
        }
        switch filter { case .trash: return "list.trashEmpty"; case .favorites: return "list.favoritesEmpty"; default: return "list.emptyTitle" }
    }

    private var emptyDescription: String {
        if !search.isEmpty {
            return "list.noResultsDescription"
        }
        switch filter { case .trash: return "list.trashDescription"; case .favorites: return "list.favoritesDescription"; default: return "list.emptyDescription" }
    }
}

private struct VaultRecordRow: View {
    let entry: VaultEntry
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    @ScaledMetric(relativeTo: .body) private var titleSize = 13
    @ScaledMetric(relativeTo: .caption) private var subtitleSize = 11
    private var rowPadding: CGFloat {
        #if os(macOS)
            11
        #else
            15
        #endif
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ItemIcon(item: entry.item, isSelected: selected, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.item.title).font(.system(size: titleSize, weight: .semibold)).foregroundStyle(AegisTheme.text).lineLimit(1)
                    Text(entry.listSubtitle)
                        .font(.system(size: subtitleSize)).foregroundStyle(selected ? AegisTheme.teal : AegisTheme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if entry.isConflict {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityLabel(L10n.text("list.conflict"))
                }
                if entry.item.isFavorite {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(AegisTheme.gold)
                }
            }.padding(.horizontal, 13).padding(.vertical, rowPadding).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? AegisTheme.selected : hovered ? AegisTheme.inset : Color.clear, in: RoundedRectangle(cornerRadius: AegisMetrics.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: AegisMetrics.controlRadius).stroke(selected ? AegisTheme.teal.opacity(0.12) : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: AegisMetrics.controlRadius))
        }.buttonStyle(.plain).onHover { hovered = $0 }.accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("record-\(entry.item.title)")
    }
}

extension VaultEntry {
    /// Shared by the main list and the macOS quick-access panel so both find the same records.
    func matchesSearch(_ text: String) -> Bool {
        text.isEmpty || [item.title, item.username, item.website].contains { $0.localizedStandardContains(text) }
    }

    var listSubtitle: String {
        if item.kind == .card {
            return item.cardDescription
        }
        if item.kind == .login, !item.username.isEmpty {
            return item.username
        }
        return item.kind.title
    }
}

private enum VaultSheet: Identifiable {
    case editor(VaultItem, [UUID]), settings, generator
    var id: String {
        switch self {
        case let .editor(item, _): "editor-\(item.id)"
        case .settings: "settings"
        case .generator: "generator"
        }
    }
}

#if os(macOS)
    struct VaultMenuActions {
        let add: () -> Void
        let search: () -> Void
        let settings: () -> Void
        let generator: () -> Void
        let edit: () -> Void
        let trash: () -> Void
        let restore: () -> Void
        let favorite: () -> Void
        let hasSelection: Bool
        let isTrashed: Bool
        let isFavorite: Bool
        let quickCopyFields: [QuickCopyField]
        let copy: (QuickCopyField) -> Void
        let hasOneTimeCode: Bool
        let copyOneTimeCode: () -> Void
    }

    private struct VaultMenuActionsKey: FocusedValueKey {
        typealias Value = VaultMenuActions
    }

    extension FocusedValues {
        var vaultMenuActions: VaultMenuActions? {
            get { self[VaultMenuActionsKey.self] }
            set { self[VaultMenuActionsKey.self] = newValue }
        }
    }
#endif
