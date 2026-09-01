import Foundation

public extension String {
    var nonblank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedSessionName: String? {
        guard let trimmed = nonblank else { return nil }
        let locale = Locale(identifier: "en_US_POSIX")
        let normalized = trimmed
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            .lowercased(with: locale)
        return normalized.isEmpty ? nil : normalized
    }
}
