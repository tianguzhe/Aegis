import AegisCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct AegisApp: App {
    @State private var session = VaultSession()
    var body: some Scene {
        WindowGroup {
            RootView().environment(session)
                .tint(AegisTheme.teal)
                #if os(macOS)
                .frame(minWidth: 940, minHeight: 640)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.text("action.lock")) { session.lock() }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        #endif
    }
}

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
            if scenePhase != .active && session.phase == .unlocked {
                ZStack { AegisTheme.background.ignoresSafeArea(); AegisMark(size: 80) }
            }
        }
        #endif
        .task { await session.bootstrap() }
        .simultaneousGesture(TapGesture().onEnded { session.touch() })
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.lock() }
        }
        #if os(macOS)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in session.lock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in session.lock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in session.lock() }
        #endif
        .alert(L10n.text("app.error"), isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button(L10n.text("action.done")) { session.error = nil }
        } message: { Text(session.error ?? "") }
        .sheet(isPresented: Binding(get: { session.recoveryKey != nil }, set: { _ in })) { RecoveryView().environment(session) }
    }
}
