import SendpointDomain
import Foundation
import XCTest
@testable import Sendpoint

final class StackPaletteTests: XCTestCase {
    private let stackID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private let otherStackID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    private let firstNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private let secondNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    private let thirdNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!

    private var entries: [Annotation] {
        [
            Annotation(
                id: firstNoteID,
                subject: .selection(quote: "OT scales quadratically"),
                note: "Can you explain why?",
                provenance: Provenance(
                    application: ApplicationIdentity(name: "Helium"),
                    windowTitle: "CRDT deep dive",
                    url: URL(string: "https://example.com/crdt")
                )
            ),
            Annotation(
                id: secondNoteID,
                subject: .standalone,
                note: "Monoids and semi-groups",
                provenance: Provenance(application: ApplicationIdentity(name: "Safari"))
            ),
            Annotation(
                id: thirdNoteID,
                subject: .selection(quote: "join-semilattice"),
                note: "",
                provenance: Provenance(application: ApplicationIdentity(name: "Helium"))
            ),
        ]
    }

    func testNoteListingSearchesQuoteNoteAppAndWindow() {
        let all = NoteListing(entries: entries, query: "  ")
        XCTAssertEqual(all.ids, [firstNoteID, secondNoteID, thirdNoteID])

        XCTAssertEqual(NoteListing(entries: entries, query: "QUADRAT").ids, [firstNoteID], "quote")
        XCTAssertEqual(NoteListing(entries: entries, query: "monoid").ids, [secondNoteID], "note")
        XCTAssertEqual(
            NoteListing(entries: entries, query: "helium").ids, [firstNoteID, thirdNoteID], "app")
        XCTAssertEqual(NoteListing(entries: entries, query: "deep dive").ids, [firstNoteID], "window")
        XCTAssertTrue(NoteListing(entries: entries, query: "zzz").isEmpty)
    }

    func testNoteHighlightWrapsAndConfines() {
        let ids = [firstNoteID, secondNoteID, thirdNoteID]
        var state = NoteHighlightState()
        XCTAssertNil(state.highlight)

        state.move(by: -1, in: ids)
        XCTAssertEqual(state.highlight, thirdNoteID, "moving up with no highlight lands on the last note")
        state.move(by: 1, in: ids)
        XCTAssertEqual(state.highlight, firstNoteID, "wraps from the bottom")
        state.move(by: 1, in: ids)
        XCTAssertEqual(state.highlight, secondNoteID)

        state.confine(to: [firstNoteID, secondNoteID])
        XCTAssertEqual(state.highlight, secondNoteID, "a still-listed highlight stays put")
        state.confine(to: [thirdNoteID])
        XCTAssertEqual(state.highlight, thirdNoteID, "an unlisted highlight falls to the first note")
        state.confine(to: [])
        XCTAssertNil(state.highlight)
    }

    func testStackLevelActionsFollowTheHighlightedStack() {
        let context = PaletteActionContext(
            level: .stacks,
            focus: .stack(id: stackID, name: "crdt", isCurrent: false, noteCount: 3),
            openStack: nil,
            canDeleteStack: true,
            undo: SessionUndoFacts(
                sessionID: otherStackID, sessionName: "Default", annotationCount: 1,
                isCurrentSession: true),
            templateName: "Coherent"
        )
        let items = PaletteActionCatalog.items(for: context)
        XCTAssertEqual(items.map(\.action), [
            .switchToStack(stackID), .openStack(stackID), .copyStack(stackID),
            .renameStack(stackID), .newStack, .chooseTemplate, .undoClear,
            .clearStack(stackID), .deleteStack(stackID),
        ])
        XCTAssertEqual(items.first?.title, "Switch to “crdt”")
        XCTAssertEqual(items.first?.keys, "↩")
        XCTAssertEqual(items.first { $0.action == .undoClear }?.title, "Undo Clear (1)")
        XCTAssertTrue(items.last?.isDestructive ?? false)

        let empty = PaletteActionCatalog.items(for: PaletteActionContext(
            level: .stacks,
            focus: .stack(id: stackID, name: "crdt", isCurrent: true, noteCount: 0),
            openStack: nil, canDeleteStack: false, undo: nil, templateName: "Plain"
        ))
        XCTAssertEqual(empty.map(\.action), [
            .switchToStack(stackID), .openStack(stackID), .renameStack(stackID), .newStack,
            .chooseTemplate,
        ], "an empty, only stack cannot be copied, cleared, or deleted")
        XCTAssertEqual(empty.first?.title, "Keep “crdt” current")

        let create = PaletteActionCatalog.items(for: PaletteActionContext(
            level: .stacks, focus: .createStack(name: "New"), openStack: nil,
            canDeleteStack: true, undo: nil, templateName: "Plain"
        ))
        XCTAssertEqual(create.map(\.action), [.createStack("New"), .chooseTemplate])
    }

