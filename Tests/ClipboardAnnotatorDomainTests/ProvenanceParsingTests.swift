import Foundation
import XCTest
@testable import ClipboardAnnotatorDomain

final class ProvenanceParsingTests: XCTestCase {
    func testGhosttyFileURLAcceptsAndStandardizesOnlySafeLocalLocations() {
        let expected = URL(fileURLWithPath: "/tmp/repository").standardizedFileURL
        XCTAssertEqual(
            ProvenanceFileURLParser.absoluteFileURL("  /tmp/project/../repository\n"),
            expected
        )
        XCTAssertEqual(
            ProvenanceFileURLParser.absoluteFileURL("file:///tmp/project/../repository"),
            expected
        )

        for value in [
            "relative/path", "file:relative/path", "/tmp/project?query=yes",
            "/tmp/project#fragment", "file:///tmp/project?query=yes",
            "file:///tmp/project#fragment", "file:///tmp/project\0child",
            "file://remote-host/tmp/project", "https://example.com/project",
        ] {
            XCTAssertNil(ProvenanceFileURLParser.absoluteFileURL(value), value)
        }
    }

    func testEditorDocumentAndTitleYieldFileAndOutermostWorkspace() {
        let file = "/Users/reader/code/effect/packages/effect/src/Unify.ts"
        let fields = editorFields(title: "Unify.ts — effect", document: file)

        XCTAssertEqual(fields.url, URL(fileURLWithPath: file))
        XCTAssertEqual(
            fields.workingDirectory,
            URL(fileURLWithPath: "/Users/reader/code/effect")
        )
    }

    func testEditorParsesReversedDirtyProfileRemoteAndAppTitleSegments() {
        let file = "/Users/reader/code/effect/src/Unify.ts"
        let fields = editorFields(
            title: "● Unify.ts — effect [SSH: dev] — Data Science (Profile) — Visual Studio Code - Insiders",
            document: file
        )
        XCTAssertEqual(fields.url, URL(fileURLWithPath: file))
        XCTAssertEqual(fields.workingDirectory, URL(fileURLWithPath: "/Users/reader/code/effect"))

        let reversed = editorFields(
            title: "effect (Workspace) — Unify.ts — Cursor",
            document: file
        )
        XCTAssertEqual(reversed.workingDirectory, URL(fileURLWithPath: "/Users/reader/code/effect"))
    }

    func testEditorDistinguishesDirectoryDocumentAndSingleFile() {
        let directory = URL(fileURLWithPath: "/Users/reader/code/effect")
        let directoryFields = editorFields(
            title: "effect",
            document: directory.path,
            directories: [directory]
        )
        XCTAssertNil(directoryFields.url)
        XCTAssertEqual(directoryFields.workingDirectory, directory)

        let file = URL(fileURLWithPath: "/Users/reader/Desktop/notes.md")
        let fileFields = editorFields(title: "notes.md", document: file.path)
        XCTAssertEqual(fileFields.url, file)
        XCTAssertNil(fileFields.workingDirectory)
    }

    func testEditorUsesAbsoluteTitleHintButRejectsRemoteAndRelativeDocuments() {
        let file = "/Users/reader/code/effect/src/Unify.ts"
        let titleFields = editorFields(title: "\(file) - effect - Cursor", document: nil)
        XCTAssertEqual(titleFields.url, URL(fileURLWithPath: file))
        XCTAssertEqual(titleFields.workingDirectory, URL(fileURLWithPath: "/Users/reader/code/effect"))

        XCTAssertNil(editorFields(
            title: "Main.swift — project",
            document: "vscode-remote://ssh/project/Main.swift"
        ).url)
        XCTAssertNil(editorFields(
            title: "Main.swift — project",
            document: "relative/Main.swift"
        ).url)
    }

    func testProvenanceOnlyMutationRequiresExactAnnotationAndApplication() throws {
        let app = ApplicationIdentity(name: "Editor", bundleID: "com.microsoft.VSCode")
        let annotation = Annotation(
            subject: .standalone,
            note: "Keep this note",
            provenance: Provenance(application: app)
        )
        let session = Session(name: "Default", entries: [annotation])
        let document = StoreDocument(sessions: [session], currentSessionID: session.id)
        let enriched = Provenance(
            application: app,
            windowTitle: "Main.swift — project",
            url: URL(fileURLWithPath: "/tmp/project/Main.swift")
        )

        let result = SessionDocumentMutations.applying(
            .updateAnnotationProvenance(
                sessionID: session.id,
                annotationID: annotation.id,
                expectedApplication: app,
                provenance: enriched
            ),
            to: document
        )
        guard case let .applied(updated) = result else {
            return XCTFail("Expected provenance update")
        }
        XCTAssertEqual(updated.sessions[0].entries[0].note, annotation.note)
        XCTAssertEqual(updated.sessions[0].entries[0].provenance, enriched)

        let stale = SessionDocumentMutations.applying(
            .updateAnnotationProvenance(
                sessionID: session.id,
                annotationID: annotation.id,
                expectedApplication: ApplicationIdentity(name: "Other"),
                provenance: Provenance(application: ApplicationIdentity(name: "Other"))
            ),
            to: document
        )
        XCTAssertEqual(stale, .noOp)
    }

    func testNoteOnlyAndClearedProvenanceUpdatesNoOpForMissingOrStaleTargets() throws {
        let app = ApplicationIdentity(name: "Editor", bundleID: "com.microsoft.VSCode")
        let annotation = Annotation(
            subject: .standalone,
            note: "Original",
            provenance: Provenance(application: app)
        )
        let session = Session(name: "Default", entries: [annotation])
        let document = StoreDocument(sessions: [session], currentSessionID: session.id)

        XCTAssertEqual(
            SessionDocumentMutations.applying(
                .updateAnnotationNote(
                    sessionID: session.id,
                    annotationID: UUID(),
                    note: "Stale"
                ),
                to: document
            ),
            .noOp
        )
        XCTAssertEqual(
            SessionDocumentMutations.applying(
                .updateAnnotationNote(
                    sessionID: UUID(),
                    annotationID: annotation.id,
                    note: "Stale"
                ),
                to: document
            ),
            .noOp
        )

        guard case let .applied(cleared) = SessionDocumentMutations.applying(
            .clearSession(sessionID: session.id),
            to: document
        ) else { return XCTFail("Expected clear") }
        let enriched = Provenance(application: app, windowTitle: "Focused window")
        let wrongApp = ApplicationIdentity(name: "Other")
        for mutation in [
            SessionDocumentMutation.updateAnnotationProvenance(
                sessionID: UUID(),
                annotationID: annotation.id,
                expectedApplication: app,
                provenance: enriched
            ),
            .updateAnnotationProvenance(
                sessionID: session.id,
                annotationID: UUID(),
                expectedApplication: app,
                provenance: enriched
            ),
            .updateAnnotationProvenance(
                sessionID: session.id,
                annotationID: annotation.id,
                expectedApplication: wrongApp,
                provenance: Provenance(application: wrongApp, windowTitle: "Wrong")
            ),
        ] {
            XCTAssertEqual(SessionDocumentMutations.applying(mutation, to: cleared), .noOp)
        }
    }

    private func editorFields(
        title: String?,
        document: String?,
        directories: [URL] = []
    ) -> ProvenanceFields {
        let paths = Set(directories.map(\.standardizedFileURL.path))
        return CodeEditorProvenance.fields(
            windowTitle: title,
            document: document,
            isDirectory: { paths.contains($0.standardizedFileURL.path) }
        )
    }
}
