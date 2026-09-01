import Foundation
import XCTest

@testable import ClipboardAnnotatorDomain

final class ModelsAndPromptComposerTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_735_831_440)
    private let locale = Locale(identifier: "en_US_POSIX")
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    func testStoreDocumentRoundTripsAllCurrentModelFactsAndArrayOrder() throws {
        let annotationID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let first = Annotation(
            id: annotationID,
            subject: .selection(quote: "A quote"),
            note: "A note",
            provenance: Provenance(
                application: ApplicationIdentity(
                    name: "Reader",
                    bundleID: "com.example.reader"
                ),
                windowTitle: "Article",
                url: URL(string: "https://example.com/article"),
                workingDirectory: URL(fileURLWithPath: "/tmp/reading")
            ),
            createdAt: date
        )
        let second = Annotation(
            id: annotationID,
            subject: .standalone,
            note: "A second note with the same ID remains in an ordinary Array.",
            provenance: Provenance(application: ApplicationIdentity(name: "Reader")),
            createdAt: date.addingTimeInterval(60)
        )
        let session = Session(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            name: "Reading",
            entries: [first, second],
            createdAt: date
        )
        let document = StoreDocument(
            sessions: [session],
            currentSessionID: session.id,
            lastCleared: ClearedBatch(sessionID: session.id, entries: [second, first])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(document)
        let decoded = try decoder.decode(StoreDocument.self, from: data)

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.sessions[0].entries.map(\.note), [first.note, second.note])
        XCTAssertEqual(decoded.lastCleared?.entries.map(\.note), [second.note, first.note])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, StoreDocument.currentVersion)
        XCTAssertNotNil(object["sessions"])
        XCTAssertNotNil(object["currentSessionID"])
        XCTAssertNotNil(object["lastCleared"])
    }

    func testSubjectAndProvenanceRoundTripThroughCodable() throws {
        let subjects: [Subject] = [
            .selection(quote: "First line\n\nThird line"),
            .standalone,
        ]
        let provenance = Provenance(
            application: ApplicationIdentity(name: "Helium", bundleID: "com.example.helium"),
            windowTitle: "Page title",
            url: URL(string: "https://example.com/article"),
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(try decoder.decode([Subject].self, from: encoder.encode(subjects)), subjects)
        XCTAssertEqual(
            try decoder.decode(Provenance.self, from: encoder.encode(provenance)),
            provenance
        )
    }

    func testAnnotationPreservesNoteTextExactly() {
        let note = "  Keep leading space\n\nand trailing space  "
        let annotation = Annotation(
            subject: .standalone,
            note: note,
            provenance: Provenance(application: ApplicationIdentity(name: "Test"))
        )

        XCTAssertEqual(annotation.note, note)
    }

    func testTextNormalizationTrimsAndCaseFoldsSessionIdentity() {
        XCTAssertEqual("  Reading Notes \n".nonblank, "Reading Notes")
        XCTAssertEqual("  Reading Notes \n".normalizedSessionName, "reading notes")
        XCTAssertEqual("READING NOTES".normalizedSessionName, "reading notes")
        XCTAssertEqual("Résumé".normalizedSessionName, "resume")
        XCTAssertEqual("ＲＥＡＤＩＮＧ".normalizedSessionName, "reading")
        XCTAssertNil(" \n\t".nonblank)
        XCTAssertNil(" \n\t".normalizedSessionName)
    }

    func testProfileBuiltInsHaveStableIDsOrderTextAndCurrentSplitFlags() {
        XCTAssertEqual(Profile.builtIns.map(\.name), ["Coherent", "Point by Point", "Plain"])
        XCTAssertEqual(
            Profile.builtIns.map(\.id),
            [
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            ]
        )
        XCTAssertTrue(Profile.coherent.preamble.hasPrefix("These are my reading notes"))
        XCTAssertTrue(Profile.pointByPoint.preamble.contains("Address each note separately."))

        for profile in [Profile.coherent, .pointByPoint] {
            XCTAssertTrue(profile.includeApplication)
            XCTAssertTrue(profile.includeWindow)
            XCTAssertTrue(profile.includeLink)
            XCTAssertTrue(profile.includeTimestamps)
            XCTAssertTrue(profile.includeHeading)
            XCTAssertFalse(profile.clearSessionAfterExport)
        }
        XCTAssertEqual(Profile.plain.preamble, "")
        XCTAssertFalse(Profile.plain.includeApplication)
        XCTAssertFalse(Profile.plain.includeWindow)
        XCTAssertFalse(Profile.plain.includeLink)
        XCTAssertFalse(Profile.plain.includeTimestamps)
        XCTAssertFalse(Profile.plain.includeHeading)
        XCTAssertFalse(Profile.plain.clearSessionAfterExport)
    }

    func testProfileCodableWritesOnlyCurrentSplitSourceFlags() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Profile.coherent)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["includeApplication"] as? Bool, true)
        XCTAssertEqual(object["includeWindow"] as? Bool, true)
        XCTAssertEqual(object["includeLink"] as? Bool, true)
        XCTAssertNil(object["includeProvenance"])
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: data), .coherent)
    }

    func testComposerIncludesPreambleHeadingEntriesAndFullMetadata() {
        let output = compose(profile: .coherent)

        XCTAssertTrue(output.contains("# Reading notes — January 2, 2025"))
        XCTAssertEqual(output.components(separatedBy: Profile.coherent.preamble).count - 1, 1)
        XCTAssertEqual(output.components(separatedBy: "## ").count - 1, 2)
        XCTAssertEqual(
            metadata(in: output),
            ["Helium", "Page title", "https://example.com/article", "/tmp/project", expectedTime]
        )
    }

    func testComposerKeepsAllMetadataFlagsIndependent() {
        var applicationOnly = Profile.plain
        applicationOnly.includeApplication = true
        XCTAssertEqual(metadata(in: compose(profile: applicationOnly)), ["Helium"])

        var windowOnly = Profile.plain
        windowOnly.includeWindow = true
        XCTAssertEqual(metadata(in: compose(profile: windowOnly)), ["Page title"])

        var linkOnly = Profile.plain
        linkOnly.includeLink = true
        XCTAssertEqual(
            metadata(in: compose(profile: linkOnly)),
            ["https://example.com/article", "/tmp/project"]
        )

        var timestampOnly = Profile.plain
        timestampOnly.includeTimestamps = true
        XCTAssertEqual(metadata(in: compose(profile: timestampOnly)), [expectedTime])
    }

    func testPlainComposerFormatsSelectionAndStandaloneEntriesExactly() {
        let output = compose(profile: .plain)

        XCTAssertEqual(
            output,
            """
            ## 1

            > First line
            > Second line
            >
            > Fourth line

            Response to selection

            ## 2

            A standalone thought
            """
        )
        XCTAssertFalse(output.contains("Reading notes"))
        XCTAssertFalse(output.contains("Helium"))
    }

    func testComposerDisplaysWebFileAndDirectoryLinksWithoutCouplingThem() {
        var profile = Profile.plain
        profile.includeLink = true

        let webOnly = makeSession(
            provenance: Provenance(
                application: ApplicationIdentity(name: "Browser"),
                url: URL(string: "https://example.com/article")
            )
        )
        XCTAssertEqual(metadata(in: compose(session: webOnly, profile: profile)), ["https://example.com/article"])

        let file = URL(fileURLWithPath: NSHomeDirectory() + "/code/Main.swift")
        let workspace = URL(fileURLWithPath: NSHomeDirectory() + "/code")
        let fileAndDirectory = makeSession(
            provenance: Provenance(
                application: ApplicationIdentity(name: "Editor"),
                url: file,
                workingDirectory: workspace
            )
        )
        XCTAssertEqual(
            metadata(in: compose(session: fileAndDirectory, profile: profile)),
            ["~/code/Main.swift", "~/code"]
        )
    }

    func testBlankProvenanceFactsDoNotCreateEmptyMetadataBlock() {
        let annotation = Annotation(
            subject: .standalone,
            note: "Note",
            provenance: Provenance(
                application: ApplicationIdentity(name: "  "),
                windowTitle: "\n"
            ),
            createdAt: date
        )
        let session = Session(name: "Empty facts", entries: [annotation], createdAt: date)
        var profile = Profile.plain
        profile.includeApplication = true
        profile.includeWindow = true

        XCTAssertEqual(compose(session: session, profile: profile), "## 1\n\nNote")
    }

    private var expectedTime: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func metadata(in markdown: String) -> [String] {
        let firstEntry = markdown.components(separatedBy: "## 1").last ?? ""
        let beforeSecond = firstEntry.components(separatedBy: "## 2").first ?? ""
        guard
            let line = beforeSecond
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .last(where: { $0.hasPrefix("_") && $0.hasSuffix("_") })
        else { return [] }
        return String(line.dropFirst().dropLast()).components(separatedBy: " · ")
    }

    private func compose(profile: Profile) -> String {
        compose(session: makeSession(), profile: profile)
    }

    private func compose(session: Session, profile: Profile) -> String {
        PromptComposer.markdown(
            session: session,
            profile: profile,
            calendar: Calendar(identifier: .gregorian),
            locale: locale,
            timeZone: timeZone
        )
    }

    private func makeSession(
        provenance: Provenance = Provenance(
            application: ApplicationIdentity(name: "Helium", bundleID: "com.example.helium"),
            windowTitle: "Page title",
            url: URL(string: "https://example.com/article"),
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
    ) -> Session {
        Session(
            name: "Reading",
            entries: [
                Annotation(
                    subject: .selection(quote: "First line\nSecond line\n\nFourth line"),
                    note: "Response to selection",
                    provenance: provenance,
                    createdAt: date
                ),
                Annotation(
                    subject: .standalone,
                    note: "A standalone thought",
                    provenance: provenance,
                    createdAt: date
                ),
            ],
            createdAt: date
        )
    }
}
