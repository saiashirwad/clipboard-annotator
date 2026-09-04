import ApplicationServices
import Foundation

enum VoiceModifierShortcut {
    static let displayString = "⌥⌘"

    private static let requiredFlags: CGEventFlags = [.maskAlternate, .maskCommand]
    private static let relevantFlags: CGEventFlags = [
        .maskAlternate, .maskCommand, .maskControl, .maskShift, .maskSecondaryFn,
    ]

    static func isPressed(flags: CGEventFlags) -> Bool {
        flags.intersection(relevantFlags) == requiredFlags
    }

    /// A key-based shortcut with these modifiers would start voice capture
    /// before its key was pressed, so keep that prefix for voice alone.
    static func conflicts(with combo: KeyCombo) -> Bool {
        combo.modifiers.intersection([.option, .command, .control, .shift]) == [.option, .command]
    }
}

enum VoiceModifierShortcutEdge: Equatable {
    case pressed
    case released
}

struct VoiceModifierShortcutState {
    private(set) var isPressed = false

    mutating func update(isPressed nextValue: Bool) -> VoiceModifierShortcutEdge? {
        guard nextValue != isPressed else { return nil }
        isPressed = nextValue
        return nextValue ? .pressed : .released
    }

    @discardableResult
    mutating func reset() -> Bool {
        let wasPressed = isPressed
        isPressed = false
        return wasPressed
    }
}

/// Watches the fixed modifier-only voice shortcut system-wide. Carbon hotkeys
/// need a non-modifier key, so this uses the same passive event-tap approach as
/// Hex. The tap observes flags; it does not block or change keyboard input.
@MainActor
final class VoiceModifierShortcutMonitor {
    private enum Lifecycle {
        case stopped
        case running
        case tornDown
    }

    var onPressed: ((TimeInterval) -> Void)?
    var onReleased: ((TimeInterval) -> Void)?
    var onInterrupted: (() -> Void)?

    private var lifecycle: Lifecycle = .stopped
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var state = VoiceModifierShortcutState()

    @discardableResult
    func start() -> Bool {
        guard lifecycle != .tornDown else { return false }
        if lifecycle == .running { return true }
        guard CGPreflightListenEventAccess() else { return false }

        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: voiceModifierShortcutCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        state.reset()
        lifecycle = .running
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        stop(notifyInterruption: true)
    }

    func teardown() {
        guard lifecycle != .tornDown else { return }
        stop(notifyInterruption: false)
        lifecycle = .tornDown
        onPressed = nil
        onReleased = nil
        onInterrupted = nil
    }

    fileprivate func receive(flags: CGEventFlags, timestamp: TimeInterval) {
        guard lifecycle == .running,
              let edge = state.update(isPressed: VoiceModifierShortcut.isPressed(flags: flags))
        else { return }

        switch edge {
        case .pressed:
            onPressed?(timestamp)
        case .released:
            onReleased?(timestamp)
        }
    }

    fileprivate func recoverFromDisabledTap() {
        guard lifecycle == .running, let eventTap else { return }
        if state.reset() {
            onInterrupted?()
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stop(notifyInterruption: Bool) {
        guard lifecycle == .running else { return }
        if state.reset(), notifyInterruption {
            onInterrupted?()
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        lifecycle = .stopped
    }
}

private func voiceModifierShortcutCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<VoiceModifierShortcutMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()

    MainActor.assumeIsolated {
        switch type {
        case .flagsChanged:
            monitor.receive(
                flags: event.flags,
                timestamp: TimeInterval(event.timestamp) / 1_000_000_000
            )
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            monitor.recoverFromDisabledTap()
        default:
            break
        }
    }
    return Unmanaged.passUnretained(event)
}
