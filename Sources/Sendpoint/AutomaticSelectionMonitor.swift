import AppKit

/// Remembers selections copied by apps that own terminal mouse input.
///
/// Full-screen terminal UIs can draw their own selection and copy it directly
/// to the pasteboard. In that case Accessibility has no selected text and a
/// later synthetic Command-C has nothing to copy. This monitor ties a
/// pasteboard value to the mouse drag that produced it, rather than treating
/// arbitrary clipboard text as a selection.
@MainActor
final class AutomaticSelectionMonitor {
    static let shared = AutomaticSelectionMonitor()

    private var tracker = AutomaticSelectionTracker()
    private var eventMonitor: Any?
    private var settlementTask: Task<Void, Never>?

    func start() {
        guard eventMonitor == nil, !tracker.isTornDown else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
    }

    func takeSelection(for processIdentifier: pid_t) -> String? {
        let pasteboard = NSPasteboard.general
        let now = Date()
        _ = tracker.settlePending(
            text: pasteboard.string(forType: .string),
            pasteboardChangeCount: pasteboard.changeCount,
            now: now
        )
        return tracker.takeCandidate(
            processIdentifier: processIdentifier,
            pasteboardChangeCount: pasteboard.changeCount,
            now: now
        )
    }

    func discard() {
        settlementTask?.cancel()
        settlementTask = nil
        tracker.discard()
    }

    func teardown() {
        guard !tracker.isTornDown else { return }
        settlementTask?.cancel()
        settlementTask = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        tracker.teardown()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            settlementTask?.cancel()
            settlementTask = nil
            let pasteboard = NSPasteboard.general
            tracker.mouseDown(
                processIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                pasteboardChangeCount: pasteboard.changeCount
            )
        case .leftMouseDragged:
            tracker.mouseDragged()
        case .leftMouseUp:
            guard let request = tracker.mouseUp() else { return }
            settlementTask?.cancel()
            settlementTask = Task { [weak self] in
                // Native clipboard writes are usually immediate, but some
                // terminal paths finish asynchronously after mouse-up.
                for _ in 0..<10 {
                    do {
                        try await Task.sleep(for: .milliseconds(25))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, let self else { return }
                    let pasteboard = NSPasteboard.general
                    if tracker.settle(
                        request,
                        text: pasteboard.string(forType: .string),
                        pasteboardChangeCount: pasteboard.changeCount,
                        now: Date()
                    ) {
                        settlementTask = nil
                        return
                    }
                }
                guard let self else { return }
                tracker.abandon(request)
                settlementTask = nil
            }
        default:
            break
        }
    }
}

/// Pure transition state for `AutomaticSelectionMonitor`.
struct AutomaticSelectionTracker {
    struct SettlementRequest: Equatable {
        fileprivate var token: Int
        fileprivate var processIdentifier: pid_t
        fileprivate var pasteboardChangeCountBeforeDrag: Int
    }

    private struct Drag {
        var request: SettlementRequest
        var didDrag = false
    }

    private struct Candidate {
        var text: String
        var processIdentifier: pid_t
        var pasteboardChangeCount: Int
        var capturedAt: Date
    }

    private enum State {
        case idle
        case dragging(Drag)
        case settling(SettlementRequest)
        case available(Candidate)
        case tornDown
    }

    private var state: State = .idle
    private var nextToken = 0

    var isTornDown: Bool {
        if case .tornDown = state { return true }
        return false
    }

    mutating func mouseDown(processIdentifier: pid_t, pasteboardChangeCount: Int) {
        guard !isTornDown else { return }
        guard processIdentifier > 0 else {
            state = .idle
            return
        }
        nextToken += 1
        state = .dragging(Drag(request: SettlementRequest(
            token: nextToken,
            processIdentifier: processIdentifier,
            pasteboardChangeCountBeforeDrag: pasteboardChangeCount
        )))
    }

    mutating func mouseDragged() {
        guard case var .dragging(drag) = state else { return }
        drag.didDrag = true
        state = .dragging(drag)
    }

    mutating func mouseUp() -> SettlementRequest? {
        guard case let .dragging(drag) = state else { return nil }
        guard drag.didDrag else {
            state = .idle
            return nil
        }
        state = .settling(drag.request)
        return drag.request
    }

    @discardableResult
    mutating func settle(
        _ request: SettlementRequest,
        text: String?,
        pasteboardChangeCount: Int,
        now: Date
    ) -> Bool {
        guard case let .settling(activeRequest) = state, activeRequest == request else {
            return false
        }
        guard pasteboardChangeCount != request.pasteboardChangeCountBeforeDrag else {
            return false
        }
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            state = .idle
            return false
        }
        state = .available(Candidate(
            text: text,
            processIdentifier: request.processIdentifier,
            pasteboardChangeCount: pasteboardChangeCount,
            capturedAt: now
        ))
        return true
    }

    mutating func settlePending(
        text: String?,
        pasteboardChangeCount: Int,
        now: Date
    ) -> Bool {
        guard case let .settling(request) = state else { return false }
        return settle(
            request,
            text: text,
            pasteboardChangeCount: pasteboardChangeCount,
            now: now
        )
    }

    mutating func abandon(_ request: SettlementRequest) {
        guard case let .settling(activeRequest) = state, activeRequest == request else { return }
        state = .idle
    }

    mutating func takeCandidate(
        processIdentifier: pid_t,
        pasteboardChangeCount: Int,
        now: Date,
        maximumAge: TimeInterval = 15
    ) -> String? {
        guard case let .available(candidate) = state else { return nil }
        defer { state = .idle }
        guard candidate.processIdentifier == processIdentifier,
              candidate.pasteboardChangeCount == pasteboardChangeCount
        else { return nil }
        let age = now.timeIntervalSince(candidate.capturedAt)
        guard age >= 0, age <= maximumAge else { return nil }
        return candidate.text
    }

    mutating func discard() {
        guard !isTornDown else { return }
        state = .idle
    }

    mutating func teardown() {
        state = .tornDown
    }
}
