import Carbon.HIToolbox

/// Global ⌃⌥ shortcuts via Carbon hot keys, which work without Accessibility permission.
final class HotKeys {
    static let shared = HotKeys()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func register(keyCode: Int, handler: @escaping () -> Void) {
        installHandler()
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E_43_4F_41), id: id) // "NCOA"
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(controlKey | optionKey), hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref { refs.append(ref) }
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr { HotKeys.shared.fire(hotKeyID.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
