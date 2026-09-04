import AppKit
import SendpointDomain
import SwiftUI

/// State for the session palette, owned by its window controller so the key
/// monitor and the view work on the same highlight, query, and rename draft.
@MainActor
@Observable
final class QuickSwitchModel {
    struct InlineRename: Equatable {
        let sessionID: UUID
        var text: String
        var problem: String?
    }

    enum Field: Hashable {
        case search
        case rename(UUID)
    }

    let store: AnnotationStore
    private let onSwitch: (UUID) -> Void
    private let onClose: () -> Void

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            state.confine(to: listing.rows, preferring: facts.currentSessionID)
        }
    }
    private(set) var state = QuickSwitchState()
    var rename: InlineRename?
    /// Bumped whenever the view should move keyboard focus.
    private(set) var focusRequest: (field: Field, generation: Int) = (.search, 0)

    init(store: AnnotationStore, onSwitch: @escaping (UUID) -> Void, onClose: @escaping () -> Void)
    {
        self.store = store
        self.onSwitch = onSwitch
        self.onClose = onClose
        state.synchronize(with: facts)
    }

    var facts: SessionUIFacts {
        SessionUIFacts(
            sessions: store.sessions,
            currentSessionID: store.currentSessionID,
            lastCleared: store.lastCleared
        )
    }

    var listing: QuickSwitchListing {
        QuickSwitchListing(facts: facts, query: query)
    }

    var highlight: QuickSwitchRow? { state.highlight }
    var selectedSessionID: UUID? { state.selectedSessionID }
    var highlightsCreateRow: Bool { state.highlightsCreateRow }
    var canRenameHighlight: Bool { state.selectedSessionID != nil && rename == nil }
    /// ⌘⌫ deletes a stack only while the search field is empty; with text in
    /// it, ⌘⌫ keeps its text-editing meaning (delete to start of line).
    var canDeleteHighlight: Bool {
        facts.canDelete && state.selectedSessionID != nil && rename == nil && query.isEmpty
    }

    // MARK: - Store changes

    func sessionsChanged() {
        state.synchronize(with: facts)
        state.confine(to: listing.rows, preferring: facts.currentSessionID)
        if let rename, facts.session(id: rename.sessionID) == nil {
            self.rename = nil
            requestFocus(.search)
        }
    }

    func currentSessionChanged() {
        state.selectCurrent(from: facts)
    }

    // MARK: - Keyboard

    func moveHighlight(by offset: Int) {
        guard rename == nil else { return }
        state.move(by: offset, in: listing.rows)
    }

    func choose(_ sessionID: UUID) {
        _ = state.choose(sessionID, from: facts)
    }

    func activateHighlight() {
        if rename != nil {
            commitRename()
            return
        }
        switch state.highlight {
        case .session(let id):
            onSwitch(id)
        case .create(let name):
            createSession(named: name)
        case nil:
            NSSound.beep()
        }
    }

    func escape() {
        if rename != nil {
            rename = nil
            requestFocus(.search)
        } else if !query.isEmpty {
            query = ""
        } else {
            onClose()
        }
    }

    func createFromQuery() {
        guard let name = listing.creatableName else {
            NSSound.beep()
            return
        }
        createSession(named: name)
    }

    // MARK: - Mutations

    func createSession(named draft: String) {
        guard
            let name = SessionDialogs.validateForEnqueue(
                draft,
                excluding: nil,
                sessions: store.sessions
            )
        else { return }
        let session = Session(name: name)
        store.mutate(.createSession(session))
        onSwitch(session.id)
    }

    func beginRename() {
        guard canRenameHighlight, let session = state.selectedSession(in: facts) else {
            NSSound.beep()
            return
        }
        rename = InlineRename(sessionID: session.id, text: session.name)
        requestFocus(.rename(session.id))
    }

    func updateRenameText(_ text: String) {
        rename?.text = text
        rename?.problem = nil
    }

    func commitRename() {
        guard let rename else { return }
        let draft = SessionNameDraft(text: rename.text, excludedSessionID: rename.sessionID)
        switch draft.validation(sessions: store.sessions) {
        case .valid(let name):
            self.rename = nil
            requestFocus(.search)
            if name != facts.session(id: rename.sessionID)?.name {
                store.mutate(.renameSession(sessionID: rename.sessionID, name: name))
            }
        case .invalid(let problem):
            self.rename?.problem = problem
            NSSound.beep()
        }
    }

    func deleteHighlightedSession() {
        guard canDeleteHighlight, let sessionID = state.selectedSessionID else {
            NSSound.beep()
            return
        }
        guard
            SessionDialogs.confirmsDelete(
                sessionID: sessionID,
                sessions: store.sessions,
                lastCleared: store.lastCleared
            )
        else { return }
        store.mutate(.deleteSession(sessionID: sessionID))
    }

    func switchToHighlightedSession() {
        guard let id = state.selectedSessionID else { return }
        onSwitch(id)
    }

    func close() {
        onClose()
    }

    private func requestFocus(_ field: Field) {
        focusRequest = (field, focusRequest.generation + 1)
    }
}

