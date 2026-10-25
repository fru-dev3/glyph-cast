import Carbon.HIToolbox

/// A system-wide hotkey through Carbon's RegisterEventHotKey.
/// Needs no Accessibility permission, unlike a global NSEvent monitor.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var registered = false
    private let number: UInt32
    private static var count: UInt32 = 0

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        HotKey.count += 1
        number = HotKey.count

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        // Every hotkey's handler sees every press: act only on our own id.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.id == hotKey.number else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handler)

        let id = EventHotKeyID(signature: OSType(0x43415054), id: number) // "CAPT"
        registered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
