import Foundation

/// The input that owns a voice capture.
enum VoiceTriggerSource: Equatable, Sendable {
    case hotKey
    case modifierHold
}

/// Events delivered by the Carbon voice shortcut and its capture owner.
enum VoiceTriggerEvent: Equatable, Sendable {
    case hotKeyPressed(at: TimeInterval)
    case hotKeyReleased(at: TimeInterval)
    case escape
    case captureEnded(source: VoiceTriggerSource)
    /// The registered shortcut changed. An active capture must not wait for
    /// a key-up that belonged to the old registration.
    case shortcutConfigurationChanged
}

/// Commands for the capture owner. The machine never touches AppKit or audio.
enum VoiceTriggerCommand: Equatable, Sendable {
    case beginCapture(source: VoiceTriggerSource)
    case finishCapture(source: VoiceTriggerSource)
    case cancelCapture(source: VoiceTriggerSource)
    case setLatched(Bool)
}

enum VoiceTriggerState: Equatable, Sendable {
    case idle
    case comboHeld(pressedAt: TimeInterval)
    case comboLatched
    /// The capture has ended, but the physical shortcut may still be down.
    case awaitingComboRelease
}

enum VoiceTriggerTiming {
    /// A short press latches the recording; a press at or above this duration
    /// is push-to-talk and saves when the key is released.
    static let tapHoldThreshold: TimeInterval = 0.35
}

/// Pure state machine for Option+Space voice capture.
///
/// Timestamps come from a monotonic clock supplied by the caller. A release
/// earlier than its press is stale and is ignored. Once a gesture has acted,
/// duplicate presses and releases cannot finalize it a second time.
struct VoiceTriggerMachine: Equatable, Sendable {
    private(set) var state: VoiceTriggerState = .idle

    mutating func handle(_ event: VoiceTriggerEvent) -> [VoiceTriggerCommand] {
        switch event {
        case let .hotKeyPressed(at):
            return pressed(at: at)
        case let .hotKeyReleased(at):
            return released(at: at)
        case .escape:
            return escape()
        case let .captureEnded(source):
            return captureEnded(source: source)
        case .shortcutConfigurationChanged:
            return configurationChanged()
        }
    }

    private mutating func pressed(at time: TimeInterval) -> [VoiceTriggerCommand] {
        guard time.isFinite else { return [] }
        switch state {
        case .idle:
            state = .comboHeld(pressedAt: time)
            return [
                .beginCapture(source: .hotKey),
                .setLatched(false),
            ]
        case .comboLatched:
            state = .awaitingComboRelease
            return [.finishCapture(source: .hotKey)]
        case .comboHeld, .awaitingComboRelease:
            return []
        }
    }

    private mutating func released(at time: TimeInterval) -> [VoiceTriggerCommand] {
        guard time.isFinite else { return [] }
        switch state {
        case let .comboHeld(pressedAt):
            guard time >= pressedAt else { return [] }
            if time - pressedAt >= VoiceTriggerTiming.tapHoldThreshold {
                state = .idle
                return [.finishCapture(source: .hotKey)]
            }
            state = .comboLatched
            return [.setLatched(true)]
        case .awaitingComboRelease:
            state = .idle
            return []
        case .idle, .comboLatched:
            return []
        }
    }

    private mutating func escape() -> [VoiceTriggerCommand] {
        switch state {
        case .comboHeld:
            // Keep the pending physical key-up harmless.
            state = .awaitingComboRelease
            return [.cancelCapture(source: .hotKey)]
        case .comboLatched:
            state = .idle
            return [.cancelCapture(source: .hotKey)]
        case .idle, .awaitingComboRelease:
            return []
        }
    }

    private mutating func captureEnded(source: VoiceTriggerSource) -> [VoiceTriggerCommand] {
        guard source == .hotKey else { return [] }
        switch state {
        case .comboHeld:
            // Wait for the matching release so it cannot start a new capture.
            state = .awaitingComboRelease
        case .comboLatched, .awaitingComboRelease:
            state = .idle
        case .idle:
            break
        }
        return []
    }

    private mutating func configurationChanged() -> [VoiceTriggerCommand] {
        switch state {
        case .comboHeld, .comboLatched:
            state = .idle
            return [.cancelCapture(source: .hotKey)]
        case .awaitingComboRelease:
            state = .idle
            return []
        case .idle:
            return []
        }
    }
}
