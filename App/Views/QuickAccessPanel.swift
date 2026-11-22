#if os(macOS)
    import AegisCore
    import AppKit
    import Carbon.HIToolbox
    import SwiftUI

    /// App-lifetime owner of the quick-access panel, its global shortcut and the system lock
    /// triggers. The app keeps running after its last window closes, so these must not live
    /// in a window's view tree or sleep/screen-lock would stop locking the vault.
    @MainActor
    final class QuickAccessController {
        static let shortcutLabel = "⇧⌘Space"
        private let session: VaultSession
        private var panel: NSPanel?
        private var hotKey: GlobalHotKey?
        private var observers: [NSObjectProtocol] = []
        /// Set only for unlocks started from the panel. `session.isBusy` is not used because saves,
        /// imports and key rotation also set it, and would keep an unfocused panel on screen.
        private var unlockInFlight = false

        init(session: VaultSession) {
            self.session = session
            hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in self?.toggle() }
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.hide()
                        self?.session.lock(reason: .system)
                    }
                })
            }
        }

        var hotKeyRegistered: Bool {
            hotKey != nil
        }

        func toggle() {
            if panel?.isVisible == true {
                hide()
            } else {
                show()
            }
        }

        func show() {
            let panel = panel ?? makePanel()
            self.panel = panel
            // A fresh hosting view per presentation resets the search and focuses the field.
            panel.contentView = NSHostingView(rootView: QuickAccessView(onDone: { [weak self] in self?.hide() }, onOpenApp: { [weak self] in self?.openMainWindow() },
                                                                        runUnlock: { [weak self] refocus, work in self?.runUnlock(refocus: refocus, work) })
                    .environment(session).tint(AegisTheme.teal))
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + screen.height * 0.62))
            }
            panel.makeKeyAndOrderFront(nil)
        }

        func hide() {
            guard let panel, panel.isVisible else { return }
            panel.orderOut(nil)
            // Drop the rendered records instead of keeping plaintext views around while hidden. Deferred because
            // hide() usually runs inside a button action of that very hosting view; skip if show() replaced it.
            let hosted = panel.contentView
            Task { @MainActor in
                if !panel.isVisible, panel.contentView === hosted {
                    panel.contentView = nil
                }
            }
        }

        /// Resign-key is ignored while the panel's unlock runs, so re-check once it ends; otherwise a panel
        /// that lost focus mid-unlock would float over every Space with no further event to hide it.
        private func runUnlock(refocus: Bool, _ work: @escaping @MainActor () async -> Void) {
            unlockInFlight = true
            Task {
                await work()
                unlockInFlight = false
                settleAfterUnlock(refocus: refocus)
            }
        }

        private func settleAfterUnlock(refocus: Bool) {
            guard let panel, panel.isVisible else { return }
            if refocus {
                // Touch ID's system prompt took key status; hand it back to the panel the user was using.
                panel.makeKeyAndOrderFront(nil)
            } else if !panel.isKeyWindow {
                hide()
            }
        }

        func openMainWindow() {
            hide()
            NSApp.activate(ignoringOtherApps: true)
            // SwiftUI may keep a closed window object around; only reuse one that is still shown or minimized.
            if let window = NSApp.windows.first(where: { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }) {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            } else {
                // SwiftUI recreates the WindowGroup window when the app is reopened.
                NSWorkspace.shared.open(Bundle.main.bundleURL)
            }
        }

        private func makePanel() -> NSPanel {
            let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                                     styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: true)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                panel.standardWindowButton(button)?.isHidden = true
            }
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                // The Touch ID prompt takes key status; keep the panel while its unlock runs.
                MainActor.assumeIsolated {
                    if self?.unlockInFlight != true {
                        self?.hide()
                    }
                }
            })
            return panel
        }
    }

    /// Non-activating panels refuse key status by default, which would block typing.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool {
            true
        }
    }

    private struct QuickAccessView: View {
        @Environment(VaultSession.self) private var session
        let onDone: () -> Void
        let onOpenApp: () -> Void
        let runUnlock: (_ refocus: Bool, _ work: @escaping @MainActor () async -> Void) -> Void

        var body: some View {
            Group {
                switch session.phase {
                case .unlocked: QuickAccessSearch(onDone: onDone)
                case .locked: QuickAccessUnlock(runUnlock: runUnlock)
                case .loading, .setup:
                    VStack(spacing: 14) {
                        AegisMark(size: 44)
                        Button(L10n.text("quick.openApp"), action: onOpenApp).buttonStyle(AegisButtonStyle())
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(width: 560, height: 400).background(AegisTheme.surface)
                .onExitCommand(perform: onDone)
                .privacySensitive()
        }
    }

    private struct QuickAccessUnlock: View {
        @Environment(VaultSession.self) private var session
        let runUnlock: (_ refocus: Bool, _ work: @escaping @MainActor () async -> Void) -> Void
        @State private var password = ""
        @FocusState private var focused: Bool

        var body: some View {
            VStack(spacing: 16) {
                AegisMark(size: 44)
                Text(L10n.text("quick.locked")).aegisFont(size: 15, weight: .semibold).foregroundStyle(AegisTheme.text)
                SecureField(L10n.text("welcome.master"), text: $password).textFieldStyle(.roundedBorder)
                    .focused($focused).onSubmit(submit).frame(width: 300)
                Button(L10n.text(session.isBusy ? "action.unlocking" : "action.unlock"), action: submit)
                    .buttonStyle(AegisButtonStyle(primary: true)).disabled(password.isEmpty || session.isBusy)
                if session.biometricEnabled {
                    Button {
                        session.error = nil
                        runUnlock(true) { await session.unlockWithBiometrics() }
                    } label: { Label(L10n.text("unlock.biometric"), systemImage: "touchid") }
                        .buttonStyle(AegisButtonStyle()).disabled(session.isBusy)
                }
                if let error = session.error {
                    Text(error).aegisFont(size: 12).foregroundStyle(AegisTheme.danger).multilineTextAlignment(.center).frame(width: 320)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(session.isBusy)
                .onAppear { focused = true }
        }

        private func submit() {
            guard !password.isEmpty, !session.isBusy else { return }
            let submitted = password; password = ""
            session.error = nil
            runUnlock(false) { await session.unlock(password: submitted) }
        }
    }

    private struct QuickAccessSearch: View {
        @Environment(VaultSession.self) private var session
        let onDone: () -> Void
        @State private var search = ""
        @State private var selection: VaultEntry.ID?
        @FocusState private var focused: Bool

        private static let resultLimit = 50

        /// Active, copyable records only; favorites first so the common targets need fewer keystrokes.
        private var results: [VaultEntry] {
            Array(session.entries.filter { $0.item.deletedAt == nil && !$0.item.quickCopyFields.isEmpty && $0.matchesSearch(search) }
                .sorted { lhs, rhs in
                    lhs.item.isFavorite != rhs.item.isFavorite ? lhs.item.isFavorite : lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
                }.prefix(Self.resultLimit))
        }

        private var selected: VaultEntry? {
            selected(in: results)
        }

        private func selected(in results: [VaultEntry]) -> VaultEntry? {
            results.first { $0.id == selection } ?? results.first
        }

        var body: some View {
            // Filtering and sorting walk the whole vault, so do it once per render, not once per row.
            let results = results
            let selected = selected(in: results)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(AegisTheme.secondary)
                    TextField(L10n.text("action.search"), text: $search).textFieldStyle(.plain).aegisFont(size: 17)
                        .focused($focused).onSubmit { copy(index: 1) }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                }.padding(.horizontal, 18).padding(.vertical, 16)
                Divider()
                if results.isEmpty {
                    Text(L10n.text("quick.noResults")).aegisFont(size: 13).foregroundStyle(AegisTheme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(results) { entry in
                                    row(entry, isSelected: entry.id == selected?.id).id(entry.id)
                                }
                            }.padding(8)
                        }.onChange(of: selection) { _, id in
                            if let id {
                                proxy.scrollTo(id)
                            }
                        }
                    }
                }
                Divider()
                footer(selected)
            }.onAppear { focused = true; session.touch() }
                .onChange(of: search) { selection = nil }
        }

        private func row(_ entry: VaultEntry, isSelected: Bool) -> some View {
            Button { selection = entry.id } label: {
                HStack(spacing: 12) {
                    ItemIcon(item: entry.item, isSelected: isSelected, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.item.title).aegisFont(size: 13, weight: .semibold).foregroundStyle(AegisTheme.text).lineLimit(1)
                        Text(entry.listSubtitle).aegisFont(size: 11).foregroundStyle(AegisTheme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if entry.isConflict {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityLabel(L10n.text("list.conflict"))
                    }
                }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? AegisTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: AegisMetrics.controlRadius))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }

        private func footer(_ selected: VaultEntry?) -> some View {
            let fields = selected?.item.quickCopyFields ?? []
            return HStack(spacing: 16) {
                Spacer()
                // Index 0 is the identifier and 1 the secret (see `VaultItem.quickCopyFields`).
                if fields.count == 2 {
                    Button { copy(index: 0) } label: { Text(L10n.text(fields[0].actionKey)) + Text("  ⌘↩").foregroundColor(AegisTheme.secondary) }
                        .keyboardShortcut(.return, modifiers: .command).disabled(fields[0].value.isEmpty)
                    Button { copy(index: 1) } label: { Text(L10n.text(fields[1].actionKey)) + Text("  ↩").foregroundColor(AegisTheme.secondary) }
                        .disabled(fields[1].value.isEmpty)
                }
                if selected?.item.oneTimePassword != nil {
                    Button(action: copyOneTimeCode) { Text(L10n.text("action.copyOneTimeCode")) + Text("  ⌥↩").foregroundColor(AegisTheme.secondary) }
                        .keyboardShortcut(.return, modifiers: .option).disabled(selected?.item.oneTimeCode(at: Date()) == nil)
                }
            }.buttonStyle(.plain).aegisFont(size: 12, weight: .medium).foregroundStyle(AegisTheme.text)
                .padding(.horizontal, 18).padding(.vertical, 10)
        }

        /// Computed at press time: TOTP codes roll over every period.
        private func copyOneTimeCode() {
            guard let code = selected?.item.oneTimeCode(at: Date()) else { return }
            SecureClipboard.copy(code); session.touch()
            onDone()
        }

        private func move(_ offset: Int) {
            let results = results
            guard !results.isEmpty else { return }
            let current = results.firstIndex { $0.id == selected(in: results)?.id } ?? 0
            selection = results[min(max(current + offset, 0), results.count - 1)].id
        }

        private func copy(index: Int) {
            guard let fields = selected?.item.quickCopyFields, fields.indices.contains(index), !fields[index].value.isEmpty else { return }
            SecureClipboard.copy(fields[index].value); session.touch()
            onDone()
        }
    }
#endif
