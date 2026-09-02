import AppKit
import ApplicationServices
import ClipboardAnnotatorDomain
import Foundation

struct CapturedApplication: Hashable, Sendable {
    let identity: ApplicationIdentity
    let processIdentifier: pid_t
}

/// The one injected boundary used to resolve provenance for a captured app.
struct ProvenanceProbe: Sendable {
    typealias Lookup = @Sendable (CapturedApplication) async throws -> ProvenanceFields
    typealias ApplicationValidator = @Sendable (CapturedApplication) async throws -> Bool

    private let validateApplication: ApplicationValidator
    private let genericLookup: Lookup
    private let enrichers: [String: Lookup]

    init(
        validateApplication: @escaping ApplicationValidator = { _ in true },
        genericLookup: @escaping Lookup,
        enrichers: [String: Lookup] = [:]
    ) {
        self.validateApplication = validateApplication
        self.genericLookup = genericLookup
        self.enrichers = enrichers
    }

    func probe(_ application: CapturedApplication) async -> Provenance {
        let empty = Provenance(application: application.identity)
        let baselineFields: ProvenanceFields
        do {
            try Task.checkCancellation()
            guard try await validateApplication(application) else { return empty }
            try Task.checkCancellation()
            baselineFields = try await genericLookup(application)
            try Task.checkCancellation()
            guard try await validateApplication(application) else { return empty }
            try Task.checkCancellation()
        } catch {
            return empty
        }

        let baseline = provenance(application.identity, baselineFields)
        guard let bundleID = application.identity.bundleID,
              let enrich = enrichers[bundleID]
        else { return baseline }

        do {
            try Task.checkCancellation()
            guard try await validateApplication(application) else { return baseline }
            try Task.checkCancellation()
            let fields = try await enrich(application)
            try Task.checkCancellation()
            guard try await validateApplication(application) else { return baseline }
            try Task.checkCancellation()
            return provenance(application.identity, baselineFields.merging(fields))
        } catch {
            return baseline
        }
    }

    static let codeEditorBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.microsoft.VSCodeExploration", "com.visualstudio.code.oss",
        "com.vscodium", "com.vscodium.VSCodium", "com.vscodium.VSCodiumInsiders",
        "com.todesktop.230313mzl4w4u92", "co.anysphere.cursor.nightly",
        "com.exafunction.windsurf", "com.google.antigravity",
        "com.google.antigravity-ide", "com.t3tools.t3code", "com.trae.app",
        "dev.zed.Zed", "dev.zed.Zed-Preview",
    ]

    /// Browsers that answer the Chromium AppleScript dictionary. Asking one for
    /// its active tab triggers the macOS Automation prompt for that browser once.
    static let chromiumBrowserBundleIDs: Set<String> = [
        "net.imput.helium",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.google.Chrome.canary", "org.chromium.Chromium",
        "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
    ]

    static let safariBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]

    static func live() -> Self {
        var enrichers: [String: Lookup] = [
            "com.mitchellh.ghostty": { application in
                try await ProvenanceSystemBoundary.ghosttyFields(
                    processIdentifier: application.processIdentifier
                )
            },
        ]
        for bundleID in chromiumBrowserBundleIDs {
            enrichers[bundleID] = browserEnricher(
                bundleID: bundleID,
                script: BrowserActiveTabScript.chromium(bundleID: bundleID)
            )
        }
        for bundleID in safariBundleIDs {
            enrichers[bundleID] = browserEnricher(
                bundleID: bundleID,
                script: BrowserActiveTabScript.safari(bundleID: bundleID)
            )
        }
        for bundleID in codeEditorBundleIDs {
            enrichers[bundleID] = { application in
                try await ProvenanceSystemBoundary.codeEditorFields(
                    processIdentifier: application.processIdentifier
                )
            }
        }
        return Self(
            validateApplication: { application in
                try await ProvenanceSystemBoundary.matchesCapturedApplication(application)
            },
            genericLookup: { application in
                try await ProvenanceSystemBoundary.focusedWindowFields(
                    processIdentifier: application.processIdentifier
                )
            },
            enrichers: enrichers
        )
    }

    private static func browserEnricher(bundleID: String, script: String) -> Lookup {
        { application in
            let matches = await ProvenanceSystemBoundary.isRunningApplication(
                processIdentifier: application.processIdentifier,
                bundleID: bundleID
            )
            try Task.checkCancellation()
            guard matches else { return ProvenanceFields() }
            return try await ProvenanceSystemBoundary.activeTabFields(script: script)
        }
    }

    private func provenance(
        _ identity: ApplicationIdentity,
        _ fields: ProvenanceFields
    ) -> Provenance {
        Provenance(
            application: identity,
            windowTitle: fields.windowTitle,
            url: fields.url,
            workingDirectory: fields.workingDirectory
        )
    }
}

