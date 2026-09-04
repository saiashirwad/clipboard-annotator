import ApplicationServices
import Foundation

enum VoiceModifierShortcut {
    static let displayString = "⌥⌘"
    static let armingDelay: Duration = .milliseconds(150)

    private static let requiredFlags: CGEventFlags = [.maskAlternate, .maskCommand]
    private static let relevantFlags: CGEventFlags = [
        .maskAlternate, .maskCommand, .maskControl, .maskShift, .maskSecondaryFn,
    ]

    static func isPressed(flags: CGEventFlags) -> Bool {
        flags.intersection(relevantFlags) == requiredFlags
    }

    static func hasDisqualifyingModifier(flags: CGEventFlags) -> Bool {
        !flags.intersection(relevantFlags).subtracting(requiredFlags).isEmpty
    }

    static func hasNoModifiers(flags: CGEventFlags) -> Bool {
        flags.intersection(relevantFlags).isEmpty
    }

    /// A key-based shortcut with these modifiers would start voice capture
    /// before its key was pressed, so keep that prefix for voice alone.
    static func conflicts(with combo: KeyCombo) -> Bool {
        combo.modifiers.intersection([.option, .command, .control, .shift]) == [.option, .command]
    }
}

enum VoiceModifierShortcutAction: Equatable {
    case startArming
    case cancelArming
    case pressed(at: TimeInterval)
    case released(at: TimeInterval)
    case tapped(pressedAt: TimeInterval, releasedAt: TimeInterval)
    case interrupted
}

struct VoiceModifierShortcutState {
    private enum Phase: Equatable {
        case idle
        case arming(pressedAt: TimeInterval)
        case active
        case suppressed
    }

    private var phase: Phase = .idle

    mutating func flagsChanged(
        flags: CGEventFlags,
        timestamp: TimeInterval
    ) -> VoiceModifierShortcutAction? {
        let isPressed = VoiceModifierShortcut.isPressed(flags: flags)
        let isClear = VoiceModifierShortcut.hasNoModifiers(flags: flags)

        switch phase {
        case .idle:
            guard isPressed else {
                if VoiceModifierShortcut.hasDisqualifyingModifier(flags: flags) {
                    phase = .suppressed
                }
                return nil
            }
            phase = .arming(pressedAt: timestamp)
            return .startArming

        case let .arming(pressedAt):
            guard !isPressed else { return nil }
            if VoiceModifierShortcut.hasDisqualifyingModifier(flags: flags) {
                phase = .suppressed
                return .cancelArming
            }
            phase = isClear ? .idle : .suppressed
            return .tapped(pressedAt: pressedAt, releasedAt: timestamp)

        case .active:
            guard !isPressed else { return nil }
            phase = isClear ? .idle : .suppressed
            if VoiceModifierShortcut.hasDisqualifyingModifier(flags: flags) {
                return .interrupted
            }
            return .released(at: timestamp)

        case .suppressed:
            if isClear {
                phase = .idle
            }
            return nil
        }
    }

    mutating func keyDown() -> VoiceModifierShortcutAction? {
        switch phase {
        case .arming:
            phase = .suppressed
            return .cancelArming
        case .active:
            phase = .suppressed
            return .interrupted
        case .idle, .suppressed:
            return nil
        }
    }

    mutating func armingDelayElapsed() -> VoiceModifierShortcutAction? {
        guard case let .arming(pressedAt) = phase else { return nil }
        phase = .active
        return .pressed(at: pressedAt)
    }

    @discardableResult
    mutating func reset() -> Bool {
        let wasActive = phase == .active
        phase = .idle
        return wasActive
    }
}

/// Watches the fixed modifier-only voice shortcut system-wide. Carbon hotkeys
/// need a non-modifier key, so this uses the same passive event-tap approach as
/// Hex. The tap observes flags and key-down events; it does not block or change
/// keyboard input. A short arming delay rejects Hyper-key transitions and
/// ordinary Option-Command shortcuts before voice capture starts.
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
    private var armingTask: Task<Void, Never>?

    @discardableResult
    func start() -> Bool {
        guard lifecycle != .tornDown else { return false }
        if lifecycle == .running { return true }
        guard CGPreflightListenEventAccess() else { return false }

        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
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
        guard lifecycle == .running else { return }
        perform(state.flagsChanged(flags: flags, timestamp: timestamp))
    }

    fileprivate func receiveKeyDown() {
        guard lifecycle == .running else { return }
        perform(state.keyDown())
    }

    private func perform(_ action: VoiceModifierShortcutAction?) {
        guard let action else { return }
        switch action {
        case .startArming:
            armingTask?.cancel()
            armingTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: VoiceModifierShortcut.armingDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.armingTask = nil
                self.perform(self.state.armingDelayElapsed())
            }
        case .cancelArming:
            cancelArming()
        case let .pressed(timestamp):
            onPressed?(timestamp)
        case let .released(timestamp):
            onReleased?(timestamp)
        case let .tapped(pressedAt, releasedAt):
            cancelArming()
            onPressed?(pressedAt)
            onReleased?(releasedAt)
        case .interrupted:
            cancelArming()
            onInterrupted?()
        }
    }

    fileprivate func recoverFromDisabledTap() {
        guard lifecycle == .running, let eventTap else { return }
        cancelArming()
        if state.reset() {
            onInterrupted?()
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stop(notifyInterruption: Bool) {
        guard lifecycle == .running else { return }
        cancelArming()
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

    private func cancelArming() {
        armingTask?.cancel()
        armingTask = nil
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
        case .keyDown:
            monitor.receiveKeyDown()
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            monitor.recoverFromDisabledTap()
        default:
            break
        }
    }
    return Unmanaged.passUnretained(event)
}
