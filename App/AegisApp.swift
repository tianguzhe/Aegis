import AegisCore
import SwiftUI
#if os(macOS)
    import AppKit
#endif

@main
struct AegisApp: App {
    @State private var session = VaultSession()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("aegis.appearance") private var appearance: AegisAppearance = .system
    init() {
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
                Button(L10n.text(actions?.isTrashed == true ? "action.deleteImmediately" : "action.trash")) { actions?.trash() }
                    .keyboardShortcut(.delete).disabled(actions?.hasSelection != true)
                Button(L10n.text("action.restore")) { actions?.restore() }
                    .disabled(actions?.hasSelection != true || actions?.isTrashed != true)
                Divider()
                Button(L10n.text("nav.generator")) { actions?.generator() }
                    .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(actions == nil)
            }
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
        #if os(macOS)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in session.lock(reason: .system) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in session.lock(reason: .system) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in session.lock(reason: .system) }
        #endif
        .vaultErrorPresenter()
        .sheet(isPresented: Binding(get: { session.recoveryKey != nil && !session.recoveryPresentedInline }, set: { _ in })) { RecoveryView().environment(session) }
    }
}
