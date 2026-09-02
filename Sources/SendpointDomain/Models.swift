import Foundation

public struct ApplicationIdentity: Codable, Hashable, Sendable {
    public var name: String
    public var bundleID: String?

    public init(name: String, bundleID: String? = nil) {
        self.name = name
        self.bundleID = bundleID
    }
}

public enum Subject: Codable, Hashable, Sendable {
    case selection(quote: String)
    case standalone
}

public struct Provenance: Codable, Hashable, Sendable {
    public var application: ApplicationIdentity
    public var windowTitle: String?
    public var url: URL?
    public var workingDirectory: URL?

    public init(
        application: ApplicationIdentity,
        windowTitle: String? = nil,
        url: URL? = nil,
        workingDirectory: URL? = nil
    ) {
        self.application = application
        self.windowTitle = windowTitle
        self.url = url
        self.workingDirectory = workingDirectory
    }
}

public struct Annotation: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var subject: Subject
    public var note: String
    public var provenance: Provenance
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        subject: Subject,
        note: String,
        provenance: Provenance,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.subject = subject
        self.note = note
        self.provenance = provenance
        self.createdAt = createdAt
    }
}

public struct Session: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var entries: [Annotation]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        entries: [Annotation] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.createdAt = createdAt
    }
}

public struct ClearedBatch: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var entries: [Annotation]

    public init(sessionID: UUID, entries: [Annotation]) {
        self.sessionID = sessionID
        self.entries = entries
    }
}

public struct StoreDocument: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var sessions: [Session]
    public var currentSessionID: UUID
    public var lastCleared: ClearedBatch?

    public init(
        version: Int = StoreDocument.currentVersion,
        sessions: [Session],
        currentSessionID: UUID,
        lastCleared: ClearedBatch? = nil
    ) {
        self.version = version
        self.sessions = sessions
        self.currentSessionID = currentSessionID
        self.lastCleared = lastCleared
    }
}

public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var preamble: String
    public var includeApplication: Bool
    public var includeWindow: Bool
    public var includeLink: Bool
    public var includeTimestamps: Bool
    public var includeHeading: Bool
    public var clearSessionAfterExport: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        preamble: String,
        includeApplication: Bool,
        includeWindow: Bool,
        includeLink: Bool,
        includeTimestamps: Bool,
        includeHeading: Bool,
        clearSessionAfterExport: Bool
    ) {
        self.id = id
        self.name = name
        self.preamble = preamble
        self.includeApplication = includeApplication
        self.includeWindow = includeWindow
        self.includeLink = includeLink
        self.includeTimestamps = includeTimestamps
        self.includeHeading = includeHeading
        self.clearSessionAfterExport = clearSessionAfterExport
    }
}

public extension Profile {
    static let coherent = Profile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Coherent",
        preamble: "These are my reading notes, captured in order while I read. Each entry is either a response to a quoted passage or a standalone thought. Read the notes as a whole and give me one coherent response that takes all of them into account. Restate enough context to make each part of your response understandable without requiring me to scroll back. Do not respond point by point unless the notes ask you to.",
        includeApplication: true,
        includeWindow: true,
        includeLink: true,
        includeTimestamps: true,
        includeHeading: true,
        clearSessionAfterExport: false
    )

    static let pointByPoint = Profile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Point by Point",
        preamble: "These are my reading notes, captured in order while I read. Each entry is either a response to a quoted passage or a standalone thought. Address each note separately. Before answering a note, restate the relevant topic or quoted idea in a few words so I never need to look up an entry number.",
        includeApplication: true,
        includeWindow: true,
        includeLink: true,
        includeTimestamps: true,
        includeHeading: true,
        clearSessionAfterExport: false
    )

    static let plain = Profile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Plain",
        preamble: "",
        includeApplication: false,
        includeWindow: false,
        includeLink: false,
        includeTimestamps: false,
        includeHeading: false,
        clearSessionAfterExport: false
    )

    static let builtIns: [Profile] = [.coherent, .pointByPoint, .plain]
}
