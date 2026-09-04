import AppKit
import SendpointDomain
import SwiftUI

/// State for the stack palette, owned by its window controller so the key
/// monitor and the view work on the same level, query, highlight, and edit.
@MainActor
@Observable
final class StackPaletteModel {
    enum Field: Hashable {
        case search
        case rename(UUID)
        case create
        case note(UUID)
        case overlay
    }

    /// A text field that has temporarily taken over a row.
    enum InlineEdit: Equatable {
        case renameStack(id: UUID, text: String, problem: String?)
        case createStack(text: String, problem: String?)
        case note(id: UUID, text: String)

        var noteID: UUID? {
            if case let .note(id, _) = self { return id }
            return nil
        }
    }

    /// A menu floating over the palette: the ⌘K actions or the ⌘P templates.
    enum Overlay: Equatable {
        case actions
        case templates
    }

    let store: AnnotationStore
    let settings: AppSettings
    private let onSwitch: (UUID) -> Void
    private let onSelectProfile: (UUID) -> Void
    private let onClose: () -> Void

    private(set) var level: PaletteLevel = .stacks
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            confineHighlights()
        }
    }
    private(set) var stackState = QuickSwitchState()
    private(set) var noteState = NoteHighlightState()
    private(set) var inlineEdit: InlineEdit?
    private(set) var overlay: Overlay?
    var overlayQuery = "" {
        didSet {
            guard overlayQuery != oldValue else { return }
            overlayHighlight = 0
        }
    }
    private(set) var overlayHighlight = 0
    /// Bumped whenever the view should move keyboard focus.
    private(set) var focusRequest: (field: Field, generation: Int) = (.search, 0)
    /// A short-lived confirmation shown in the footer.
    private(set) var flash: (text: String, generation: Int)?

    init(
        store: AnnotationStore,
        settings: AppSettings,
        onSwitch: @escaping (UUID) -> Void,
        onSelectProfile: @escaping (UUID) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.settings = settings
        self.onSwitch = onSwitch
        self.onSelectProfile = onSelectProfile
        self.onClose = onClose
        stackState.synchronize(with: facts)
    }

    // MARK: - Derived

    var facts: SessionUIFacts {
        SessionUIFacts(
            sessions: store.sessions,
            currentSessionID: store.currentSessionID,
            lastCleared: store.lastCleared
        )
    }

    var stackListing: QuickSwitchListing {
        QuickSwitchListing(facts: facts, query: level == .stacks ? query : "")
    }

    /// The stack whose notes are shown: the open one, or the highlighted one
    /// as a preview.
    var shownSession: Session? {
        switch level {
        case let .notes(id):
            return store.sessions.first(where: { $0.id == id })
        case .stacks:
            guard let id = stackState.selectedSessionID else { return nil }
            return store.sessions.first(where: { $0.id == id })
        }
    }

    var noteListing: NoteListing {
        NoteListing(entries: shownSession?.entries ?? [], query: level == .stacks ? "" : query)
    }

    var highlightedNoteID: UUID? {
        guard case .notes = level else { return nil }
        return noteState.highlight
    }

    var isEditingNote: Bool { inlineEdit?.noteID != nil }

    var activeProfile: Profile { settings.activeProfile }

    var actionContext: PaletteActionContext {
        let facts = facts
        let focus: PaletteActionContext.Focus
        switch level {
        case .stacks:
            switch stackState.highlight {
            case let .session(id):
                if let session = facts.session(id: id) {
                    focus = .stack(
                        id: id, name: session.name, isCurrent: session.isCurrent,
                        noteCount: session.annotationCount)
                } else {
                    focus = .nothing
                }
            case let .create(name):
                focus = .createStack(name: name)
            case nil:
                focus = .nothing
            }
        case .notes:
            let listing = noteListing
            if let id = noteState.highlight, let index = listing.ids.firstIndex(of: id) {
                focus = .note(
                    id: id, index: index, count: listing.entries.count,
                    sourceURL: listing.entries[index].provenance.url)
            } else {
                focus = .nothing
            }
        }
        let open = level.sessionID.flatMap { facts.session(id: $0) }.map {
            (id: $0.id, name: $0.name, isCurrent: $0.isCurrent, noteCount: $0.annotationCount)
        }
        return PaletteActionContext(
            level: level,
            focus: focus,
            openStack: open,
            canDeleteStack: facts.canDelete,
            undo: facts.undo,
            templateName: settings.activeProfile.name
        )
    }

    var actionItems: [PaletteActionItem] {
        PaletteActionCatalog.items(for: actionContext)
    }

    var filteredActionItems: [PaletteActionItem] {
        PaletteActionCatalog.filter(actionItems, query: overlayQuery)
    }

    var filteredProfiles: [Profile] {
        let trimmed = overlayQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let needle = SessionDocumentMutations.normalizedSessionName(trimmed) else {
            return settings.profiles
        }
        return settings.profiles.filter {
            (SessionDocumentMutations.normalizedSessionName($0.name) ?? "").contains(needle)
        }
    }

    /// The action ↩ performs, for the footer.
    var primaryAction: PaletteActionItem? {
        actionItems.first { $0.keys == "↩" }
    }

    // MARK: - Store changes

    func sessionsChanged() {
        if case let .notes(id) = level, facts.session(id: id) == nil {
            leaveNotes()
        }
        stackState.synchronize(with: facts)
        confineHighlights()
        switch inlineEdit {
        case let .renameStack(id, _, _) where facts.session(id: id) == nil:
            inlineEdit = nil
            requestFocus(.search)
        case let .note(id, _) where !noteListing.ids.contains(id):
            inlineEdit = nil
            requestFocus(.search)
        default:
            break
        }
    }

    func currentSessionChanged() {
        if level == .stacks { stackState.selectCurrent(from: facts) }
    }

    private func confineHighlights() {
        switch level {
        case .stacks:
            stackState.confine(to: stackListing.rows, preferring: facts.currentSessionID)
        case .notes:
            noteState.confine(to: noteListing.ids)
        }
    }

    // MARK: - Navigation

    func open(at level: PaletteLevel) {
        closeOverlay()
        inlineEdit = nil
        switch level {
        case .stacks:
            leaveNotes()
            stackState.selectCurrent(from: facts)
        case let .notes(id):
            guard facts.session(id: id) != nil else {
                leaveNotes()
                return
            }
            enterNotes(of: id)
        }
        requestFocus(.search)
    }

    private func enterNotes(of sessionID: UUID) {
        query = ""
        level = .notes(sessionID)
        noteState.select(nil)
        noteState.confine(to: noteListing.ids)
    }

    private func leaveNotes() {
        let previous = level.sessionID
        query = ""
        level = .stacks
        if let previous {
            _ = stackState.choose(previous, from: facts)
        } else {
            stackState.synchronize(with: facts)
        }
    }

    func openHighlightedStack() {
        guard level == .stacks, let id = stackState.selectedSessionID else {
            NSSound.beep()
            return
        }
        enterNotes(of: id)
        requestFocus(.search)
    }

    func backToStacks() {
        guard case .notes = level else { return }
        inlineEdit = nil
        leaveNotes()
        requestFocus(.search)
    }

    func moveHighlight(by offset: Int) {
        switch level {
        case .stacks: stackState.move(by: offset, in: stackListing.rows)
        case .notes: noteState.move(by: offset, in: noteListing.ids)
        }
    }

    func chooseStack(_ id: UUID) {
        guard level == .stacks, inlineEdit == nil else { return }
        _ = stackState.choose(id, from: facts)
    }

    func chooseCreateRow(_ name: String) {
        guard level == .stacks, inlineEdit == nil else { return }
        stackState.highlight(.create(name))
    }

    func chooseNote(_ id: UUID) {
        guard case .notes = level, noteListing.ids.contains(id) else { return }
        if let editing = inlineEdit?.noteID, editing != id { commitInlineEdit() }
        noteState.select(id)
    }

    func jump(to position: Int) {
        switch level {
        case .stacks:
            let sessions = stackListing.sessions
            guard sessions.indices.contains(position) else { NSSound.beep(); return }
            onSwitch(sessions[position].id)
        case .notes:
            let ids = noteListing.ids
            guard ids.indices.contains(position) else { NSSound.beep(); return }
            noteState.select(ids[position])
        }
    }

    // MARK: - Activation

    func activateHighlight() {
        switch level {
        case .stacks:
            switch stackState.highlight {
            case let .session(id): onSwitch(id)
            case let .create(name): createStack(named: name)
            case nil: NSSound.beep()
            }
        case .notes:
            guard let id = noteState.highlight else { NSSound.beep(); return }
            beginEditingNote(id)
        }
    }

    func escape() {
        if overlay != nil {
            closeOverlay()
        } else if inlineEdit != nil {
            cancelInlineEdit()
        } else if !query.isEmpty {
            query = ""
        } else if case .notes = level {
            backToStacks()
        } else {
            onClose()
        }
    }

    func close() {
        onClose()
    }

    // MARK: - Actions

    func perform(_ action: PaletteAction) {
        closeOverlay()
        switch action {
        case let .switchToStack(id):
            onSwitch(id)
        case let .openStack(id):
            guard level == .stacks else { return }
            _ = stackState.choose(id, from: facts)
            openHighlightedStack()
        case let .createStack(name):
            createStack(named: name)
        case .newStack:
            beginCreate()
        case let .renameStack(id):
            beginRename(id)
        case let .deleteStack(id):
            deleteStack(id)
        case let .clearStack(id):
            clearStack(id)
        case .undoClear:
            guard facts.undo != nil else { NSSound.beep(); return }
            store.mutate(.undoClear)
        case let .copyStack(id):
            copyStack(id)
        case .chooseTemplate:
            openOverlay(.templates)
        case let .editNote(id):
            beginEditingNote(id)
        case let .copyNote(id):
            copyNote(id)
        case let .deleteNote(id):
            deleteNote(id)
        case let .moveNoteUp(id):
            moveNote(id, by: -1)
        case let .moveNoteDown(id):
            moveNote(id, by: 1)
        case let .openSource(url):
            NSWorkspace.shared.open(url)
            onClose()
        case .backToStacks:
            backToStacks()
        }
    }

    /// Runs the action bound to `keys` if the context offers it.
    @discardableResult
    private func performAction(keyed keys: String) -> Bool {
        guard let item = actionItems.first(where: { $0.keys == keys }) else {
            NSSound.beep()
            return true
        }
        perform(item.action)
        return true
    }

    func createFromQuery() {
        guard level == .stacks, let name = stackListing.creatableName else {
            NSSound.beep()
            return
        }
        createStack(named: name)
    }

    private func createStack(named draft: String) {
        guard
            let name = SessionDialogs.validateForEnqueue(
                draft, excluding: nil, sessions: store.sessions)
        else { return }
        let session = Session(name: name)
        store.mutate(.createSession(session))
        onSwitch(session.id)
    }

    private func deleteStack(_ id: UUID) {
        guard facts.canDelete else { NSSound.beep(); return }
        guard
            SessionDialogs.confirmsDelete(
                sessionID: id, sessions: store.sessions, lastCleared: store.lastCleared)
        else { return }
        store.mutate(.deleteSession(sessionID: id))
    }

    private func clearStack(_ id: UUID) {
        guard let session = store.sessions.first(where: { $0.id == id }), !session.entries.isEmpty
        else { NSSound.beep(); return }
        store.mutate(.clearSession(sessionID: id))
    }

    private func copyStack(_ id: UUID) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        let count = session.entries.count
        guard SessionExport.copy(store: store, sessionID: id, profile: settings.activeProfile)
        else { NSSound.beep(); return }
        show(flash: "Copied \(count) note\(count == 1 ? "" : "s") from “\(session.name)”")
    }

    private func copyNote(_ id: UUID) {
        guard let entry = noteListing.entries.first(where: { $0.id == id }) else { return }
        var parts: [String] = []
        if case let .selection(quote) = entry.subject {
            let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append("> " + trimmed.replacingOccurrences(of: "\n", with: "\n> ")) }
        }
        if let note = entry.note.nonblank { parts.append(note) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(parts.joined(separator: "\n\n"), forType: .string) else {
            NSSound.beep()
            return
        }
        show(flash: "Copied note")
    }

    private func deleteNote(_ id: UUID) {
        guard let sessionID = level.sessionID, noteListing.ids.contains(id) else { return }
        let ids = noteListing.ids
        if let index = ids.firstIndex(of: id) {
            let next = ids.indices.contains(index + 1) ? ids[index + 1] : ids.dropLast().last
            noteState.select(next)
        }
        store.mutate(.removeAnnotation(sessionID: sessionID, annotationID: id))
    }

    private func moveNote(_ id: UUID, by offset: Int) {
        guard let sessionID = level.sessionID, let session = shownSession else { return }
        let ids = session.entries.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else {
            NSSound.beep()
            return
        }
        store.mutate(.moveAnnotation(
            sessionID: sessionID, annotationID: id, destinationIndex: index + offset))
    }

    func selectProfile(_ id: UUID) {
        closeOverlay()
        onSelectProfile(id)
    }

    private func show(flash text: String) {
        flash = (text, (flash?.generation ?? 0) + 1)
    }

    func clearFlash(generation: Int) {
        guard flash?.generation == generation else { return }
        flash = nil
    }

    // MARK: - Inline edits

    private func beginRename(_ id: UUID) {
        guard let session = facts.session(id: id) else { NSSound.beep(); return }
        if level == .stacks { _ = stackState.choose(id, from: facts) }
        inlineEdit = .renameStack(id: id, text: session.name, problem: nil)
        requestFocus(.rename(id))
    }

    private func beginCreate() {
        guard level == .stacks else { return }
        if let name = stackListing.creatableName {
            createStack(named: name)
            return
        }
        query = ""
        inlineEdit = .createStack(text: "", problem: nil)
        requestFocus(.create)
    }

    func beginEditingNote(_ id: UUID, requestingFocus: Bool = true) {
        guard case .notes = level, let entry = noteListing.entries.first(where: { $0.id == id })
        else { return }
        if inlineEdit?.noteID == id { return }
        if inlineEdit != nil { commitInlineEdit() }
        noteState.select(id)
        inlineEdit = .note(id: id, text: entry.note)
        if requestingFocus { requestFocus(.note(id)) }
    }

    var inlineText: String {
        switch inlineEdit {
        case let .renameStack(_, text, _), let .createStack(text, _), let .note(_, text):
            return text
        case nil:
            return ""
        }
    }

    var inlineProblem: String? {
        switch inlineEdit {
        case let .renameStack(_, _, problem), let .createStack(_, problem):
            return problem
        default:
            return nil
        }
    }

    func updateInlineText(_ text: String) {
        switch inlineEdit {
        case let .renameStack(id, _, _):
            inlineEdit = .renameStack(id: id, text: text, problem: nil)
        case .createStack:
            inlineEdit = .createStack(text: text, problem: nil)
        case let .note(id, _):
            inlineEdit = .note(id: id, text: text)
        case nil:
            break
        }
    }

    func commitInlineEdit() {
        switch inlineEdit {
        case let .renameStack(id, text, _):
            let draft = SessionNameDraft(text: text, excludedSessionID: id)
            switch draft.validation(sessions: store.sessions) {
            case let .valid(name):
                inlineEdit = nil
                requestFocus(.search)
                if name != facts.session(id: id)?.name {
                    store.mutate(.renameSession(sessionID: id, name: name))
                }
            case let .invalid(problem):
                inlineEdit = .renameStack(id: id, text: text, problem: problem)
                NSSound.beep()
            }
        case let .createStack(text, _):
            let draft = SessionNameDraft(text: text, excludedSessionID: nil)
            switch draft.validation(sessions: store.sessions) {
            case let .valid(name):
                inlineEdit = nil
                requestFocus(.search)
                let session = Session(name: name)
                store.mutate(.createSession(session))
                onSwitch(session.id)
            case let .invalid(problem):
                inlineEdit = .createStack(text: text, problem: problem)
                NSSound.beep()
            }
        case let .note(id, text):
            inlineEdit = nil
            requestFocus(.search)
            if let sessionID = level.sessionID,
               let entry = shownSession?.entries.first(where: { $0.id == id }),
               entry.note != text
            {
                store.mutate(.updateAnnotationNote(sessionID: sessionID, annotationID: id, note: text))
            }
        case nil:
            break
        }
    }

    func cancelInlineEdit() {
        guard inlineEdit != nil else { return }
        inlineEdit = nil
        requestFocus(.search)
    }

    /// The view reports focus moving into or out of a note field with the
    /// mouse; the edit follows.
    func noteFieldFocusChanged(to id: UUID?) {
        if let id {
            beginEditingNote(id, requestingFocus: false)
        } else if inlineEdit?.noteID != nil {
            commitInlineEdit()
        }
    }

    // MARK: - Overlays

    func openOverlay(_ overlay: Overlay) {
        if inlineEdit?.noteID != nil { commitInlineEdit() }
        self.overlay = overlay
        overlayQuery = ""
        overlayHighlight = overlay == .templates
            ? settings.profiles.firstIndex(where: { $0.id == settings.activeProfileID }) ?? 0
            : 0
        requestFocus(.overlay)
    }

    func toggleOverlay(_ overlay: Overlay) {
        if self.overlay == overlay { closeOverlay() } else { openOverlay(overlay) }
    }

    func closeOverlay() {
        guard overlay != nil else { return }
        overlay = nil
        overlayQuery = ""
        requestFocus(inlineEdit == nil ? .search : focusRequest.field)
    }

    func setOverlayHighlight(_ index: Int) {
        overlayHighlight = index
    }

    private var overlayCount: Int {
        switch overlay {
        case .actions: return filteredActionItems.count
        case .templates: return filteredProfiles.count
        case nil: return 0
        }
    }

    private func moveOverlayHighlight(by offset: Int) {
        let count = overlayCount
        guard count > 0 else { return }
        overlayHighlight = ((overlayHighlight + offset) % count + count) % count
    }

    func activateOverlayHighlight() {
        switch overlay {
        case .actions:
            let items = filteredActionItems
            guard items.indices.contains(overlayHighlight) else { NSSound.beep(); return }
            perform(items[overlayHighlight].action)
        case .templates:
            let profiles = filteredProfiles
            guard profiles.indices.contains(overlayHighlight) else { NSSound.beep(); return }
            selectProfile(profiles[overlayHighlight].id)
        case nil:
            break
        }
    }

    // MARK: - Keys

    /// Routes a claimed key. Returns false to let the text field have it.
    func handle(_ key: PaletteKey, textHasSelection: Bool) -> Bool {
        if overlay != nil { return handleOverlay(key) }
        if inlineEdit != nil { return handleInlineEdit(key) }

        switch key {
        case .up: moveHighlight(by: -1)
        case .down: moveHighlight(by: 1)
        case .escape: escape()
        case .command("k"): openOverlay(.actions)
        case .command("p"): openOverlay(.templates)
        case .command("z"): performAction(keyed: "⌘Z")
        case .command("r"): performAction(keyed: "⌘R")
        case .shiftCommandDelete: performAction(keyed: "⇧⌘⌫")
        case let .commandDigit(digit): jump(to: digit - 1)
        case .shiftCommand("c"):
            if level == .stacks { performAction(keyed: "⌘C") } else { performAction(keyed: "⇧⌘C") }
        case .command("c"):
            guard !textHasSelection else { return false }
            performAction(keyed: "⌘C")
        case .commandDelete:
            guard query.isEmpty else { return false }
            performAction(keyed: "⌘⌫")
        case .activate: activateHighlight()
        default:
            switch level {
            case .stacks: return handleStacks(key)
            case .notes: return handleNotes(key)
            }
        }
        return true
    }

    private func handleStacks(_ key: PaletteKey) -> Bool {
        switch key {
        case .commandActivate:
            if stackListing.creatableName != nil { createFromQuery() } else { activateHighlight() }
        case .tab:
            openHighlightedStack()
        case .right:
            guard query.isEmpty else { return false }
            openHighlightedStack()
        case .command("n"):
            perform(.newStack)
        default:
            return false
        }
        return true
    }

    private func handleNotes(_ key: PaletteKey) -> Bool {
        switch key {
        case .commandActivate:
            guard let id = level.sessionID else { return false }
            onSwitch(id)
        case .backTab:
            backToStacks()
        case .left, .delete:
            guard query.isEmpty else { return false }
            backToStacks()
        case .optionUp: performAction(keyed: "⌥↑")
        case .optionDown: performAction(keyed: "⌥↓")
        case .command("o"): performAction(keyed: "⌘O")
        default:
            return false
        }
        return true
    }

    private func handleInlineEdit(_ key: PaletteKey) -> Bool {
        switch key {
        case .activate: commitInlineEdit()
        case .escape: cancelInlineEdit()
        case .command("k"): openOverlay(.actions)
        default: return false
        }
        return true
    }

    private func handleOverlay(_ key: PaletteKey) -> Bool {
        switch key {
        case .up: moveOverlayHighlight(by: -1)
        case .down: moveOverlayHighlight(by: 1)
        case .activate, .commandActivate: activateOverlayHighlight()
        case .escape: closeOverlay()
        case .command("k"):
            if overlay == .actions { closeOverlay() } else { openOverlay(.actions) }
        case .command("p"):
            if overlay == .templates { closeOverlay() } else { openOverlay(.templates) }
        case .command, .shiftCommand, .commandDelete, .shiftCommandDelete, .optionUp, .optionDown,
            .commandDigit:
            // A shortcut pressed with the menu open runs as if it were closed.
            closeOverlay()
            return handle(key, textHasSelection: false)
        default:
            return false
        }
        return true
    }

    private func requestFocus(_ field: Field) {
        focusRequest = (field, focusRequest.generation + 1)
    }
}
