import AppKit
import SendpointDomain
import SwiftUI

/// Owns the palette panel, its key handling, and its one teardown path.
@MainActor
final class StackPaletteWindowController: NSObject, NSWindowDelegate {
    private enum Lifecycle {
        case active
        case tornDown
    }

    private static let frameAutosaveName = "StackPalette"

    private let panel: NSPanel
    private let model: StackPaletteModel
    private var keyMonitor: Any?
    private var lifecycle: Lifecycle = .active
    private let onDismiss: () -> Void

    init(
        store: AnnotationStore,
        settings: AppSettings,
        onSwitch: @escaping (UUID) -> Void,
        onSelectProfile: @escaping (UUID) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Stacks"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = StackPaletteView.minimumSize
        self.panel = panel

        // Filled in below, once `self` can be captured.
        var closeHandler: () -> Void = {}
        let model = StackPaletteModel(
            store: store,
            settings: settings,
            onSwitch: onSwitch,
            onSelectProfile: onSelectProfile,
            onClose: { closeHandler() }
        )
        self.model = model
        super.init()
        closeHandler = { [weak self] in self?.close() }

        // The palette is a sheet of frosted glass over the desktop, so the
        // window itself is clear and a popover-material view carries the tint.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        let hosting = NSHostingView(rootView: StackPaletteView(model: model))
        hosting.sizingOptions = []
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.addSubview(hosting)
        panel.contentView = glass
        panel.delegate = self
        installKeyMonitor()
    }

    func show(at level: PaletteLevel) {
        guard lifecycle == .active else { return }
        model.open(at: level)
        if !panel.isVisible {
            if !panel.setFrameUsingName(Self.frameAutosaveName) {
                placeNearTop()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// The only close path. Safe to call more than once.
    func close() {
        guard lifecycle == .active else { return }
        lifecycle = .tornDown
        panel.saveFrame(usingName: Self.frameAutosaveName)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.delegate = nil
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        onDismiss()
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }

    func windowDidResignKey(_ notification: Notification) {
        // A palette that lost focus is a palette the user is done with, unless
        // an alert of ours (delete confirmation) took the key.
        guard lifecycle == .active, NSApp.modalWindow == nil else { return }
        close()
    }

    // MARK: - Keys

    /// Every key the palette cares about is handled here, ahead of the text
    /// fields, so ↑↓ move the highlight instead of the insertion point. Any
    /// key the model declines falls through to the field.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.lifecycle == .active, event.window === self.panel,
                  let key = PaletteKey(event: event)
            else { return event }
            let selection = (self.panel.firstResponder as? NSTextView)?.selectedRange().length ?? 0
            let handled = self.model.handle(key, textHasSelection: selection > 0)
            return handled ? nil : event
        }
    }

    // MARK: - Placement

    private func placeNearTop() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - visible.height * 0.18 - size.height
            ))
    }
}

extension PaletteKey {
    private static let commandLetters: Set<Character> = ["c", "k", "n", "o", "p", "r", "z"]

    /// Decodes an event by character rather than hardware key code where a
    /// letter is involved, so ⌘R survives non-US keyboard layouts.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let plain = modifiers.isEmpty
        let command = modifiers == .command
        let shiftCommand = modifiers == [.command, .shift]
        let option = modifiers == .option
        let shift = modifiers == .shift
        switch event.keyCode {
        case 126 where plain: self = .up
        case 125 where plain: self = .down
        case 123 where plain: self = .left
        case 124 where plain: self = .right
        case 126 where option: self = .optionUp
        case 125 where option: self = .optionDown
        case 48 where plain: self = .tab
        case 48 where shift: self = .backTab
        case 36 where plain, 76 where plain: self = .activate
        case 36 where command, 76 where command: self = .commandActivate
        case 53 where plain: self = .escape
        case 51 where plain: self = .delete
        case 51 where command: self = .commandDelete
        case 51 where shiftCommand: self = .shiftCommandDelete
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased().first else {
                return nil
            }
            if command, let digit = character.wholeNumberValue, (1...9).contains(digit) {
                self = .commandDigit(digit)
            } else if command, Self.commandLetters.contains(character) {
                self = .command(character)
            } else if shiftCommand, character == "c" {
                self = .shiftCommand(character)
            } else {
                return nil
            }
        }
    }
}
