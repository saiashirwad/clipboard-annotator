import Foundation

public enum PromptComposer {
    public static func markdown(
        session: Session,
        profile: Profile,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let longDateStyle = Date.FormatStyle(
            date: .long,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
        let shortTimeStyle = Date.FormatStyle(
            date: .omitted,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
        var blocks: [String] = []

        if !profile.preamble.isEmpty {
            blocks.append(profile.preamble)
        }

        if profile.includeHeading {
            blocks.append("# Reading notes — \(session.createdAt.formatted(longDateStyle))")
        }

        for (offset, entry) in session.entries.enumerated() {
            var entryBlocks = ["## \(offset + 1)"]

            if case let .selection(quote) = entry.subject {
                entryBlocks.append(blockquote(quote))
            }

            entryBlocks.append(entry.note)

            let metadata = metadata(
                for: entry,
                profile: profile,
                shortTimeStyle: shortTimeStyle
            )
            if !metadata.isEmpty {
                entryBlocks.append("_\(metadata.joined(separator: " · "))_")
            }

            blocks.append(entryBlocks.joined(separator: "\n\n"))
        }

        return blocks.joined(separator: "\n\n")
    }

    private static func blockquote(_ quote: String) -> String {
        quote
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }

    private static func metadata(
        for entry: Annotation,
        profile: Profile,
        shortTimeStyle: Date.FormatStyle
    ) -> [String] {
        var facts: [String] = []

        if profile.includeApplication {
            appendIfPresent(entry.provenance.application.name, to: &facts)
        }
        if profile.includeWindow {
            appendIfPresent(entry.provenance.windowTitle, to: &facts)
        }
        if profile.includeLink {
            if let url = entry.provenance.url {
                appendIfPresent(displayLink(url), to: &facts)
            }
            if let directory = entry.provenance.workingDirectory {
                appendIfPresent(abbreviatedPath(directory), to: &facts)
            }
        }

        if profile.includeTimestamps {
            facts.append(entry.createdAt.formatted(shortTimeStyle))
        }

        return facts
    }

    private static func appendIfPresent(_ value: String?, to values: inout [String]) {
        guard
            let value,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        values.append(value)
    }

    private static func displayLink(_ url: URL) -> String {
        url.isFileURL ? abbreviatedPath(url) : url.absoluteString
    }

    private static func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
