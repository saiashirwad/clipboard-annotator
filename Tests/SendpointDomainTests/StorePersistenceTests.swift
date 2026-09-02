import Foundation
import XCTest
@testable import SendpointDomain

final class StorePersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

    func testLiveRoundTripUsesVersionedStoreJSON() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = StorePersistence.live(directory: directory)
        let first = document(name: "Round trip").sessions[0]
        let second = Session(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            name: "Second",
            createdAt: now
        )
        let expected = StoreDocument(
            sessions: [first, second],
            currentSessionID: second.id
        )

        try await persistence.commit(expected)

        let loaded = try await persistence.load()
        XCTAssertEqual(loaded, expected)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(StorePersistence.fileName).path
            )
        )
    }

    func testMalformedCurrentVersionIsQuarantined() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(StorePersistence.fileName)
        try Data(#"{"version":1}"#.utf8).write(to: file)
        let fixedNow = now
        let persistence = StorePersistence.live(directory: directory, now: { fixedNow })

        let recovered = try await persistence.load()
        XCTAssertNil(recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains(where: { $0.hasSuffix(".corrupt") }))
    }

    func testUnknownVersionIsRejectedWithoutQuarantine() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(StorePersistence.fileName)
        let unknownVersion = StoreDocument.currentVersion + 1
        try Data(#"{"version":\#(unknownVersion)}"#.utf8).write(to: file)

        do {
            _ = try await StorePersistence.live(directory: directory).load()
            XCTFail("Expected unsupported version")
        } catch let error as StorePersistenceError {
            XCTAssertEqual(error, .unsupportedVersion(unknownVersion))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.hasSuffix(".corrupt") }))
    }

    func testInvalidCommitDoesNotReplaceLastCommittedDocument() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = StorePersistence.live(directory: directory)
        let original = document()
        try await persistence.commit(original)
        let invalid = StoreDocument(
            sessions: original.sessions,
            currentSessionID: UUID()
        )

        do {
            try await persistence.commit(invalid)
            XCTFail("Expected invalid document")
        } catch let error as StorePersistenceError {
            guard case .invalidDocument = error else {
                return XCTFail("Expected invalid document, got \(error)")
            }
        }

        let loaded = try await persistence.load()
        XCTAssertEqual(loaded, original)
    }

    func testStackJSONIsNotLoadedOrChanged() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyFile = directory.appendingPathComponent("stack.json")
        let bytes = Data(#"[{"old":"format"}]"#.utf8)
        try bytes.write(to: legacyFile)

        let loaded = try await StorePersistence.live(directory: directory).load()
        XCTAssertNil(loaded)
        XCTAssertEqual(try Data(contentsOf: legacyFile), bytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(StorePersistence.fileName).path
            )
        )
    }

    private func document(name: String = "First") -> StoreDocument {
        StoreDocument(
            sessions: [Session(id: sessionID, name: name, createdAt: now)],
            currentSessionID: sessionID
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
