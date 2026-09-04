import AppKit
import SendpointDomain
import SwiftUI

/// The one surface for stacks: a searchable list with the highlighted stack's
/// notes previewed beside it, and the same notes opened full-width with →.
struct StackPaletteView: View {
    @Bindable var model: StackPaletteModel
    @FocusState private var focus: StackPaletteModel.Field?

    static let minimumSize = CGSize(width: 780, height: 460)
    private let stackColumnWidth: CGFloat = 300
    private let rowHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.store.error {
                Divider()
                errorRow(error)
            }
            Divider()
            footer
        }
        .frame(
            minWidth: Self.minimumSize.width, maxWidth: .infinity,
            minHeight: Self.minimumSize.height, maxHeight: .infinity
        )
        .background(.regularMaterial)
        .overlay { overlayMenu }
        .ignoresSafeArea()
        .onAppear {
            DispatchQueue.main.async { focus = .search }
        }
        .onChange(of: model.focusRequest.generation) {
            // The target field may be created by the same update; focus it
            // once it exists.
            let field = model.focusRequest.field
            DispatchQueue.main.async { focus = field }
        }
        .onChange(of: focus) { old, new in
            if case let .note(id) = new {
                model.noteFieldFocusChanged(to: id)
            } else if case .note = old {
                model.noteFieldFocusChanged(to: nil)
            }
        }
        .onChange(of: model.store.sessions) {
            model.sessionsChanged()
        }
        .onChange(of: model.store.currentSessionID) {
            model.currentSessionChanged()
        }
        .task(id: model.flash?.generation) {
            guard let generation = model.flash?.generation else { return }
            do {
                try await Task.sleep(for: .seconds(1.8))
            } catch {
                return
            }
            model.clearFlash(generation: generation)
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            if case .notes = model.level, let session = model.shownSession {
                Button {
                    model.backToStacks()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                        Text(session.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("All stacks (←)")
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            TextField(searchPlaceholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focus, equals: .search)
                .disabled(model.inlineEdit != nil || model.overlay != nil)

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            templateButton
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 52)
    }

    private var searchPlaceholder: String {
        switch model.level {
        case .stacks: return "Switch to or create a stack"
        case .notes: return "Search notes"
        }
    }

    private var templateButton: some View {
        Button {
            model.toggleOverlay(.templates)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10, weight: .semibold))
                Text(model.activeProfile.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(model.overlay == .templates ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Template used when copying (⌘P)")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.level {
        case .stacks:
            HStack(spacing: 0) {
                stackColumn
                    .frame(width: stackColumnWidth)
                Divider()
                previewPane
            }
        case .notes:
            notesPane
        }
    }

    private var stackColumn: some View {
        let listing = model.stackListing
        return VStack(spacing: 0) {
            if let undo = model.facts.undo {
                undoBanner(undo)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(listing.sessions.enumerated()), id: \.element.id) { index, session in
                            stackRow(session, position: index)
                                .id(QuickSwitchRow.session(session.id))
                        }
                        if case .createStack = model.inlineEdit {
                            inlineCreateRow
                        } else if let name = listing.creatableName {
                            createRow(name)
                                .id(QuickSwitchRow.create(name))
                        }
                        if listing.isEmpty {
                            Text("No stacks match “\(model.query.trimmingCharacters(in: .whitespaces))”.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: rowHeight)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.stackState.highlight) {
                    guard let highlight = model.stackState.highlight else { return }
                    proxy.scrollTo(highlight, anchor: nil)
                }
            }
        }
    }

    private func undoBanner(_ undo: SessionUndoFacts) -> some View {
        Button {
            model.perform(.undoClear)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
                Text(undo.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Keycap("⌘Z")
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.accentColor.opacity(0.09))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Put the cleared notes back")
    }

    private func stackRow(_ session: SessionItemFacts, position: Int) -> some View {
        let isHighlighted = model.stackState.highlight == .session(session.id)
        var isRenaming = false
        if case let .renameStack(id, _, _) = model.inlineEdit, id == session.id { isRenaming = true }
        return PaletteRow(
            isHighlighted: isHighlighted,
            onSelect: { model.chooseStack(session.id) },
            onActivate: { model.perform(.switchToStack(session.id)) }
        ) {
            HStack(spacing: 10) {
                Image(systemName: session.isCurrent ? "circle.inset.filled" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        isHighlighted
                            ? AnyShapeStyle(Color.white.opacity(session.isCurrent ? 1 : 0.6))
                            : session.isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                    )
                    .frame(width: 14)
                    .accessibilityHidden(true)

                if isRenaming {
                    inlineNameField(field: .rename(session.id), placeholder: "Stack name")
                } else {
                    Text(session.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if session.isCurrent, !isRenaming {
                    Text("Current")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.4)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                isHighlighted
                                    ? Color.white.opacity(0.22)
                                    : Color.accentColor.opacity(0.14))
                        )
                        .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                }

                if position < 9, !isRenaming {
                    Text("⌘\(position + 1)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(isHighlighted ? Color.white.opacity(0.7) : Color.secondary.opacity(0.5))
                }

                Text("\(session.annotationCount)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                    .accessibilityLabel(session.countLabel)
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .frame(height: rowHeight)
    }

    private func createRow(_ name: String) -> some View {
        let isHighlighted = model.stackState.highlight == .create(name)
        return PaletteRow(
            isHighlighted: isHighlighted,
            onSelect: { model.chooseCreateRow(name) },
            onActivate: { model.perform(.createStack(name)) }
        ) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 14)
                    .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                (Text("Create ") + Text("“\(name)”").fontWeight(.semibold))
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Keycap("⌘↩")
                    .opacity(isHighlighted ? 0 : 1)
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .frame(height: rowHeight)
    }

    private var inlineCreateRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 14)
                .foregroundStyle(Color.accentColor)
            inlineNameField(field: .create, placeholder: "New stack name")
            Spacer(minLength: 8)
            Keycap("↩")
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
    }

    private func inlineNameField(field: StackPaletteModel.Field, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(
                placeholder,
                text: Binding(
                    get: { model.inlineText },
                    set: { model.updateInlineText($0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .focused($focus, equals: field)
            if let problem = model.inlineProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Preview (stacks level)

    @ViewBuilder
    private var previewPane: some View {
        if case let .create(name) = model.stackState.highlight {
            placeholder(
                symbol: "plus.rectangle.on.folder",
                title: "Create “\(name)”",
                detail: "Press ↩ to make it and switch to it."
            )
        } else if let session = model.shownSession {
            VStack(spacing: 0) {
                previewHeader(session)
                noteCards(session: session, interactive: false)
            }
        } else {
            placeholder(symbol: "square.stack.3d.up", title: "No stack selected", detail: nil)
        }
    }

    private func previewHeader(_ session: Session) -> some View {
        let count = session.entries.count
        return HStack(spacing: 8) {
            Text(session.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text("\(count) note\(count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            ShortcutHint(keys: "→", label: "Open")
        }
        .padding(.horizontal, 18)
        .frame(height: 36)
    }

    // MARK: - Notes (drilled in)

    @ViewBuilder
    private var notesPane: some View {
        if let session = model.shownSession {
            noteCards(session: session, interactive: true)
        } else {
            placeholder(symbol: "square.stack.3d.up", title: "That stack is gone", detail: nil)
        }
    }

    @ViewBuilder
    private func noteCards(session: Session, interactive: Bool) -> some View {
        let listing = model.noteListing
        let wasCleared = model.facts.undo?.sessionID == session.id
        if session.entries.isEmpty && wasCleared, let undo = model.facts.undo {
            VStack(spacing: 14) {
                placeholder(
                    symbol: "tray",
                    title: "Stack cleared",
                    detail: "\(undo.annotationCount) note\(undo.annotationCount == 1 ? "" : "s") set aside."
                )
                .frame(maxHeight: 180)
                Button {
                    model.perform(.undoClear)
                } label: {
                    HStack(spacing: 6) {
                        Text("Undo Clear")
                        Keycap("⌘Z")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.entries.isEmpty {
            emptyState
        } else if listing.isEmpty {
            placeholder(
                symbol: "magnifyingglass",
                title: "No notes match “\(model.query.trimmingCharacters(in: .whitespaces))”",
                detail: nil
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(listing.entries.enumerated()), id: \.element.id) { index, entry in
                            let position = session.entries.firstIndex(where: { $0.id == entry.id }) ?? index
                            NoteCard(
                                index: position,
                                entry: entry,
                                isHighlighted: interactive && model.highlightedNoteID == entry.id,
                                isEditing: interactive && model.inlineEdit?.noteID == entry.id,
                                interactive: interactive,
                                draft: Binding(
                                    get: {
                                        model.inlineEdit?.noteID == entry.id ? model.inlineText : entry.note
                                    },
                                    set: { model.updateInlineText($0) }
                                ),
                                focus: $focus,
                                onSelect: { model.chooseNote(entry.id) },
                                onDelete: { model.perform(.deleteNote(entry.id)) }
                            )
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                .onChange(of: model.highlightedNoteID) {
                    guard let id = model.highlightedNoteID else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: nil)
                    }
                }
                .onAppear {
                    if let id = model.highlightedNoteID { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "quote.opening")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)

            VStack(spacing: 5) {
                Text("Nothing captured yet")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 5) {
                    Text("Hold")
                    Keycap(VoiceModifierShortcut.displayString, size: 12)
                    Text("to speak and release to save, or tap it once to start and again to save")
                }
                HStack(spacing: 5) {
                    Text("Or press")
                    Keycap(model.settings.captureCombo.displayString, size: 12)
                    Text("to type a note about selected text")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(symbol: String, title: String, detail: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.quaternary)
            VStack(spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let flash = model.flash {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(flash.text)
                }
                .font(.caption.weight(.medium))
                .transition(.opacity)
            } else {
                Text(footerContext)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let primary = model.primaryAction {
                Button {
                    model.perform(primary.action)
                } label: {
                    HStack(spacing: 6) {
                        Text(primary.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Keycap(primary.keys)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 14)

            Button {
                model.toggleOverlay(.actions)
            } label: {
                HStack(spacing: 6) {
                    Text("Actions")
                        .font(.system(size: 12, weight: .medium))
                    Keycap("⌘K")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .animation(.easeOut(duration: 0.15), value: model.flash?.generation)
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private var footerContext: String {
        switch model.level {
        case .stacks:
            let count = model.facts.sessions.count
            return "\(count) stack\(count == 1 ? "" : "s") · ↑↓ move · → open · esc close"
        case .notes:
            let count = model.shownSession?.entries.count ?? 0
            let name = model.shownSession?.name ?? ""
            return "\(name) · \(count) note\(count == 1 ? "" : "s") · ↑↓ move · ⌥↑↓ reorder · ← back"
        }
    }

    private func errorRow(_ error: AnnotationStoreError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(annotationStoreErrorMessage(error))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if model.store.hasPendingMutations {
                Button("Retry") { model.store.retryPendingMutations() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Overlay menus

    @ViewBuilder
    private var overlayMenu: some View {
        if let overlay = model.overlay {
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeOverlay() }
                Group {
                    switch overlay {
                    case .actions: actionsMenu
                    case .templates: templatesMenu
                    }
                }
                .padding(.trailing, 12)
                .padding(.bottom, 44)
            }
            .transition(.opacity)
        }
    }

    private var actionsMenu: some View {
        let items = model.filteredActionItems
        return OverlayPanel(
            title: "Actions",
            emptyText: "No matching actions",
            isEmpty: items.isEmpty,
            query: $model.overlayQuery,
            focus: $focus
        ) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isHighlighted = index == model.overlayHighlight
                OverlayRow(isHighlighted: isHighlighted, onHover: { model.setOverlayHighlight(index) }) {
                    model.perform(item.action)
                } content: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            if let subtitle = item.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.75) : Color.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Keycap(item.keys)
                    }
                    .foregroundStyle(
                        isHighlighted ? Color.white : item.isDestructive ? Color.red : Color.primary)
                }
            }
        }
    }

    private var templatesMenu: some View {
        let profiles = model.filteredProfiles
        return OverlayPanel(
            title: "Copy with template",
            emptyText: "No matching templates",
            isEmpty: profiles.isEmpty,
            query: $model.overlayQuery,
            focus: $focus
        ) {
            ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                let isHighlighted = index == model.overlayHighlight
                let isActive = profile.id == model.settings.activeProfileID
                OverlayRow(isHighlighted: isHighlighted, onHover: { model.setOverlayHighlight(index) }) {
                    model.selectProfile(profile.id)
                } content: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 12)
                            .opacity(isActive ? 1 : 0)
                        Text(profile.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if profile.clearSessionAfterExport {
                            Text("clears after copy")
                                .font(.system(size: 10))
                                .foregroundStyle(isHighlighted ? Color.white.opacity(0.75) : Color.secondary)
                        }
                    }
                    .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                }
            }
        }
    }
}

// MARK: - Pieces

/// A palette row: flat by default, accent-filled when highlighted. One click
/// highlights it, a second click on the same row runs it.
private struct PaletteRow<Content: View>: View {
    let isHighlighted: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isHighlighted
                            ? Color.accentColor
                            : Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { onActivate() }
            .onTapGesture { onSelect() }
    }
}

/// One captured passage with its note, drawn the same whether previewed or
/// opened; only the opened card takes a highlight and edits.
private struct NoteCard: View {
    let index: Int
    let entry: SendpointDomain.Annotation
    let isHighlighted: Bool
    let isEditing: Bool
    let interactive: Bool
    @Binding var draft: String
    var focus: FocusState<StackPaletteModel.Field?>.Binding
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var quote: String {
        guard case let .selection(quote) = entry.subject else { return "" }
        return quote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(
                        Circle().fill(isHighlighted ? Color.accentColor : Color.accentColor.opacity(0.12)))

                Text(entry.provenance.application.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let window = entry.provenance.windowTitle?.nonblank {
                    Text(window)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if entry.provenance.url != nil, interactive {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .help("Open source (⌘O)")
                }

                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                if interactive {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .help("Delete note (⌘⌫)")
                    .accessibilityLabel("Delete note \(index + 1)")
                    .opacity(hovering || isHighlighted ? 1 : 0)
                }
            }

            if !quote.isEmpty {
                HighlightedPassage(text: quote)
            }

            if interactive {
                TextField(
                    quote.isEmpty ? "Write a thought…" : "Add a note about this passage…",
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.body)
                .lineSpacing(2)
                .lineLimit(1...8)
                .focused(focus, equals: .note(entry.id))
            } else if let note = entry.note.nonblank {
                Text(note)
                    .font(.body)
                    .lineSpacing(2)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No note")
                    .font(.body)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isEditing
                        ? Color.accentColor.opacity(0.9)
                        : isHighlighted ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                    lineWidth: isHighlighted || isEditing ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { if interactive { onSelect() } }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isHighlighted)
    }
}

/// A captured passage drawn the way a highlighter marks a page: the tint
/// follows the lines of text instead of boxing them.
private struct HighlightedPassage: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(marked)
            .font(.callout)
            .lineSpacing(5)
            .lineLimit(6)
            .foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var marked: AttributedString {
        var attributed = AttributedString(text)
        attributed.backgroundColor = colorScheme == .dark
            ? Color(red: 1.0, green: 0.80, blue: 0.25).opacity(0.28)
            : Color(red: 1.0, green: 0.86, blue: 0.30).opacity(0.5)
        return attributed
    }
}

/// The floating menu in the corner: a list of rows and a filter field below
/// them, the way Raycast lays out its action panel.
private struct OverlayPanel<Rows: View>: View {
    let title: String
    let emptyText: String
    let isEmpty: Bool
    @Binding var query: String
    var focus: FocusState<StackPaletteModel.Field?>.Binding
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 1) {
                    rows()
                    if isEmpty {
                        Text(emptyText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused(focus, equals: .overlay)
                Keycap("esc")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}

private struct OverlayRow<Content: View>: View {
    let isHighlighted: Bool
    let onHover: () -> Void
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHighlighted ? Color.accentColor : Color.clear)
        )
        .onHover { if $0 { onHover() } }
    }
}
