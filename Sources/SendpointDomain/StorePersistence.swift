import Foundation

public enum StorePersistenceError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidDocument(String)
    case unavailable
}

/// An injected persistence boundary for the versioned session document.
public struct StorePersistence: Sendable {
    public static let fileName = "store.json"

    private let loadOperation: @Sendable () async throws -> StoreDocument?
    private let commitOperation: @Sendable (StoreDocument) async throws -> Void

    public init(
        load: @escaping @Sendable () async throws -> StoreDocument?,
        commit: @escaping @Sendable (StoreDocument) async throws -> Void
    ) {
        self.loadOperation = load
        self.commitOperation = commit
    }

    public func load() async throws -> StoreDocument? {
        try await loadOperation()
    }

    public func commit(_ document: StoreDocument) async throws {
        try await commitOperation(document)
    }

    public static let unavailable = StorePersistence(
        load: { throw StorePersistenceError.unavailable },
        commit: { _ in throw StorePersistenceError.unavailable }
    )

    public static func live(
        directory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> StorePersistence {
        let baseDirectory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Sendpoint", isDirectory: true)
        let storage = AtomicJSONStore(directory: baseDirectory, now: now)
        return StorePersistence(
            load: { try await storage.load() },
            commit: { try await storage.commit($0) }
        )
    }
}

private actor AtomicJSONStore {
    private struct VersionEnvelope: Decodable {
        var version: Int
    }

    private let directory: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let now: @Sendable () -> Date
    private let quarantineDateFormatter: ISO8601DateFormatter

    init(directory: URL, now: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(StorePersistence.fileName)
        self.now = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.quarantineDateFormatter = ISO8601DateFormatter()
    }

    func load() throws -> StoreDocument? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            try quarantine(using: fileManager)
            return nil
        }

        let version: Int
        do {
            version = try decoder.decode(VersionEnvelope.self, from: data).version
        } catch {
            try quarantine(using: fileManager)
            return nil
        }
        guard version == StoreDocument.currentVersion else {
            throw StorePersistenceError.unsupportedVersion(version)
        }

        do {
            let document = try decoder.decode(StoreDocument.self, from: data)
            try SessionDocumentMutations.validate(document)
            return document
        } catch is SessionDocumentValidationError {
            try quarantine(using: fileManager)
            return nil
        } catch {
            try quarantine(using: fileManager)
            return nil
        }
    }

    func commit(_ document: StoreDocument) throws {
        guard document.version == StoreDocument.currentVersion else {
            throw StorePersistenceError.unsupportedVersion(document.version)
        }
        do {
            try SessionDocumentMutations.validate(document)
        } catch let error as SessionDocumentValidationError {
            throw StorePersistenceError.invalidDocument(error.message)
        }

        // Finish validation and encoding before touching the last committed file.
        let data = try encoder.encode(document)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func quarantine(using fileManager: FileManager) throws {
        let stamp = quarantineDateFormatter
            .string(from: now())
            .replacingOccurrences(of: ":", with: "-")
        var destination = fileURL.appendingPathExtension("\(stamp).corrupt")
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = fileURL.appendingPathExtension("\(stamp)-\(suffix).corrupt")
            suffix += 1
        }
        try fileManager.moveItem(at: fileURL, to: destination)
    }
}
