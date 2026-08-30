import AppKit
import SwiftUI

/// Click it, press a shortcut, done.
struct KeyRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo

    func makeNSView(context: Context) -> KeyRecorderView {
        let view = KeyRecorderView()
        view.onChange = { combo = $0 }
        view.combo = combo
        return view
    }

    func updateNSView(_ nsView: KeyRecorderView, context: Context) {
        nsView.combo = combo
    }
}

final class KeyRecorderView: NSView {
    var onChange: ((KeyCombo) -> Void)?

    var combo: KeyCombo? {
        didSet { needsDisplay = true }
    }

    private var recording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 24) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { // escape cancels
            recording = false
            return
        }
        let candidate = KeyCombo(keyCode: event.keyCode, modifiers: event.modifierFlags)
        guard candidate.isValid else { NSSound.beep(); return }
        combo = candidate
        recording = false
        onChange?(candidate)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.textBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        let text = recording ? "Press keys…" : (combo?.displayString ?? "Not set")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }
}
