import AppKit
import Combine

/// The stack of annotations, persisted to disk so it survives a restart.
@MainActor
final class AnnotationStore: ObservableObject {
    static let shared = AnnotationStore()

    @Published private(set) var entries: [Annotation] = []

    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardAnnotator", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("stack.json")
        load()
    }

    // MARK: - Mutations

    func add(_ annotation: Annotation) {
        guard !entries.contains(where: { $0.id == annotation.id }) else {
            Diag.log("refused duplicate add id=\(annotation.id)")
            return
        }
        entries.append(annotation)
        save()
    }

    func update(_ annotation: Annotation) {
        guard let index = entries.firstIndex(where: { $0.id == annotation.id }) else { return }
        entries[index] = annotation
        save()
    }

    func remove(ids: Set<Annotation.ID>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        entries.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    /// Clearing is one keystroke away, so keep the last cleared batch around
    /// until the next clear. No dialog needed when the mistake is undoable.
    @Published private(set) var lastCleared: [Annotation] = []

    func clear() {
        guard !entries.isEmpty else { return }
        lastCleared = entries
        entries.removeAll()
        save()
    }

    func undoClear() {
        guard !lastCleared.isEmpty else { return }
        // Put the batch back where it was. Anything captured since the clear
        // keeps its place after it, rather than the restored notes landing last.
        let existing = entries
        entries = lastCleared + existing.filter { added in
            !lastCleared.contains { $0.id == added.id }
        }
        lastCleared = []
        Diag.log("undoClear restored \(entries.count) entries")
        save()
    }

    // MARK: - Export

    func markdown(includeSource: Bool, includeHeading: Bool) -> String {
        var lines: [String] = []

        if includeHeading {
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none)
            lines.append("# Reading notes — \(stamp)")
            lines.append("")
        }

        for (index, entry) in entries.enumerated() {
            lines.append("## \(index + 1)")
            lines.append("")

            let quote = entry.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            if !quote.isEmpty {
                for line in quote.components(separatedBy: .newlines) {
                    lines.append(line.isEmpty ? ">" : "> " + line)
                }
                lines.append("")
            }

            let note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                lines.append(note)
                lines.append("")
            }

            if includeSource {
                var bits: [String] = []
                if let app = entry.sourceApp { bits.append(app) }
                if let url = entry.sourceURL { bits.append(url) }
                bits.append(DateFormatter.localizedString(from: entry.createdAt, dateStyle: .none, timeStyle: .short))
                lines.append("*\(bits.joined(separator: " · "))*")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    @discardableResult
    func copyMarkdownToPasteboard() -> Bool {
        guard !entries.isEmpty else { return false }
        let settings = AppSettings.shared
        let text = markdown(includeSource: settings.includeSource, includeHeading: settings.includeHeading)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if settings.clearAfterCopy { clear() }
        return true
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([Annotation].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
