import AegisCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
enum SecureClipboard {
    private static var task: Task<Void, Never>?
    private static var ownedChange: Int?
    static func copy(_ value: String) {
        task?.cancel()
        #if os(iOS)
        UIPasteboard.general.setItems([["public.utf8-plain-text": value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)])
        ownedChange = UIPasteboard.general.changeCount
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        ownedChange = NSPasteboard.general.changeCount
        #endif
        task = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            clear()
        }
    }
    static func clear() {
        task?.cancel()
        guard let ownedChange else { return }
        #if os(iOS)
        if UIPasteboard.general.changeCount == ownedChange { UIPasteboard.general.items = [] }
        #else
        if NSPasteboard.general.changeCount == ownedChange { NSPasteboard.general.clearContents() }
        #endif
        self.ownedChange = nil
    }
}
