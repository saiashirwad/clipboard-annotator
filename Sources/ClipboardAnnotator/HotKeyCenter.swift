import AppKit
import Carbon.HIToolbox

/// Registers system-wide shortcuts through Carbon, which works without
/// Accessibility permission and fires even when another app is frontmost.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    /// Replaces any shortcut previously registered under `name`.
    func register(name: String, combo: KeyCombo?, action: @escaping () -> Void) {
        unregister(name: name)
        guard let combo, combo.isValid else { return }
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C_414E), id: id) // 'CLAN'
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode), combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Diag.log("hotkey FAILED name=\(name) combo=\(combo.displayString) keyCode=\(combo.keyCode) carbonMods=\(combo.carbonModifiers) status=\(status)")
            return
        }
        Diag.log("hotkey ok name=\(name) combo=\(combo.displayString) id=\(id)")
        handlers[id] = action
        refs[id] = ref
        names[name] = id
    }

    func unregister(name: String) {
        guard let id = names.removeValue(forKey: name) else { return }
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    private var names: [String: UInt32] = [:]

    fileprivate func fire(id: UInt32) {
        Diag.log("hotkey fired id=\(id)")
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
    }
}

private func hotKeyEventHandler(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr else { return status }
    DispatchQueue.main.async { HotKeyCenter.shared.fire(id: id.id) }
    return noErr
}
