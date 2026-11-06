import AegisCore
import SwiftUI

/// Only the most recently presented surface owns the alert.
@MainActor @Observable
final class VaultPresentationStack {
    private var surfaces: [UUID] = []
    func register(_ id: UUID) { surfaces.removeAll { $0 == id }; surfaces.append(id) }
    func remove(_ id: UUID) { surfaces.removeAll { $0 == id } }
    func isTop(_ id: UUID) -> Bool { surfaces.last == id }
}

private struct VaultErrorPresenter: ViewModifier {
    @Environment(VaultSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .overlay {
                if scenePhase != .active && session.phase == .unlocked {
                    ZStack { AegisTheme.background.ignoresSafeArea(); AegisMark(size: 80) }
                }
            }
            #endif
            .onAppear { session.presentationStack.register(id) }
            .onDisappear { session.presentationStack.remove(id) }
            .alert(L10n.text("app.error"), isPresented: Binding(
                get: { session.error != nil && session.presentationStack.isTop(id) },
                set: { value in if !value && session.presentationStack.isTop(id) { session.error = nil } }
            )) {
                Button(L10n.text("action.done")) { session.error = nil }
            } message: { Text(session.error ?? "") }
    }
}

extension View {
    func vaultErrorPresenter() -> some View { modifier(VaultErrorPresenter()) }
}
