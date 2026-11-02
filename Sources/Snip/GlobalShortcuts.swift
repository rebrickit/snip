import AppKit
import Carbon

@MainActor
final class GlobalShortcuts {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let action: (UInt32) -> Void

    init(action: @escaping (UInt32) -> Void) { self.action = action }

    func register() -> String? {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            // Application event handlers are dispatched on the main event loop.
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue().action(identifier.id)
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return "Global shortcuts are unavailable. Use the menu bar controls." }
        let keys = [kVK_ANSI_S, kVK_ANSI_R, kVK_ANSI_A, kVK_ANSI_X]
        var failed = false
        for (index, key) in keys.enumerated() {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x534E4950, id: UInt32(index))
            let status = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey | cmdKey), id,
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { references.append(reference) } else { failed = true }
        }
        return failed ? "A shortcut is already in use. Menu bar controls still work; quit the conflicting app and reopen Snip to retry." : nil
    }

    func unregister() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

