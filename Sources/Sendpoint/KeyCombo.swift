import AppKit
import Carbon.HIToolbox

/// A global shortcut: one key plus modifiers.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    /// Raw value of NSEvent.ModifierFlags, masked to the device-independent flags.
    var modifierRawValue: UInt

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var isValid: Bool {
        // Require at least one of control/option/command so we don't eat plain typing.
        !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierRawValue = modifiers
            .intersection([.command, .option, .control, .shift, .function])
            .subtracting(.function)
            .rawValue
    }

    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += KeyCombo.name(for: keyCode)
        return s
    }

    /// The character NSMenuItem wants for this key, so the menu shows the
    /// shortcut correctly for ⌫, ↩, arrows and the rest — not just letters.
    var menuKeyEquivalent: String? {
        if let special = KeyCombo.menuEquivalents[keyCode] { return special }
        let name = KeyCombo.name(for: keyCode)
        guard name.count == 1, let scalar = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
        else { return nil }
        return name.lowercased()
    }

    private static let menuEquivalents: [UInt16: String] = [
        UInt16(kVK_Return): "\r",
        UInt16(kVK_ANSI_KeypadEnter): "\u{3}",
        UInt16(kVK_Tab): "\t",
        UInt16(kVK_Space): " ",
        UInt16(kVK_Delete): "\u{8}",
        UInt16(kVK_ForwardDelete): "\u{7F}",
        UInt16(kVK_Escape): "\u{1B}",
        UInt16(kVK_LeftArrow): "\u{F702}",
        UInt16(kVK_RightArrow): "\u{F703}",
        UInt16(kVK_UpArrow): "\u{F700}",
        UInt16(kVK_DownArrow): "\u{F701}",
        UInt16(kVK_Home): "\u{F729}",
        UInt16(kVK_End): "\u{F72B}",
        UInt16(kVK_PageUp): "\u{F72C}",
        UInt16(kVK_PageDown): "\u{F72D}",
    ]

    static func name(for keyCode: UInt16) -> String {
        if let special = specialNames[keyCode] { return special }
        return literal(for: keyCode) ?? "Key \(keyCode)"
    }

    private static let specialNames: [UInt16: String] = [
        UInt16(kVK_Return): "↩",
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "⎋",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "↖",
        UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞",
        UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_ANSI_KeypadEnter): "⌤",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    ]

    /// Ask the current keyboard layout what character this key produces.
    private static func literal(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
