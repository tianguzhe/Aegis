#if os(macOS)
    import Carbon.HIToolbox

    /// One system-wide shortcut. Carbon hot keys are the only public API that works inside
    /// the App Sandbox without Accessibility permission. The instance lives for the whole
    /// app run, so it never unregisters.
    @MainActor
    final class GlobalHotKey {
        private var hotKeyRef: EventHotKeyRef?
        private var handlerRef: EventHandlerRef?
        private let action: () -> Void

        /// Returns nil when Carbon refuses the handler or the key combination.
        init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
            self.action = action
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers application-target events on the main thread.
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            guard status == noErr else { return nil }
            let id = EventHotKeyID(signature: OSType(0x4145_4753), id: 1) // "AEGS"
            guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
                RemoveEventHandler(handlerRef)
                return nil
            }
        }
    }
#endif
