import Foundation
import SendpointDomain

/// Where the palette is: the list of every stack, or inside one of them.
enum PaletteLevel: Equatable, Hashable {
    case stacks
    case notes(UUID)

    var sessionID: UUID? {
        if case let .notes(id) = self { return id }
        return nil
    }
}

/// The notes of one stack that match a query. Matching is case- and
/// diacritic-insensitive over the quote, the note, the app, and the window.
struct NoteListing: Equatable {
    let entries: [Annotation]

    init(entries: [Annotation], query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let needle = SessionDocumentMutations.normalizedSessionName(trimmed) else {
            self.entries = entries
            return
        }
        self.entries = entries.filter { NoteListing.searchText($0).contains(needle) }
    }

    var ids: [UUID] { entries.map(\.id) }
    var isEmpty: Bool { entries.isEmpty }

    static func searchText(_ entry: Annotation) -> String {
        var parts = [entry.note, entry.provenance.application.name]
        if case let .selection(quote) = entry.subject { parts.append(quote) }
        if let window = entry.provenance.windowTitle { parts.append(window) }
        return SessionDocumentMutations.normalizedSessionName(parts.joined(separator: "\n")) ?? ""
    }
}

/// Which note carries the keyboard highlight inside a stack.
struct NoteHighlightState: Equatable {
    private(set) var highlight: UUID?

    mutating func select(_ id: UUID?) {
        highlight = id
    }

    /// Moves the highlight through the listed notes, wrapping at both ends.
    mutating func move(by offset: Int, in ids: [UUID]) {
        guard !ids.isEmpty else { return }
        guard let highlight, let index = ids.firstIndex(of: highlight) else {
            self.highlight = offset < 0 ? ids[ids.count - 1] : ids[0]
            return
        }
        let count = ids.count
        self.highlight = ids[((index + offset) % count + count) % count]
    }

    /// Ensures the highlight names a listed note after the listing changes.
    mutating func confine(to ids: [UUID]) {
        if let highlight, ids.contains(highlight) { return }
        highlight = ids.first
    }
}

/// Everything the palette can do from the keyboard or the ⌘K menu.
enum PaletteAction: Hashable {
    case switchToStack(UUID)
    case openStack(UUID)
    case createStack(String)
    case newStack
    case renameStack(UUID)
    case deleteStack(UUID)
    case clearStack(UUID)
    case undoClear
    case copyStack(UUID)
    case chooseTemplate
    case editNote(UUID)
    case copyNote(UUID)
    case deleteNote(UUID)
    case moveNoteUp(UUID)
    case moveNoteDown(UUID)
    case openSource(URL)
    case backToStacks
}

/// One entry of the ⌘K menu: the action, how it reads, and its keys.
struct PaletteActionItem: Equatable, Identifiable {
    let action: PaletteAction
    let title: String
    let keys: String
    var subtitle: String? = nil
    var isDestructive = false

    var id: PaletteAction { action }
}

/// What the palette is looking at, reduced to what decides the action list.
struct PaletteActionContext: Equatable {
    enum Focus: Equatable {
        case stack(id: UUID, name: String, isCurrent: Bool, noteCount: Int)
        case createStack(name: String)
        case note(id: UUID, index: Int, count: Int, sourceURL: URL?)
        case nothing
    }

    var level: PaletteLevel
    var focus: Focus
    /// The stack the notes level is inside, when it is.
    var openStack: (id: UUID, name: String, isCurrent: Bool, noteCount: Int)?
    var canDeleteStack: Bool
    var undo: SessionUndoFacts?
    var templateName: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.level == rhs.level && lhs.focus == rhs.focus
            && lhs.openStack?.id == rhs.openStack?.id
            && lhs.openStack?.name == rhs.openStack?.name
            && lhs.openStack?.isCurrent == rhs.openStack?.isCurrent
            && lhs.openStack?.noteCount == rhs.openStack?.noteCount
            && lhs.canDeleteStack == rhs.canDeleteStack && lhs.undo == rhs.undo
            && lhs.templateName == rhs.templateName
    }
}

