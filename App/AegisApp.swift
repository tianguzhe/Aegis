import AegisCore
import SwiftUI
#if os(macOS)
    import AppKit
#endif

@main
struct AegisApp: App {
    @State private var session: VaultSession
    #if os(macOS)
        @State private var quickAccess: QuickAccessController
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("aegis.appearance") private var appearance: AegisAppearance = .system
    init() {
        let session = VaultSession()
        _session = State(initialValue: session)
        #if os(macOS)
            _quickAccess = State(initialValue: QuickAccessController(session: session))
        #endif
        #if DEBUG && os(macOS)
            CardDesignGallery.renderIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView().environment(session)
                .tint(AegisTheme.teal)
                .preferredColorScheme(appearance.colorScheme)
            #if os(macOS)
                .frame(minWidth: 940, minHeight: 640)
            #endif
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            session.setLANSyncForeground(phase == .active)
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            VaultCommands()
            CommandGroup(after: .appInfo) {
                Button(L10n.text("action.lock")) { session.lock() }.keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(session.phase != .unlocked)
            }
        }
        #endif
        #if os(macOS)
            MenuBarExtra("Aegis", systemImage: "lock.shield") {
                Button(L10n.text("quick.search")) { quickAccess.show() }
                if !quickAccess.hotKeyRegistered {
                    Text(L10n.format("quick.hotKeyUnavailable", QuickAccessController.shortcutLabel))
                }
                Button(L10n.text("quick.openApp")) { quickAccess.openMainWindow() }
                Divider()
                Button(L10n.text("action.lock")) { session.lock() }.disabled(session.phase != .unlocked)
                Divider()
                Button(L10n.text("quick.quit")) { NSApp.terminate(nil) }
            }
        #endif
    }
}

#if os(macOS)
    private struct VaultCommands: Commands {
        @FocusedValue(\.vaultMenuActions) private var actions
        var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("action.add")) { actions?.add() }
                    .keyboardShortcut("n").disabled(actions == nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("action.settings")) { actions?.settings() }
                    .keyboardShortcut(",").disabled(actions == nil)
            }
            CommandGroup(after: .textEditing) {
                Button(L10n.text("action.search")) { actions?.search() }
                    .keyboardShortcut("f").disabled(actions == nil)
            }
            CommandMenu(L10n.text("menu.record")) {
                Button(L10n.text("action.edit")) { actions?.edit() }
                    .keyboardShortcut("e").disabled(actions?.hasSelection != true || actions?.isTrashed == true)
                Button(L10n.text(actions?.isFavorite == true ? "action.unfavorite" : "action.favorite")) { actions?.favorite() }
                    .keyboardShortcut("d").disabled(actions?.hasSelection != true || actions?.isTrashed == true)
                Divider()
                quickCopyButton(at: 0, fallbackKey: "action.copyUsername").keyboardShortcut("c", modifiers: [.command, .shift])
                quickCopyButton(at: 1, fallbackKey: "action.copyPassword").keyboardShortcut("c", modifiers: [.command, .option])
                Divider()
                Button(L10n.text(actions?.isTrashed == true ? "action.deleteImmediately" : "action.trash")) { actions?.trash() }
                    .keyboardShortcut(.delete).disabled(actions?.hasSelection != true)
                Button(L10n.text("action.restore")) { actions?.restore() }
                    .disabled(actions?.hasSelection != true || actions?.isTrashed != true)
                Divider()
                Button(L10n.text("nav.generator")) { actions?.generator() }
                    .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(actions == nil)
            }
        }

        /// Index 0 is the identifier and 1 the secret (see `VaultItem.quickCopyFields`);
        /// notes and empty selections fall back to a disabled login label.
        private func quickCopyButton(at index: Int, fallbackKey: String) -> some View {
            let field = actions?.quickCopyFields.indices.contains(index) == true ? actions?.quickCopyFields[index] : nil
            return Button(L10n.text(field?.actionKey ?? fallbackKey)) {
                if let field {
                    actions?.copy(field)
                }
            }.disabled(field?.value.isEmpty ?? true)
        }
    }
#endif

struct RootView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            switch session.phase {
            case .loading: ProgressView(L10n.text("app.loading")).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .setup, .locked: UnlockView()
            case .unlocked: VaultView()
            }
        }
        #if os(iOS)
        .overlay {
            if scenePhase != .active, session.phase == .unlocked {
                ZStack { AegisTheme.background.ignoresSafeArea(); AegisMark(size: 80) }
            }
        }
        #endif
        .task { await session.bootstrap() }
        .simultaneousGesture(TapGesture().onEnded { session.touch() })
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                session.lock(reason: .background)
            }
        }
        .vaultErrorPresenter()
        .sheet(isPresented: Binding(get: { session.recoveryKey != nil && !session.recoveryPresentedInline }, set: { _ in })) { RecoveryView().environment(session) }
    }
}