/// A command-palette style session switcher: type to filter, ↑↓ to move,
/// ↩ to switch. Typing a new name offers to create it in place.
struct QuickSwitchView: View {
    @Bindable var model: QuickSwitchModel
    @FocusState private var focus: QuickSwitchModel.Field?

    private let width: CGFloat = 460
    private let rowHeight: CGFloat = 40
    private let maxVisibleRows = 7

    var body: some View {
        let listing = model.listing
        VStack(spacing: 0) {
            searchField
            Divider()
            rowList(listing)
            if let error = model.store.error {
                Divider()
                errorRow(error)
            }
            Divider()
            footer
        }
        .frame(width: width)
        .background(.regularMaterial)
        .ignoresSafeArea()
        .onAppear {
            DispatchQueue.main.async { focus = .search }
        }
        .onChange(of: model.focusRequest.generation) {
            // The rename field is created by the same update; focus it once
            // it exists.
            let field = model.focusRequest.field
            DispatchQueue.main.async { focus = field }
        }
        .onChange(of: model.store.sessions) {
            model.sessionsChanged()
        }
        .onChange(of: model.store.currentSessionID) {
            model.currentSessionChanged()
        }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Switch to or create a stack", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focus, equals: .search)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    @ViewBuilder
    private func rowList(_ listing: QuickSwitchListing) -> some View {
        let rows = listing.rows
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(listing.sessions) { session in
                        sessionRow(session)
                            .id(QuickSwitchRow.session(session.id))
                    }
                    if let name = listing.creatableName {
                        createRow(name)
                            .id(QuickSwitchRow.create(name))
                    }
                    if rows.isEmpty {
                        Text(
                            "No stacks match “\(model.query.trimmingCharacters(in: .whitespaces))”."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: rowHeight)
                    }
                }
                .padding(6)
            }
            .frame(height: listHeight(capacity: listCapacity))
            .onChange(of: model.highlight) {
                guard let highlight = model.highlight else { return }
                proxy.scrollTo(highlight, anchor: nil)
            }
        }
    }

    /// Rows the list must be able to show without scrolling: every stack plus
    /// the create row. Filtering can only show fewer, so the height stays put
    /// while typing and changes only when a stack is created or deleted.
    private var listCapacity: Int {
        min(model.facts.sessions.count + 1, maxVisibleRows)
    }

    private func listHeight(capacity: Int) -> CGFloat {
        CGFloat(capacity) * (rowHeight + 2) + 10
    }

    private func sessionRow(_ session: SessionItemFacts) -> some View {
        let isHighlighted = model.highlight == .session(session.id)
        let isRenaming = model.rename?.sessionID == session.id
        return PaletteRow(
            isHighlighted: isHighlighted,
            action: {
                if isRenaming { return }
                model.choose(session.id)
                model.switchToHighlightedSession()
            }
        ) {
            HStack(spacing: 10) {
                Image(systemName: session.isCurrent ? "circle.inset.filled" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        isHighlighted
                            ? AnyShapeStyle(Color.white.opacity(session.isCurrent ? 1 : 0.6))
                            : session.isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                    )
                    .frame(width: 14)
                    .accessibilityHidden(true)

                if isRenaming {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(
                            "Stack name",
                            text: Binding(
                                get: { model.rename?.text ?? "" },
                                set: { model.updateRenameText($0) }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .focused($focus, equals: .rename(session.id))
                        if let problem = model.rename?.problem {
                            Text(problem)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Text(session.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if session.isCurrent, !isRenaming {
                    Text("Current")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.4)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                isHighlighted
                                    ? Color.white.opacity(0.22)
                                    : Color.accentColor.opacity(0.14))
                        )
                        .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                }

                Text("\(session.annotationCount)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                    .accessibilityLabel(session.countLabel)
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .frame(height: rowHeight)
    }

    private func createRow(_ name: String) -> some View {
        let isHighlighted = model.highlight == .create(name)
        return PaletteRow(
            isHighlighted: isHighlighted, action: { model.createSession(named: name) }
        ) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 14)
                    .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                (Text("Create ") + Text("“\(name)”").fontWeight(.semibold))
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Keycap("⌘↩")
                    .opacity(isHighlighted ? 0 : 1)
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .frame(height: rowHeight)
    }

    private func errorRow(_ error: AnnotationStoreError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(annotationStoreErrorMessage(error))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if model.store.hasPendingMutations {
                Button("Retry") { model.store.retryPendingMutations() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            ShortcutHint(keys: "↑↓", label: "Move")
            ShortcutHint(keys: "↩", label: model.highlightsCreateRow ? "Create" : "Switch")
            if model.canRenameHighlight {
                ShortcutHint(keys: "⌘R", label: "Rename")
            }
            if model.canDeleteHighlight {
                ShortcutHint(keys: "⌘⌫", label: "Delete")
            }
            Spacer()
            ShortcutHint(keys: "esc", label: "Close")
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }
}

/// A palette row: flat by default, accent-filled when highlighted.
private struct PaletteRow<Content: View>: View {
    let isHighlighted: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isHighlighted
                        ? Color.accentColor
                        : Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .onHover { hovering = $0 }
    }
}

/// Owns the palette panel, its key handling, its one teardown path, and the
/// resize that keeps the top edge still when the row list changes capacity.
@MainActor
final class QuickSwitchWindowController: NSObject, NSWindowDelegate {
    private enum Lifecycle {
        case active
        case tornDown
    }

    private let panel: NSPanel
    private let model: QuickSwitchModel
    private var keyMonitor: Any?
    private var lifecycle: Lifecycle = .active
    private let onDismiss: () -> Void

    init(
        store: AnnotationStore,
        onSwitch: @escaping (UUID) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Switch Stack"
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
        self.panel = panel

        // Filled in below, once `self` can be captured.
        var closeHandler: () -> Void = {}
        let model = QuickSwitchModel(
            store: store,
            onSwitch: onSwitch,
            onClose: { closeHandler() }
        )
        self.model = model
        super.init()
        closeHandler = { [weak self] in self?.close() }

        let hosting = NSHostingView(
            rootView: QuickSwitchView(model: model).background(
                GeometryReader { proxy in
                    Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
                }
            ).onPreferenceChange(HeightKey.self) { [weak self] height in
                self?.fit(height: height)
            })
        // fittingSize is zero unless the hosting view reports an intrinsic
        // size, so measure with it on, then clear it: from here on only
        // fit(height:) resizes the panel, and the hosting view must not pin
        // the window to a size measured before the list settled.
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        hosting.sizingOptions = []
        panel.delegate = self
        installKeyMonitor()
    }

    func show() {
        guard lifecycle == .active else { return }
        if !panel.isVisible {
            placeNearTop()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// The only close path. Safe to call more than once.
    func close() {
        guard lifecycle == .active else { return }
        lifecycle = .tornDown
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
    /// field, so ↑↓ move the highlight instead of the insertion point. Any
    /// key not claimed falls through to the field, and ⌘⌫ is only claimed
    /// while deleting a stack is actually possible, so it otherwise keeps its
    /// delete-to-start-of-line meaning.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.lifecycle == .active, event.window === self.panel else {
                return event
            }
            let handled = self.handle(PaletteKey(event: event))
            return handled ? nil : event
        }
    }

    private func handle(_ key: PaletteKey?) -> Bool {
        switch key {
        case .up:
            model.moveHighlight(by: -1)
        case .down:
            model.moveHighlight(by: 1)
        case .activate:
            model.activateHighlight()
        case .create:
            model.createFromQuery()
        case .escape:
            model.escape()
        case .rename:
            model.beginRename()
        case .delete:
            guard model.canDeleteHighlight else { return false }
            model.deleteHighlightedSession()
        case nil:
            return false
        }
        return true
    }

    // MARK: - Placement

    private func placeNearTop() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - visible.height * 0.28 - size.height
            ))
    }

    private func fit(height: CGFloat) {
        guard lifecycle == .active, height > 0 else { return }
        // The content view fills the whole frame, title-bar strip included.
        let frame = panel.frame
        guard abs(height - frame.height) > 0.5 else { return }
        let target = NSRect(
            x: frame.minX,
            y: frame.maxY - height,
            width: frame.width,
            height: height
        )
        // Snap rather than animate: SwiftUI has already laid the content out
        // at the new height, so an animated frame only shows a mismatch.
        panel.setFrame(target, display: true)
    }
}

/// The keys the palette claims, decoded from an event by character rather
/// than hardware key code so ⌘R survives non-US keyboard layouts.
private enum PaletteKey {
    case up, down, activate, create, escape, rename, delete

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let plain = modifiers.isEmpty
        let command = modifiers == .command
        switch event.keyCode {
        case 126 where plain: self = .up
        case 125 where plain: self = .down
        case 36 where plain, 76 where plain: self = .activate
        case 36 where command, 76 where command: self = .create
        case 53 where plain: self = .escape
        case 51 where command: self = .delete
        default:
            guard command, event.charactersIgnoringModifiers?.lowercased() == "r" else {
                return nil
            }
            self = .rename
        }
    }
}
