import AppKit
import SendpointDomain
import Foundation

/// Converts SwiftUI's insertion offset into ordered Domain final-index moves.
enum AnnotationMoveMapping {
    struct Move: Equatable {
        let annotationID: UUID
        let destinationIndex: Int
    }

    static func moves(
        annotationIDs: [UUID],
        from offsets: IndexSet,
        to insertionOffset: Int
    ) -> [Move] {
        let validOffsets = offsets.sorted().filter { annotationIDs.indices.contains($0) }
        guard !validOffsets.isEmpty,
              (0...annotationIDs.count).contains(insertionOffset)
        else { return [] }

        let moving = validOffsets.map { annotationIDs[$0] }
        var desired = annotationIDs
        for offset in validOffsets.reversed() {
            desired.remove(at: offset)
        }
        let destination = insertionOffset - validOffsets.filter { $0 < insertionOffset }.count
        guard (0...desired.count).contains(destination) else { return [] }
        desired.insert(contentsOf: moving, at: destination)

        var working = annotationIDs
        var result: [Move] = []
        for destinationIndex in desired.indices where working[destinationIndex] != desired[destinationIndex] {
            let annotationID = desired[destinationIndex]
            guard let sourceIndex = working.firstIndex(of: annotationID) else { return [] }
            working.remove(at: sourceIndex)
            working.insert(annotationID, at: destinationIndex)
            result.append(Move(annotationID: annotationID, destinationIndex: destinationIndex))
        }
        return result
    }
}

@MainActor
enum SessionExport {
    static func markdown(store: AnnotationStore, settings: AppSettings) -> String {
        PromptComposer.markdown(
            session: store.currentSession,
            profile: settings.activeProfile
        )
    }

    /// Copies the current stack. The clear is conditional on the pasteboard
    /// accepting the Markdown.
    static func copy(
        store: AnnotationStore,
        settings: AppSettings,
        write: @MainActor (String) -> Bool = writeToGeneralPasteboard
    ) -> Bool {
        copy(
            store: store,
            sessionID: store.currentSessionID,
            profile: settings.activeProfile,
            write: write
        )
    }

    static func copy(
        store: AnnotationStore,
        profile: Profile,
        write: @MainActor (String) -> Bool
    ) -> Bool {
        copy(store: store, sessionID: store.currentSessionID, profile: profile, write: write)
    }

    /// Copies any stack, current or not, shaped by `profile`.
    static func copy(
        store: AnnotationStore,
        sessionID: UUID,
        profile: Profile,
        write: @MainActor (String) -> Bool = writeToGeneralPasteboard
    ) -> Bool {
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              !session.entries.isEmpty
        else { return false }
        let markdown = PromptComposer.markdown(session: session, profile: profile)
        guard write(markdown) else { return false }
        if profile.clearSessionAfterExport {
            store.mutate(.clearSession(sessionID: sessionID))
        }
        return true
    }

    private static func writeToGeneralPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