/// The ⌘K menu, derived from context so the footer, the menu, and the key
/// handler all agree on what is possible right now.
enum PaletteActionCatalog {
    static func items(for context: PaletteActionContext) -> [PaletteActionItem] {
        var items: [PaletteActionItem] = []
        let template = PaletteActionItem(
            action: .chooseTemplate,
            title: "Template: \(context.templateName)",
            keys: "⌘P"
        )

        switch context.level {
        case .stacks:
            switch context.focus {
            case let .stack(id, name, isCurrent, noteCount):
                items.append(PaletteActionItem(
                    action: .switchToStack(id),
                    title: isCurrent ? "Keep “\(name)” current" : "Switch to “\(name)”",
                    keys: "↩"
                ))
                items.append(PaletteActionItem(
                    action: .openStack(id), title: "Open “\(name)”", keys: "→"
                ))
                if noteCount > 0 {
                    items.append(PaletteActionItem(
                        action: .copyStack(id),
                        title: "Copy “\(name)” as Markdown",
                        keys: "⌘C",
                        subtitle: "Shaped by the \(context.templateName) template"
                    ))
                }
                items.append(PaletteActionItem(
                    action: .renameStack(id), title: "Rename “\(name)”", keys: "⌘R"
                ))
                items.append(PaletteActionItem(action: .newStack, title: "New Stack", keys: "⌘N"))
                items.append(template)
                if let undo = context.undo {
                    items.append(PaletteActionItem(action: .undoClear, title: undo.title, keys: "⌘Z"))
                }
                if noteCount > 0 {
                    items.append(PaletteActionItem(
                        action: .clearStack(id),
                        title: "Clear “\(name)”",
                        keys: "⇧⌘⌫",
                        subtitle: "Sets the notes aside; undo with ⌘Z",
                        isDestructive: true
                    ))
                }
                if context.canDeleteStack {
                    items.append(PaletteActionItem(
                        action: .deleteStack(id),
                        title: "Delete “\(name)”",
                        keys: "⌘⌫",
                        isDestructive: true
                    ))
                }
            case let .createStack(name):
                items.append(PaletteActionItem(
                    action: .createStack(name), title: "Create “\(name)”", keys: "↩"
                ))
                items.append(template)
            case .note, .nothing:
                items.append(PaletteActionItem(action: .newStack, title: "New Stack", keys: "⌘N"))
                items.append(template)
                if let undo = context.undo {
                    items.append(PaletteActionItem(action: .undoClear, title: undo.title, keys: "⌘Z"))
                }
            }

        case .notes:
            if case let .note(id, index, count, sourceURL) = context.focus {
                items.append(PaletteActionItem(action: .editNote(id), title: "Edit Note", keys: "↩"))
                items.append(PaletteActionItem(action: .copyNote(id), title: "Copy Note", keys: "⌘C"))
                if let sourceURL {
                    items.append(PaletteActionItem(
                        action: .openSource(sourceURL),
                        title: "Open Source",
                        keys: "⌘O",
                        subtitle: sourceURL.host ?? sourceURL.absoluteString
                    ))
                }
                if index > 0 {
                    items.append(PaletteActionItem(action: .moveNoteUp(id), title: "Move Note Up", keys: "⌥↑"))
                }
                if index < count - 1 {
                    items.append(PaletteActionItem(action: .moveNoteDown(id), title: "Move Note Down", keys: "⌥↓"))
                }
                items.append(PaletteActionItem(
                    action: .deleteNote(id), title: "Delete Note", keys: "⌘⌫", isDestructive: true
                ))
            }
            if let stack = context.openStack {
                if !stack.isCurrent {
                    items.append(PaletteActionItem(
                        action: .switchToStack(stack.id), title: "Switch to “\(stack.name)”", keys: "⌘↩"
                    ))
                }
                if stack.noteCount > 0 {
                    items.append(PaletteActionItem(
                        action: .copyStack(stack.id),
                        title: "Copy “\(stack.name)” as Markdown",
                        keys: "⇧⌘C",
                        subtitle: "Shaped by the \(context.templateName) template"
                    ))
                }
                items.append(PaletteActionItem(
                    action: .renameStack(stack.id), title: "Rename “\(stack.name)”", keys: "⌘R"
                ))
            }
            items.append(template)
            items.append(PaletteActionItem(action: .backToStacks, title: "All Stacks", keys: "←"))
            if let undo = context.undo {
                items.append(PaletteActionItem(action: .undoClear, title: undo.title, keys: "⌘Z"))
            }
            if let stack = context.openStack, stack.noteCount > 0 {
                items.append(PaletteActionItem(
                    action: .clearStack(stack.id),
                    title: "Clear “\(stack.name)”",
                    keys: "⇧⌘⌫",
                    subtitle: "Sets the notes aside; undo with ⌘Z",
                    isDestructive: true
                ))
            }
        }
        return items
    }

    /// The ⌘K menu narrowed by what was typed into it.
    static func filter(_ items: [PaletteActionItem], query: String) -> [PaletteActionItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let needle = SessionDocumentMutations.normalizedSessionName(trimmed) else {
            return items
        }
        return items.filter {
            let text = SessionDocumentMutations.normalizedSessionName(
                [$0.title, $0.subtitle ?? ""].joined(separator: " ")) ?? ""
            return text.contains(needle)
        }
    }
}

/// The keys the palette claims ahead of its text fields.
enum PaletteKey: Equatable {
    case up, down, left, right
    case optionUp, optionDown
    case tab, backTab
    case activate, commandActivate
    case escape
    case delete, commandDelete, shiftCommandDelete
    case commandDigit(Int)
    case command(Character)
    case shiftCommand(Character)
}