/// AppleScript that returns "title\nURL" for the front window's active tab.
/// Each script targets a bundle ID, so it never launches a browser by name.
enum BrowserActiveTabScript {
    static func chromium(bundleID: String) -> String {
        """
        with timeout of 2 seconds
            tell application id "\(bundleID)"
                if not (exists front window) then return ""
                set selectedTab to active tab of front window
                return (title of selectedTab as text) & linefeed & (URL of selectedTab as text)
            end tell
        end timeout
        """
    }

    static func safari(bundleID: String) -> String {
        """
        with timeout of 2 seconds
            tell application id "\(bundleID)"
                if not (exists front window) then return ""
                set selectedTab to current tab of front window
                return (name of selectedTab as text) & linefeed & (URL of selectedTab as text)
            end tell
        end timeout
        """
    }
}

enum BrowserActiveTabParser {
    static func fields(from result: String) -> ProvenanceFields {
        let parts = result.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let title = parts.first.flatMap { nonblank(String($0)) }
        let url = parts.count == 2 ? absoluteWebURL(String(parts[1])) : nil
        return ProvenanceFields(windowTitle: title, url: url)
    }

    private static func nonblank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func absoluteWebURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url,
              !url.isFileURL
        else { return nil }
        return url
    }
}

@globalActor
private actor ProvenanceSystemActor {
    static let shared = ProvenanceSystemActor()
}

@ProvenanceSystemActor
private enum ProvenanceSystemBoundary {
    private static let accessibilityTimeout: Float = 1

    static func matchesCapturedApplication(_ captured: CapturedApplication) throws -> Bool {
        try Task.checkCancellation()
        guard let application = NSRunningApplication(
            processIdentifier: captured.processIdentifier
        ) else { return false }
        try Task.checkCancellation()
        guard !application.isTerminated else { return false }
        if let bundleID = captured.identity.bundleID {
            return application.bundleIdentifier == bundleID
        }
        return application.bundleIdentifier == nil
            && application.localizedName == captured.identity.name
    }

    static func focusedWindowFields(processIdentifier: pid_t) throws -> ProvenanceFields {
        guard let window = try focusedWindow(processIdentifier: processIdentifier) else {
            return ProvenanceFields()
        }
        return ProvenanceFields(windowTitle: try stringValue(window, kAXTitleAttribute))
    }

    static func ghosttyFields(processIdentifier: pid_t) throws -> ProvenanceFields {
        guard let window = try focusedWindow(processIdentifier: processIdentifier) else {
            return ProvenanceFields()
        }
        let title = try stringValue(window, kAXTitleAttribute)
        let document = try stringValue(window, kAXDocumentAttribute)
        return ProvenanceFields(
            windowTitle: title,
            workingDirectory: document.flatMap(ProvenanceFileURLParser.absoluteFileURL)
        )
    }

    static func codeEditorFields(processIdentifier: pid_t) throws -> ProvenanceFields {
        guard let window = try focusedWindow(processIdentifier: processIdentifier) else {
            return ProvenanceFields()
        }
        let title = try stringValue(window, kAXTitleAttribute)
        let document = try stringValue(window, kAXDocumentAttribute)
        try Task.checkCancellation()
        let parsed = CodeEditorProvenance.fields(
            windowTitle: title,
            document: document,
            isDirectory: CodeEditorProvenance.isDirectoryOnDisk
        )
        try Task.checkCancellation()
        return ProvenanceFields(
            windowTitle: title,
            url: parsed.url,
            workingDirectory: parsed.workingDirectory
        )
    }

    static func isRunningApplication(processIdentifier: pid_t, bundleID: String) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return false
        }
        return !application.isTerminated && application.bundleIdentifier == bundleID
    }

    static func activeTabFields(script source: String) throws -> ProvenanceFields {
        try Task.checkCancellation()
        guard let script = NSAppleScript(source: source) else { return ProvenanceFields() }
        var error: NSDictionary?
        try Task.checkCancellation()
        let descriptor = script.executeAndReturnError(&error)
        try Task.checkCancellation()
        guard error == nil, let result = descriptor.stringValue else {
            return ProvenanceFields()
        }
        return BrowserActiveTabParser.fields(from: result)
    }

    private static func focusedWindow(processIdentifier: pid_t) throws -> AXUIElement? {
        guard processIdentifier > 0 else { return nil }
        try Task.checkCancellation()
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, accessibilityTimeout)
        try Task.checkCancellation()
        guard let value = try copiedValue(application, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringValue(
        _ element: AXUIElement,
        _ attribute: String
    ) throws -> String? {
        try copiedValue(element, attribute).flatMap { value in
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func copiedValue(
        _ element: AXUIElement,
        _ attribute: String
    ) throws -> CFTypeRef? {
        var value: CFTypeRef?
        try Task.checkCancellation()
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        try Task.checkCancellation()
        guard result == .success else { return nil }
        return value
    }
}
