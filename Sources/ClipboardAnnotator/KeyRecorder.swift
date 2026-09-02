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

/// Drawn to look like a keycap: a light face over a slightly darker rim.
/// While recording it turns accent-tinted and asks for the keys.
final class KeyRecorderView: NSView {
    var onChange: ((KeyCombo) -> Void)?

    var combo: KeyCombo? {
        didSet { needsDisplay = true }
    }

    private var recording = false {
        didSet { needsDisplay = true }
    }

    private var hovering = false {
        didSet { needsDisplay = true }
    }

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 124, height: 26) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func becomeFirstResponder() -> Bool {
        recording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { // escape cancels
            recording = false
            window?.makeFirstResponder(nil)
            return
        }
        let candidate = KeyCombo(keyCode: event.keyCode, modifiers: event.modifierFlags)
        guard candidate.isValid else { NSSound.beep(); return }
        combo = candidate
        recording = false
        window?.makeFirstResponder(nil)
        onChange?(candidate)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 6
        let rimRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let rim = NSBezierPath(roundedRect: rimRect, xRadius: radius, yRadius: radius)

        let faceRect = NSRect(
            x: rimRect.minX + 1,
            y: rimRect.minY + 2,
            width: rimRect.width - 2,
            height: rimRect.height - 3
        )
        let face = NSBezierPath(roundedRect: faceRect, xRadius: radius - 1, yRadius: radius - 1)

        if recording {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            rim.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            face.fill()
            NSColor.controlAccentColor.setStroke()
            rim.lineWidth = 1.5
            rim.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(hovering ? 0.22 : 0.16).setFill()
            rim.fill()
            NSColor.controlBackgroundColor.blended(
                withFraction: hovering ? 0.02 : 0.05,
                of: .labelColor
            )?.setFill()
            face.fill()
        }

        let text: String
        let color: NSColor
        let font: NSFont
        if recording {
            text = "Press keys…"
            color = .controlAccentColor
            font = .systemFont(ofSize: 12, weight: .medium)
        } else if let combo {
            text = combo.displayString
            color = .labelColor
            font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
        } else {
            text = "Click to set"
            color = .tertiaryLabelColor
            font = .systemFont(ofSize: 12)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: recording ? 0 : 1.2,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2,
                y: faceRect.midY - size.height / 2
            ),
            withAttributes: attrs
        )
    }
}