    func testNoteLevelActionsFollowTheHighlightedNoteAndOpenStack() {
        let url = URL(string: "https://example.com/crdt")!
        let context = PaletteActionContext(
            level: .notes(stackID),
            focus: .note(id: secondNoteID, index: 1, count: 3, sourceURL: url),
            openStack: (id: stackID, name: "crdt", isCurrent: false, noteCount: 3),
            canDeleteStack: true,
            undo: nil,
            templateName: "Coherent"
        )
        let items = PaletteActionCatalog.items(for: context)
        XCTAssertEqual(items.map(\.action), [
            .editNote(secondNoteID), .copyNote(secondNoteID), .openSource(url),
            .moveNoteUp(secondNoteID), .moveNoteDown(secondNoteID), .deleteNote(secondNoteID),
            .switchToStack(stackID), .copyStack(stackID), .renameStack(stackID),
            .chooseTemplate, .backToStacks, .clearStack(stackID),
        ])
        XCTAssertEqual(items.first { $0.action == .switchToStack(stackID) }?.keys, "⌘↩")
        XCTAssertEqual(items.first { $0.action == .copyStack(stackID) }?.keys, "⇧⌘C")

        let last = PaletteActionCatalog.items(for: PaletteActionContext(
            level: .notes(stackID),
            focus: .note(id: thirdNoteID, index: 2, count: 3, sourceURL: nil),
            openStack: (id: stackID, name: "crdt", isCurrent: true, noteCount: 3),
            canDeleteStack: true, undo: nil, templateName: "Coherent"
        ))
        XCTAssertFalse(last.contains { $0.action == .moveNoteDown(thirdNoteID) }, "last note cannot move down")
        XCTAssertFalse(last.contains { $0.action == .openSource(url) }, "no source without a link")
        XCTAssertFalse(last.contains { $0.action == .switchToStack(stackID) }, "current stack needs no switch")

        let nothing = PaletteActionCatalog.items(for: PaletteActionContext(
            level: .notes(stackID), focus: .nothing,
            openStack: (id: stackID, name: "crdt", isCurrent: true, noteCount: 0),
            canDeleteStack: true, undo: nil, templateName: "Coherent"
        ))
        XCTAssertEqual(nothing.map(\.action), [.renameStack(stackID), .chooseTemplate, .backToStacks])
    }

    func testActionFilterMatchesTitleAndSubtitle() {
        let items = PaletteActionCatalog.items(for: PaletteActionContext(
            level: .stacks,
            focus: .stack(id: stackID, name: "crdt", isCurrent: false, noteCount: 3),
            openStack: nil, canDeleteStack: true, undo: nil, templateName: "Coherent"
        ))
        XCTAssertEqual(
            PaletteActionCatalog.filter(items, query: "del").map(\.action), [.deleteStack(stackID)])
        XCTAssertEqual(
            PaletteActionCatalog.filter(items, query: "coherent").map(\.action),
            [.copyStack(stackID), .chooseTemplate], "the template name appears in a subtitle")
        XCTAssertEqual(PaletteActionCatalog.filter(items, query: " ").count, items.count)
    }
}
