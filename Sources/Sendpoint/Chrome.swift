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
    var fill: Color = Color.primary.opacity(0.045)

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

extension View {
    func insetSurface(radius: CGFloat = 8, fill: Color = Color.primary.opacity(0.045)) -> some View {
        modifier(InsetSurface(radius: radius, fill: fill))
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

// MARK: - Settings chrome
//
// Shared by the settings window and the setup flow so the two read as one
// surface: the same card, the same icon tile, the same row metrics.

enum SettingsMetrics {
    /// Row padding on each side.
    static let rowInset: CGFloat = 14
    /// Icon tile size in a row.
    static let iconSize: CGFloat = 30
    /// Where a divider starts when the rows above and below carry an icon.
    static let iconDividerInset: CGFloat = rowInset + iconSize + rowInset
    static let cardRadius: CGFloat = 10
}

/// Small uppercase label above a card.
struct SettingsCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

/// A raised, bordered group of rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// A divider between two rows, indented past the icon column when the
/// rows carry icons.
struct SettingsDivider: View {
    var pastIcon = true

    var body: some View {
        Divider().padding(.leading, pastIcon ? SettingsMetrics.iconDividerInset : SettingsMetrics.rowInset)
    }
}

/// A caption followed by its card, spaced the same everywhere.
struct SettingsSection<Content: View>: View {
    let caption: String
    @ViewBuilder let content: () -> Content

    init(_ caption: String, @ViewBuilder content: @escaping () -> Content) {
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCaption(caption)
            content()
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, subtitle == nil ? 9 : 11)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// The tinted glyph tile at the leading edge of a row.
struct SettingsIcon: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: SettingsMetrics.iconSize, height: SettingsMetrics.iconSize)
            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Icon, title, one-line detail, and whatever sits at the trailing edge.
struct SettingsIconRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: SettingsMetrics.rowInset) {
            SettingsIcon(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 10)
    }
}

/// A shortcut that cannot be changed, drawn to the same size as `KeyRecorder`
/// so the two sit level in one card.
struct StaticKeycap: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(.primary)
            .frame(width: 124, height: 26)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.16))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.05)))
                        .padding(.horizontal, 1)
                        .padding(.top, 1)
                        .padding(.bottom, 2)
                }
            )
            .accessibilityLabel("Shortcut \(text)")
    }
}

/// One step of the voice how-to: a verb, what happens, and optionally the key.
struct HowToRow: View {
    let icon: String
    let lead: String
    let sentence: String
    var keycap: String? = nil

    var body: some View {
        SettingsIconRow(icon: icon, title: lead, detail: sentence) {
            if let keycap {
                Keycap(keycap)
            }
        }
    }
}

/// The macOS sidebar material, so the source list picks up window vibrancy.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
