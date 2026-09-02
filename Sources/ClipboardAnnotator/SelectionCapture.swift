import AppKit
import ApplicationServices

struct CapturedSelection {
    var text: String
    var appName: String?
    var appBundleID: String?
    var processIdentifier: pid_t = 0
    var screenRect: CGRect?
}

/// Reads whatever the user has highlighted in the frontmost app.
///
/// Two strategies, in order:
///  1. Accessibility: ask the focused element for `AXSelectedText`. Silent and
///     leaves the clipboard alone, but some apps (many Electron ones, Chrome
///     with web accessibility off) do not answer.
///  2. Synthesise ⌘C, read the pasteboard, then put the old pasteboard back.
enum SelectionCapture {

    /// How far to go when Accessibility reports no selection.
    enum FallbackPolicy {
        /// Typed capture: the user has let go of the shortcut, so wait for the
        /// modifiers and give the app time to copy.
        case patient
        /// Hold-to-talk: the modifiers stay down by design, and no selection
        /// usually means a free-standing thought, so only glance at the clipboard.
        case brief

        var waitsForModifierRelease: Bool { self == .patient }
        var clipboardTimeout: TimeInterval { self == .patient ? 0.7 : 0.15 }
    }

    static func capture(fallback: FallbackPolicy = .patient) -> CapturedSelection {
        let app = NSWorkspace.shared.frontmostApplication
        var rect: CGRect?
        var text = ""

        if let (axText, axRect) = accessibilitySelection() {
            text = axText
            rect = axRect
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = copyViaKeystroke(
                processIdentifier: app?.processIdentifier ?? 0,
                fallback: fallback
            ) ?? ""
        }

        return CapturedSelection(
            text: text,
            appName: app?.localizedName,
            appBundleID: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier ?? 0,
            screenRect: rect
        )
    }

    // MARK: - Accessibility

    private static func accessibilitySelection() -> (String, CGRect?)? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement

        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef) == .success,
              let text = textRef as? String, !text.isEmpty
        else { return nil }

        return (text, selectionRect(of: element))
    }

    /// Screen rect of the highlighted range, so the panel can appear beside it.
    private static func selectionRect(of element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue, &boundsRef
        ) == .success, let boundsValue = boundsRef, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0
        else { return nil }
        return rect // top-left origin, Quartz screen coordinates
    }

    // MARK: - Clipboard fallback

    private static func copyViaKeystroke(
        processIdentifier: pid_t,
        fallback: FallbackPolicy
    ) -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let changeCountBeforeCopy = pasteboard.changeCount

        if fallback.waitsForModifierRelease { waitForModifierRelease() }
        postCommandKey(
            8,
            processIdentifier: processIdentifier > 0 ? processIdentifier : nil
        ) // kVK_ANSI_C

        var copiedChangeCount: Int?
        var result: String?
        let deadline = Date().addingTimeInterval(fallback.clipboardTimeout)
        while Date() < deadline {
            if pasteboard.changeCount != changeCountBeforeCopy {
                copiedChangeCount = pasteboard.changeCount
                result = pasteboard.string(forType: .string)
                break
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        // Do not overwrite clipboard data changed after the copy we observed.
        if let copiedChangeCount, pasteboard.changeCount == copiedChangeCount {
            restore(saved, to: pasteboard)
        }
        return result
    }

    /// Sends ⌘V to the app that was frontmost when export began.
    static func paste(into processIdentifier: pid_t) {
        guard processIdentifier > 0 else { return }
        waitForModifierRelease()
        postCommandKey(9, processIdentifier: processIdentifier)  // kVK_ANSI_V
    }

    /// A synthetic ⌘-key event inherits whatever modifiers are physically held.
    /// The hotkey that triggered us is ⌃⌘-something, so firing straight away
    /// makes the target app see ⌃⌘C or ⌃⌘V — neither of which is copy or paste.
    /// Wait for the user's fingers to come off first.
    private static func waitForModifierRelease(timeout: TimeInterval = 0.7) {
        let watched: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSEvent.modifierFlags.intersection(watched).isEmpty { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        Diag.log("waitForModifierRelease timed out, flags still \(NSEvent.modifierFlags.rawValue)")
    }

    private static func postCommandKey(_ key: CGKeyCode, processIdentifier: pid_t? = nil) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval
        )
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        if let processIdentifier {
            down?.postToPid(processIdentifier)
            up?.postToPid(processIdentifier)
        } else {
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private struct PasteboardItemSnapshot {
        var contents: [NSPasteboard.PasteboardType: Data]
    }

    private static func snapshot(_ pb: NSPasteboard) -> [PasteboardItemSnapshot] {
        (pb.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return PasteboardItemSnapshot(contents: contents)
        }
    }

    private static func restore(_ snapshots: [PasteboardItemSnapshot], to pb: NSPasteboard) {
        pb.clearContents()
        guard !snapshots.isEmpty else { return }
        let items = snapshots.map { snap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snap.contents { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }
}
