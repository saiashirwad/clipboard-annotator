import SwiftUI

/// A small keyboard-key badge, for shortcut hints.
struct Keycap: View {
    let text: String
    var size: CGFloat = 10.5

    init(_ text: String, size: CGFloat = 10.5) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, size * 0.5)
            .padding(.vertical, size * 0.22)
            .background(
                RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .foregroundStyle(.secondary)
    }
}

/// `⌘↩ Save` — a keycap followed by what it does.
struct ShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Keycap(keys)
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Soft inset surface used for quotes and fields.
struct InsetSurface: ViewModifier {
    var radius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

extension View {
    func insetSurface(radius: CGFloat = 8) -> some View {
        modifier(InsetSurface(radius: radius))
    }
}

/// Reports a view's laid-out height upward.
struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Forces overlay scrollers on every scroll view in the window, so a
/// connected mouse does not leave a permanent track in a tiny text box.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The text view's scroll view is built lazily, so look more than once.
        for delay in [0.0, 0.1, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let root = nsView.window?.contentView else { return }
                for scroll in Self.scrollViews(in: root) {
                    scroll.scrollerStyle = .overlay
                    scroll.autohidesScrollers = true
                }
            }
        }
    }

    private static func scrollViews(in root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        var queue: [NSView] = [root]
        while let next = queue.popLast() {
            if let scroll = next as? NSScrollView { found.append(scroll) }
            queue.append(contentsOf: next.subviews)
        }
        return found
    }
}

extension View {
    func overlayScrollers() -> some View {
        background(OverlayScrollers())
    }
}
