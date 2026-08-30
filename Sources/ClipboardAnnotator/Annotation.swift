import Foundation

/// One captured selection plus whatever the user said about it.
struct Annotation: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var quote: String
    var note: String
    var sourceApp: String?
    var sourceURL: String?
    var createdAt: Date = Date()

    /// Short one-line version for list rows.
    var quotePreview: String {
        let flat = quote
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.isEmpty { return "(no selection)" }
        return flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
    }
}
