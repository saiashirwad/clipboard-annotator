# Clipboard Annotator: Sessions, Provenance, and Prompt Profiles

## Status

Migration specification. Native sessions, standalone capture, transactional persistence, voice lifecycle safety, and asynchronous provenance are implemented. Prompt profiles and first-run setup remain future work.

## Changes since the verbal design sign-off

This specification makes five deliberate refinements to the earlier sketch. They are called out here so review does not silently approve changed decisions:

1. **`Provenance` is one general record, not a browser/terminal/application sum type.** Those categories describe the first detection strategies, not the underlying data. Every source is an application; a known-app enricher may add a URL or working directory. Unknown apps still produce useful app identity and window-title provenance. The single capture timestamp remains on `Annotation`, so it is not duplicated.
2. **The first implementation requires Ghostty and Helium enrichers only.** Earlier discussion named Chrome, Arc, Safari, iTerm, Terminal, and kitty as possible strategies. The registry stays easy to extend, but this pass implements the two apps that motivated the feature. Unknown apps use the generic Accessibility fallback rather than failing.
3. **The rendered preview does not use `swift-markdown-ui`.** Conditional approval depended on confirming that the package would not slow builds. No dependency can guarantee zero cold-build cost, and this app already owns a narrow structured output format. The specification renders that model directly in SwiftUI and uses native `AttributedString(markdown:)` for inline formatting. This delivers a polished preview without a parser dependency. Full arbitrary Markdown rendering remains a later option.
4. **`clearSessionAfterPaste` is named `clearSessionAfterExport`.** The action may copy without directly pasting, so the broader name matches when clearing actually occurs: after a successful pasteboard write. The user-facing control says `Clear the current session after copying or pasting`.
5. **The voice overlay is now part of the state-modeling work.** Releasing the hold shortcut before recording starts must cancel cleanly instead of leaving an undismissable warning pill. The overlay also gets a smaller visual redesign, explicit task ownership, reliable Escape cancellation, and automatic dismissal of terminal failures.

## Product statement

Clipboard Annotator should let a person keep reading without opening a side investigation. They select a passage or capture a standalone thought, speak or type a note, and keep going. The app records where the thought came from. Later, it turns the active session into a shaped prompt and copies or pastes it into another app.

The core loop is:

> Capture out loud, stamp where you were, fire a shaped prompt.

The app remains a small macOS menu-bar utility. There is no persistent screen bubble.

## Goals

1. Support named annotation sessions. Switching sessions must never discard another session's entries.
2. Support notes about selected text and standalone thoughts with no selection.
3. Stamp each annotation with best-effort application provenance and optional enriched context.
4. Detect the active Ghostty tab's title and working directory.
5. Detect the active Helium tab's title and URL.
6. Keep provenance work outside the capture UI's critical path.
7. Support named prompt profiles with a customizable preamble and fixed formatting toggles.
8. Inject the active profile's preamble once at the start of every copied or pasted prompt.
9. Allow a profile to clear the current session after a successful export while retaining undo.
10. Show a polished, rendered prompt preview without adding a Markdown rendering dependency.
11. Move all app-owned observable state from `ObservableObject`/`@Published` to Swift Observation's `@Observable` model. Do not mix the two systems.
12. Keep typed capture first-class while treating voice capture as the main path.
13. Keep builds fast and the implementation small enough to understand.
14. Make the voice overlay smaller, visually refined, and impossible to strand in a terminal state.
15. Provide a polished first-run setup window and a focused helper window for permissions that require System Settings.

## Non-goals

- Bookmarks, screenshots, image storage, and Screen Recording permission.
- A persistent floating bubble.
- Raycast, CLI, or automation commands for switching sessions.
- Automatic routing from an app, URL, or directory to a session.
- WYSIWYG Markdown editing.
- A freeform layout/template language such as `{{quote}}` placeholders.
- iCloud sync, SwiftData, Core Data, SQLite, or GRDB.
- Backward compatibility with the existing `stack.json` format or old settings keys.
- General browser support beyond Helium in the first implementation.
- A note-format instruction for `AGENTS.md` or `CLAUDE.md`; the prompt preamble carries that instruction on every export.
- A plugin framework or protocol hierarchy for provenance adapters. A small bundle-ID registry is enough.
- The Composable Architecture dependency or a partial TCA architecture.
- Input Monitoring permission while global shortcuts continue to use Carbon-compatible registration.

Bookmarks may become a separate product later. The provenance types should be reusable by it, but this implementation must not add bookmark abstractions, screenshot fields, attachment types, or speculative storage code.

## Terminology

- **Session:** A named working context, such as "CEK machines" or "Default".
- **Stack:** The ordered annotations inside one session.
- **Annotation:** One captured note.
- **Selection annotation:** An annotation about highlighted text.
- **Standalone annotation:** A thought captured with no highlighted text.
- **Provenance:** The recorded origin of an annotation: application, page or terminal context, and location.
- **Profile:** A named set of prompt text, formatting flags, and export behavior.
- **Export:** Building Markdown and placing it on the system clipboard. Export may then paste the clipboard into the frontmost app.

"Session" is intentional. "Queue" would imply ordered, one-at-a-time consumption. The app collects and exports the whole stack.

## Product behavior

### Capture

The existing shortcuts remain conceptually unchanged:

- Capture shortcut: read the current selection, show the note panel, and accept plain text.
- Hold-to-record shortcut: read the current selection, record while held, transcribe locally, and save the transcript.

Both paths support a missing selection:

- Non-empty selected text produces `.selection(quote:)`.
- Missing or whitespace-only selected text produces `.standalone`.
- A standalone capture omits the quote surface and shows only the note input or voice status.
- The note/transcript must contain non-whitespace text before an annotation can be saved.
- A selection without a note is not an annotation. This app records thoughts, not plain bookmarks.

The note editor stays a plain, vertically growing text field. It may contain Markdown syntax as text, but it does not render formatting while editing.

### Sessions

- The first launch creates one session named `Default` and selects it.
- The menu bar exposes a `Session` submenu.
- The submenu shows all sessions, with a checkmark beside the current session.
- It also provides `New Session…`, `Rename Current Session…`, and `Delete Current Session…`.
- The stack window includes the same session picker and management actions.
- Creating a session requires a non-empty name.
- Session names are unique after trimming whitespace and comparing case-insensitively.
- Switching sessions changes only `currentSessionID`.
- The status-item count and all capture, clear, copy, paste, list, and preview actions operate on the current session.
- Deleting the final session is not allowed. If a design later permits it, the store must create and select a fresh `Default` session in the same mutation.
- Deleting a non-empty session requires confirmation because it is not the same as clearing and is not covered by clear undo.

### Clear and undo

- `Clear` clears only the current session.
- The store retains one last cleared batch with its originating `sessionID`.
- Undo restores that batch to its original session even if another session is now active.
- Menu copy should say which session will be restored when it is not the current one, for example `Undo Clear in CEK machines (7)`.
- A later clear replaces the prior undo batch, matching the current one-level undo behavior.

### Profiles

Profiles are presets backed by fixed controls. They are not a template language.

Each profile contains:

- Name.
- Custom preamble text.
- Include heading.
- Include application name.
- Include window title.
- Include link or working directory.
- Include timestamps.
- Clear current session after export.

The rough design called the last field `clearSessionAfterPaste`. The implementation should call it `clearSessionAfterExport`, because the same command may only copy when direct paste is disabled. The user-facing label should be `Clear the current session after copying or pasting`.

The active profile is global, not per session. The menu bar exposes a `Profile` submenu with a checkmark beside the active profile. Profile creation and editing live in Settings, not in the menu.

#### Draft editing

Profile controls edit a draft, not the stored profile directly.

- Selecting a profile in the editor copies it into a draft.
- `draft != storedProfile` marks the editor dirty.
- A dirty editor offers `Save to “<name>”`, `Save as New…`, and `Revert`.
- Switching the profile being edited while dirty requires an explicit Save, Save as New, Discard, or Cancel choice.
- `Save as New…` requires a unique, non-empty name and assigns a new UUID.
- Built-in profiles may be edited and overwritten; there is no protected-default machinery.
- At least one profile must exist.
- Deleting the active profile selects another existing profile atomically.

#### Default profiles

Ship three profiles:

1. **Coherent** — active by default.
   - Heading: on.
   - Application, window title, and link or working directory: on.
   - Timestamps: on.
   - Clear after export: off.
   - Preamble:

     > These are my reading notes, captured in order while I read. Each entry is either a response to a quoted passage or a standalone thought. Read the notes as a whole and give me one coherent response that takes all of them into account. Restate enough context to make each part of your response understandable without requiring me to scroll back. Do not respond point by point unless the notes ask you to.

2. **Point by Point**
   - Heading: on.
   - Application, window title, and link or working directory: on.
   - Timestamps: on.
   - Clear after export: off.
   - Preamble:

     > These are my reading notes, captured in order while I read. Each entry is either a response to a quoted passage or a standalone thought. Address each note separately. Before answering a note, restate the relevant topic or quoted idea in a few words so I never need to look up an entry number.

3. **Plain**
   - Empty preamble.
   - Heading: off.
   - Application, window title, and link or working directory: off.
   - Timestamps: off.
   - Clear after export: off.

The preamble appears once at the top of every exported prompt. It is not repeated before every annotation.

### Export and direct paste

- Build the complete Markdown string from the current session and active profile.
- Write it to `NSPasteboard.general` first.
- Treat a successful pasteboard write as a successful export.
- If direct paste is on, synthesize paste after the current delay used by the app.
- If `clearSessionAfterExport` is on, clear the current session only after the pasteboard write succeeds.
- Clearing must populate `lastCleared`, so undo remains available.
- The clipboard retains the exported prompt after the session clears.
- An empty session cannot export and should beep or show the current restrained status feedback.
- A failed pasteboard write must not clear anything.

The existing app already has `includeSource`, `includeHeading`, and `clearAfterCopy`. Replace those global settings with profile fields in a clean cutover. Do not keep aliases or dual behavior.

## Data model

Use Swift enums with associated values for closed alternatives. The compiler should make invalid states hard to construct.

```swift
import Foundation

struct ApplicationIdentity: Codable, Hashable {
    var name: String
    var bundleID: String?
}

enum Subject: Codable, Hashable {
    case selection(quote: String)
    case standalone
}

struct Provenance: Codable, Hashable {
    var application: ApplicationIdentity
    var windowTitle: String?
    var url: URL?
    var workingDirectory: URL?
}

struct Annotation: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var subject: Subject
    var note: String
    var provenance: Provenance
    var createdAt: Date = Date()
}

struct Session: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var entries: [Annotation] = []
    var createdAt: Date = Date()
}

struct Profile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var preamble: String
    var includeApplication: Bool
    var includeWindow: Bool
    var includeLink: Bool
    var includeTimestamps: Bool
    var includeHeading: Bool
    var clearSessionAfterExport: Bool
}

struct ClearedBatch: Codable, Hashable {
    var sessionID: Session.ID
    var entries: [Annotation]
}

struct StoreDocument: Codable {
    var version: Int = 1
    var sessions: [Session]
    var currentSessionID: Session.ID
    var lastCleared: ClearedBatch?
}
```

### Model decisions

- The model case is `.standalone`, matching the explicit state. UI copy may say `Standalone thought`.
- `Subject` describes what the note is about. `Provenance` describes where it came from.
- `Provenance` has no source category. Every capture comes from an application; known-app enrichment may add a URL, a working directory, or both.
- The optional enrichment fields are not a bag of mutually exclusive states. They are independent facts. A future app may legitimately expose both a URL and a local working directory.
- `ApplicationIdentity.bundleID` is optional because `NSRunningApplication.bundleIdentifier` is optional.
- Use `URL` for both web and file locations. Do not store either as an unvalidated string.
- `Annotation.createdAt` is the capture-trigger time, not the later save time. Do not duplicate the timestamp inside `Provenance`.
- `Provenance` is always present. Build the generic application baseline synchronously at capture time; asynchronous work only enriches it.
- Do not add a `kind` discriminator. Export formatting should inspect the facts that exist, not infer a browser or terminal class.

## Persistence

### Session data

Persist one `StoreDocument` as JSON at:

```text
~/Library/Application Support/ClipboardAnnotator/store.json
```

Requirements:

- Encode dates with ISO 8601.
- Write atomically after every successful store mutation.
- Keep all sessions in one document. They contain small text records, and atomic cross-session changes matter more than file-level separation.
- Ignore the existing `stack.json`; no migration is required.
- Do not silently overwrite a malformed current-format `store.json`. Preserve it with a timestamped `.corrupt` suffix, log the decode error, and start a fresh document.
- Reject an unknown future `version` rather than decoding it as version 1.
- Keep `version` even though version 1 has no migration code. Future migrations should decode the old version into an old Codable type, transform it in memory, and write the current document.

### Settings

`AppSettings` remains the owner of machine and behavior configuration:

- Profiles encoded as `Data` in `UserDefaults`.
- `activeProfileID` in `UserDefaults`.
- Direct-paste setting.
- Restore-focus-after-save setting.
- Launch-at-login setting.
- Shortcut settings, subject to the KeyboardShortcuts decision below.

Do not put profiles or the active profile pointer in `StoreDocument`.

No compatibility code is required for the old `includeSource`, `includeHeading`, or `clearAfterCopy` keys.

## Provenance detection

### Boundary and fallback

Detection uses one generic baseline plus a small registry of optional enrichers. Do not build a plugin system or class hierarchy.

Conceptual shape:

```swift
struct ProvenanceEnrichment {
    var windowTitle: String?
    var url: URL?
    var workingDirectory: URL?
}

struct ProvenanceProbe {
    typealias Enricher = @Sendable (CapturedApplication) async throws -> ProvenanceEnrichment

    private let enrichersByBundleID: [String: Enricher]

    func probe(_ target: CapturedApplication) async -> Provenance
}
```

`probe` always begins with application identity and a generic Accessibility window-title lookup. It then looks up the captured bundle ID:

- Known bundle ID: run the registered enricher and merge its non-nil facts.
- Unknown bundle ID: return the generic baseline.
- Enricher failure or permission denial: return the generic baseline.

This is the extensible boundary. Adding Chrome later is one registry entry plus an enrichment function, or another bundle ID pointing at a shared Chromium enrichment function. It does not require a new provenance case, export branch, persistence shape, or profile type.

Call these functions `enrichGhostty` and `enrichHelium`, not “terminal adapter” and “browser adapter.” The functions are app-specific strategies; the stored data is not classified by app category.

### Required enrichers

#### Ghostty

Target Ghostty through Accessibility by the captured process identifier, not by whichever app is frontmost after the panel opens.

Read:

- `AXTitle` from the focused window.
- `AXDocument` from the focused window and parse it as a file URL.

Merge the title and working-directory URL into the generic provenance. If `AXDocument` is unavailable, retain the generic application identity and any window title. Only the focused native tab needs detection; background Ghostty tabs do not need enumeration.

#### Helium

Use an in-process Apple Event or `NSAppleScript`; do not launch `/usr/bin/osascript` for each capture. Query the title and URL of Helium's active tab in its front window.

Merge the title and parsed URL into generic provenance. If Automation permission is denied, Helium is absent, the event fails, or the URL does not parse, retain the generic baseline.

#### Other applications

Use the captured process identifier and Accessibility to read the focused window title when possible. No app-specific enrichment is required. Chrome therefore still produces its application name and window title in this pass; it simply lacks the active-tab URL until a Chrome enricher is registered.

Do not add Chrome, Safari, Arc, iTerm, Terminal, or kitty-specific enrichers in this pass.

### Performance, ownership, and cancellation

Provenance must never delay panel presentation or recording.

1. At shortcut time, capture the target application's identity and process identifier before activating any Clipboard Annotator panel.
2. Set `Annotation.createdAt` at that moment.
3. Create one provenance `Task` owned by that capture lifecycle. Never use `Task.detached`.
4. Present the note or voice UI without awaiting the task.
5. Save the annotation immediately when the note/transcript is ready, using the best result then available.
6. If enrichment finishes after save, update that annotation by UUID in its original session. Do not route it into whichever session is active later.
7. On cancel or dismissal, cancel the owned task and clear its handle.
8. Enrichers must call `Task.checkCancellation()` before and after Accessibility or Apple Event work.
9. If a system API does not stop promptly when cancellation is requested, discard its eventual result by checking cancellation and the capture identity before any store mutation.
10. A failed or cancelled task never removes an annotation or mutates a later capture.

Swift `Task` cancellation is cooperative; a task is not a dedicated thread. The event-driven panel lifecycle does not fit a single lexical `async let` scope, so retaining one ordinary task handle and cancelling it explicitly is the correct structured ownership here.

The target record needs at least `sessionID`, `annotationID`, application identity, process identifier, and a capture identity/token. Do not infer the target from current global state after capture starts.

Provenance logging must omit selected text, note text, and full URLs. Log only enricher name, success/failure, and elapsed time.

## Setup and permissions

### First-run setup window

Add a dedicated first-run setup window, visually similar in density and clarity to the supplied Hex reference without copying its layout or styling. It is a real app window or sheet, not a series of alerts.

Show:

- A short statement that notes, audio, transcription, and provenance remain on this Mac.
- Accessibility — required to read selections and paste.
- Microphone — required for voice capture.
- Local speech model — required for local transcription.
- Helium Automation — optional provenance enrichment, shown when Helium is installed.

Each row includes:

- Plain-language reason.
- Live status.
- One direct action such as `Grant Access`, `Download Model`, or `Open Settings`.
- A completed state that cannot be mistaken for a disabled button.

Accessibility is the only requirement for the basic typed workflow. Let the user finish with a clear `Use Text Capture for Now` path when microphone access or the speech model is not ready. Do not trap the user in setup.

Persist `hasCompletedSetup` in `AppSettings`. Show setup automatically on first launch, provide `Run Setup Again…` from Settings, and do not force it open on every launch after a permission is later revoked. Settings should continue to show revoked states.

### System Settings helper window

Some TCC grants require manual work in System Settings. When the app opens the Accessibility privacy pane, also show a small separate helper window that remains visible beside System Settings:

- Name the exact permission.
- Give no more than three concrete steps.
- Show the Clipboard Annotator app icon/name where useful.
- Poll or refresh the real grant status.
- Close itself when access is granted.
- Offer a manual close action.

This helper must explain the real system UI rather than imitate it. It cannot claim to toggle the permission itself.

Input Monitoring is not required by the current Carbon global-hotkey path and must not appear in setup. Do not ask for a privacy-sensitive grant merely because another dictation app does. If a future shortcut implementation uses an event tap that genuinely requires Input Monitoring, add that permission and its matching helper then.

### Settings permission section

Mirror setup status in Settings:

- Accessibility.
- Microphone.
- Local speech model.
- Helium Automation, when Helium is installed.

Provide a guided `Set Up Permissions…` action that reopens the setup window.

Permission actions:

1. Request Accessibility through the existing system API and offer the System Settings helper when manual action remains.
2. Request microphone access through the system dialog.
3. Download the local speech model with visible progress and recoverable failure.
4. Send a benign Helium Apple Event when Helium is installed, provoking its separate Automation prompt.
5. Refresh displayed state when the app becomes active again.

macOS controls these grants separately; the UI must not claim there is one combined permission.

Update `NSAppleEventsUsageDescription` to say that the app reads the active browser tab's title and URL to record where an annotation came from. The current description only mentions selected text and is no longer accurate.

Do not request Screen Recording or Input Monitoring permission.

## Observation migration

Use Swift Observation across the entire app-owned state layer because the deployment target is macOS 14 and the installed toolchain supports it.

Convert these state owners:

- `AnnotationStore`.
- `AppSettings`.
- `CaptureModel`.
- `VoiceCaptureModel`.
- Any new profile draft or permission-state model.

Rules:

- Mark state-owning reference types with `@Observable`.
- Remove `ObservableObject`, `@Published`, and view-level `@ObservedObject`/`@StateObject` uses.
- Use `@Bindable` only where a SwiftUI control needs a binding to an observable model's property.
- Plain utility types such as a stateless `PermissionCheck` enum do not become observable merely for consistency. Put changing permission values in a separate observable state model.
- Remove Combine imports that become unused.
- Do not use two observation systems in parallel.

`@Observable` does not expose Combine publishers. Replace the AppDelegate's current `$entries` and `$lastCleared` subscriptions with explicit store-change callbacks from successful mutation boundaries. Use the same direct callback style already used for hotkey changes. SwiftUI views should rely on Observation tracking; AppKit menu rebuilding should rely on callbacks.

Add a project `AGENTS.md` during implementation with these durable Swift rules:

- Use Swift Observation for app-owned state; never mix `ObservableObject`/`@Published` with `@Observable`.
- Never use `Task.detached` for work owned by a capture, panel, window, or feature lifecycle.
- Retain lifecycle task handles, cancel them during teardown, and clear them.
- Treat cancellation as cooperative: check it before and after external calls, then validate capture identity before mutating state.
- Keep UI state on `@MainActor`.
- Prefer explicit state transitions and one idempotent teardown path over scattered boolean guards.
- Keep pure formatting and persistence transformations outside views and test them directly.

## Architecture decision: do not adopt TCA

Do not add [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) in this implementation.

TCA would provide real benefits: reducers make state transitions explicit, effects have cancellation identities, dependencies become replaceable, and `TestStore` supports deterministic transition tests. The voice lifecycle is the strongest local case for it.

The cost is disproportionate here:

- Clipboard Annotator is a small menu-bar app with a few state owners, two panels, and limited navigation.
- A coherent TCA adoption would replace the store, capture controller, AppDelegate event routing, view bindings, asynchronous tasks, dependency access, and tests. Using TCA for only voice or provenance would leave two state architectures in one small codebase.
- The current TCA release at review time (`1.26.2`) declares `swift-tools-version: 6.4`, while the installed toolchain is Swift `6.3.3`. Adoption would require a toolchain upgrade or pinning an older release such as `1.25.2`.
- TCA brings a broad dependency graph, including collections, schedulers, case paths, clocks, concurrency helpers, custom dump, dependency management, identified collections, issue reporting, navigation, perception, sharing, and macro/SwiftSyntax targets. That works against the stated fast-build priority.

Use the useful architectural ideas without the dependency:

- Closed state enums.
- Explicit event-to-transition methods.
- Pure prompt composition.
- Injected filesystem, pasteboard, and provenance boundaries in tests.
- Lifecycle-owned tasks with cancellation.
- Identity checks before late asynchronous mutations.

Reconsider TCA if the app later develops several independently navigable features with deeply shared state, complex presentation trees, or enough asynchronous effects that the native store becomes hard to test. If that threshold is reached, migrate the whole state layer as one architecture change rather than introducing TCA piecemeal.

## UI specification

### Menu bar

Keep the existing icon and current-session annotation count.

Recommended order:

1. `Capture` action.
2. `Session` submenu.
3. `Profile` submenu.
4. `Show Stack…`.
5. Separator.
6. `Paste/Copy <n> Annotations as Markdown`.
7. `Clear Current Session`.
8. Conditional undo item.
9. Separator.
10. `Settings…`.
11. `Quit`.

The status-item tooltip should name the active session and profile. Do not put their full names beside the icon; the menu bar should remain quiet.

### Capture panel

- Keep the current small floating panel and keyboard behavior.
- Show a truncated quote surface for `.selection`.
- Omit the quote surface for `.standalone`.
- Keep a plain text note editor.
- Preserve Escape to cancel and Command-Return to save.
- Preserve support for external dictation tools.
- Do not expose session or profile selectors inside the capture panel; switching remains a menu/stack concern.

### Voice panel

The current overlay can enter a stranded failure state when the user releases the hold shortcut before recording has started. `endVoiceCapture` sees that the recorder is not active and returns; the start task then notices that the key is no longer held, sets `.failed`, and leaves the panel open. Fix the lifecycle, not only the warning view.

Use a small explicit state machine:

```swift
enum VoiceCaptureState: Equatable {
    case starting
    case recording
    case transcribing
    case failed(String)
}
```

Cancellation is an action that tears down the capture; it does not need a persistent visible state.

Required transitions:

- Press: create the lifecycle, start recording work, show `.starting`.
- Recording begins while held: `.starting -> .recording`.
- Release during `.recording`: `.recording -> .transcribing`.
- Release during `.starting`: cancel and dismiss immediately. This is not an error.
- Escape during any state: cancel all owned work, discard recording, and dismiss immediately.
- Empty transcript or transcription error: show `.failed` briefly, then dismiss automatically.
- A new voice gesture must not revive or receive results from a prior cancelled lifecycle.

Route every cancel path through one idempotent `cancelVoiceCapture(returnFocus:)` function. It cancels the start, finish, and provenance tasks; discards any recording; removes monitors; hides the panel; clears models and task handles; and restores focus at most once.

Preserve hold-to-record behavior for both `.selection` and `.standalone`. Provenance probing runs concurrently and must not alter waveform or transcription state.

Redesign the overlay as a much smaller, cleaner recording indicator:

- Target at most about 120 points wide and 36 points high in its normal state.
- Use a restrained material surface, compact waveform or level bars, and one clear recording accent.
- Avoid text in normal recording state.
- Let a failure state expand only as much as needed for a short message.
- Keep motion subtle and driven by real audio state; no decorative looping animation.
- Study WhisperFlow, Superwhisper, and Hex before implementation for density, placement, and state communication. Record observations, then design an original component rather than copying one.
- Verify at standard and Retina scale, near a text selection and near the pointer fallback position.

The panel must never require relaunching the app to disappear.

### Stack window

The stack window operates on the current session and includes:

- Session picker.
- New, rename, and delete session actions.
- Existing reorder, edit, and remove actions scoped to the session.
- Active profile indication.
- A rendered prompt preview that reflects the active profile.
- Copy/paste and clear actions whose labels name the current session when useful.

#### Rendered preview without a package

Do not add `swift-markdown-ui` in this pass. Any package adds cold-build work, and this app owns a small, structured prompt format. Render the prompt directly from `Session`, `Annotation`, `Subject`, `Provenance`, and `Profile` using SwiftUI:

- Preamble as normal body text.
- Date heading with heading typography.
- Entry numbers as subheadings.
- Selection quotes in an inset quote surface.
- Notes as body text.
- Provenance as secondary metadata.

For inline Markdown inside a note, attempt `AttributedString(markdown:)` and fall back to plain `Text` if parsing fails. Do not implement arbitrary block Markdown parsing. This provides the requested polished preview with no dependency and no WYSIWYG editor.

The copied string remains real Markdown generated by the exporter; the preview is a structured visual equivalent, not a parser round-trip.

### Settings

Use a custom but restrained SwiftUI layout rather than accepting stock `Form` appearance as the final design. Reuse and extend the small visual primitives in `Chrome.swift`.

Sections:

1. Profiles: active profile picker, profile editor, preamble field, formatting toggles, clear-after-export toggle, dirty actions.
2. Shortcuts.
3. Capture behavior: direct paste and restore focus.
4. Permissions.
5. Voice model status and download action.
6. Launch at login.

Design requirements:

- Native typography and spacing.
- One quiet accent color through `.tint`.
- Clear section hierarchy without decorative cards around every row.
- Full keyboard access and VoiceOver labels.
- No gradients, oversized headings, custom window chrome, or persistent animation.

## Markdown export format

The exporter owns one stable layout. Profiles only include or omit sections; users do not author the layout.

Order:

1. Non-empty profile preamble.
2. Optional date heading.
3. An ordered entry section for each annotation.

Selection entry:

```markdown
## 1

> Selected text, with every line prefixed as a Markdown quote.

The note.

_Helium · Page title · https://example.com · 5:14 PM_
```

Standalone entry:

```markdown
## 2

The standalone thought.

_Ghostty · /Users/name/project · Window title · 5:15 PM_
```

Rules:

- Do not emit an empty quote block for `.standalone`.
- Keep entry numbering even for standalone notes.
- Escape or correctly prefix multiline quote content.
- Heading text remains `Reading notes — <localized long date>` when enabled.
- Provenance metadata uses one stable fact order: application name, optional window title, optional URL, optional abbreviated working-directory path, optional timestamp.
- Emit every available enabled fact without classifying the source as a browser, terminal, or generic app.
- `includeApplication`, `includeWindow`, and `includeLink` independently control application, window-title, and URL/directory facts.
- `includeTimestamps` controls the time independently. If all source facts are off but timestamps are on, emit a metadata line containing only the time.
- Never emit empty separators or a blank metadata line.

## Keyboard shortcut library

A later cleanup in the same implementation may replace `HotKeyCenter`, `KeyCombo`, and `KeyRecorder` with Sindre Sorhus's `KeyboardShortcuts` package, but only after proving all existing behavior:

- Global key-down capture.
- Distinct key-down/key-up callbacks for hold-to-record.
- Rebindable recorder controls in Settings.
- Disabled/invalid shortcut handling.
- Shortcut display in menu items.
- Persistence across launches.

Perform this as a separate commit or milestone after sessions, provenance, and profiles work. If the library cannot preserve press-and-hold voice semantics without custom event code, keep the current Carbon implementation and do not run two global-hotkey systems together.

## Store and service API responsibilities

### `AnnotationStore`

Own:

- Current `StoreDocument`.
- Computed current session and current entries.
- Session create, rename, switch, delete.
- Annotation add, update, remove, reorder.
- Clear and undo.
- Atomic persistence.
- Mutation callbacks for AppKit menu updates.

Do not let views edit session arrays directly.

### `PromptComposer`

Extract Markdown generation from the store into a pure value/service:

```swift
struct PromptComposer {
    func markdown(session: Session, profile: Profile) -> String
}
```

This keeps formatting testable and prevents the store from reaching into global `AppSettings`.

### `ProvenanceProbe`

Own enricher selection and asynchronous enrichment. It must not own UI or persistence. It receives a captured app target and returns the generic provenance with any available extra facts merged in.

### `AppSettings`

Own profiles, active-profile selection, machine settings, and persistence to `UserDefaults`. It must not own annotation data.

### Capture controller

Own the lifecycle connection among selection capture, session snapshot, annotation UUID, provenance task, note/voice UI, and eventual store update.

## File-level change map

### New files

- `Subject.swift` — `Subject` sum type.
- `Provenance.swift` — `ApplicationIdentity` and `Provenance`.
- `Session.swift` — `Session`, `ClearedBatch`, and `StoreDocument` if kept together.
- `Profile.swift` — profile model and built-in defaults.
- `PromptComposer.swift` — pure Markdown composition.
- `ProvenanceProbe.swift` — target snapshot, generic baseline, and bundle-ID enricher dispatch.
- `PermissionState.swift` — observable permission values and refresh/request orchestration.
- `SetupView.swift` — first-run setup checklist.
- `PermissionHelpWindow.swift` — focused instructions shown alongside System Settings.
- Test files under a new `Tests/ClipboardAnnotatorTests` target.

Do not split tiny related types into separate files merely to satisfy this list. A cohesive `Models.swift` is acceptable if it stays easy to scan. Prefer the repository's existing simple structure over a new folder hierarchy.

### Existing files

- `Annotation.swift` — replace flat `quote/sourceApp/sourceURL` fields with `subject` and `provenance`.
- `AnnotationStore.swift` — sessions, current pointer, one-level undo, new persistence, no global settings access, Observation.
- `SelectionCapture.swift` — produce a subject plus a stable source target; preserve selection rect behavior.
- `CaptureModel.swift` and `VoiceCaptureModel.swift` — Observation and provenance/session capture state.
- `CapturePanel.swift` — standalone behavior, session-stable save, asynchronous provenance enrichment.
- `CaptureView.swift` and `VoiceCaptureView.swift` — Observation bindings and standalone presentation.
- `AppSettings.swift` — profiles, active profile, remove superseded global output flags, Observation.
- `AppDelegate.swift` — session/profile menus, current-session counts, callbacks instead of Combine publishers, profile-aware export.
- `StackView.swift` — session controls and structured rendered preview.
- `SettingsView.swift` — profile draft editor, setup re-entry, permission status, updated style, Observation.
- `PermissionCheck.swift` — remain a stateless system bridge or be folded into `PermissionState`; do not make static computed properties pretend to be reactive.
- `Resources/Info.plist` — accurate Apple Events explanation.
- `Package.swift` — add a test target; add `KeyboardShortcuts` only if its separate acceptance gate passes.
- `README.md` — document sessions, profiles, standalone capture, provenance, permissions, shortcuts, and clear-after-export behavior.
- New project `AGENTS.md` — record the Observation, concurrency, cancellation, actor-isolation, and teardown conventions.

## Implementation milestones

### Milestone 1: Models, prompt composition, and tests

Goal: establish the new states without touching source detection or UI behavior.

- Add the model types exactly once.
- Add `PromptComposer`.
- Define built-in profiles.
- Add a SwiftPM test target.
- Test Codable round trips for `Subject` and every supported provenance enrichment combination.
- Test selection and standalone Markdown.
- Test every profile toggle independently.
- Test coherent preamble placement once per export.

Checkpoint:

- `swift test` passes.
- Model and composition tests express provenance as independent facts; no UI code invents browser or terminal categories.

### Milestone 2: Session store and breaking persistence cutover

Goal: replace the global flat stack with named sessions.

- Implement `StoreDocument` persistence.
- Add session mutations and invariants.
- Scope annotation operations to a stable session ID.
- Implement clear/undo with originating session.
- Ignore old `stack.json`.
- Add store tests using an injected temporary file URL rather than the real Application Support path.

Checkpoint:

- Two sessions survive a store reload with order and current selection intact.
- Clearing A, switching to B, and undoing restores A without changing B.
- Deleting/switching never writes an invalid `currentSessionID`.

### Milestone 3: Observation migration

Goal: remove the old state system before adding more reactive UI.

- Convert all app-owned state classes.
- Update SwiftUI bindings.
- Replace AppDelegate Combine subscriptions with explicit callbacks.
- Remove unused Combine imports.
- Add the full project `AGENTS.md` rules.

Checkpoint:

- Workspace search finds no `ObservableObject`, `@Published`, `@ObservedObject`, or `@StateObject` in app-owned code.
- Menu counts still update after add, remove, clear, undo, and session switch.

### Milestone 4: Session UI, standalone capture, and voice lifecycle

Goal: make sessions and no-selection notes usable end to end while removing the stranded voice overlay state.

- Add menu and stack-window session controls.
- Map empty capture text to `.standalone`.
- Omit the quote surface for standalone capture.
- Preserve typed and voice save paths.
- Ensure capture always targets the session active when capture began.
- Replace the voice lifecycle with explicit starting, recording, transcribing, failure, and cancellation transitions.
- Route every teardown through one idempotent cancellation function.
- Implement the compact voice overlay redesign after visual reference study.

Checkpoint:

- Capture one selection and one standalone thought into A.
- Switch to B and capture there.
- Return to A and see the first two entries unchanged.
- Typed and voice standalone captures both save.
- Press and release the voice shortcut before recording starts; the overlay dismisses without a warning or stranded task.
- Escape dismisses starting, recording, transcribing, and failed states.
- Empty speech and transcription errors dismiss automatically after brief feedback.
- Repeated quick press/release cycles never require an app restart.

### Milestone 5: Provenance and permission setup

Goal: stamp generic application context and enrich Ghostty and Helium without delaying capture.

- Add target snapshot, generic baseline probe, and bundle-ID enricher registry.
- Implement Ghostty enrichment.
- Implement Helium enrichment.
- Keep unknown applications on the generic fallback.
- Add late-enrichment update by annotation UUID and original session ID.
- Build the first-run setup window, System Settings helper, and Settings re-entry.
- Add live permission/model status and update `Info.plist`.

Checkpoint:

- Ghostty note records focused title and current working directory.
- Helium note records active tab title and full URL.
- Switching apps after the shortcut does not change the captured source.
- Denying Automation still saves the note with generic application provenance.
- Chrome without a registered enricher still records its application name and window title.
- The panel appears before provenance completes.
- Cancelling the capture cancels its owned provenance task and prevents late mutation.

### Milestone 6: Profiles, export behavior, and polished preview

Goal: turn sessions into shaped prompts.

- Add profile persistence and defaults.
- Add profile submenu and Settings draft editor.
- Move old output flags into profiles.
- Use `PromptComposer` for copy, paste, and preview.
- Implement clear-after-export with undo.
- Replace raw monospaced preview with structured SwiftUI rendering.
- Apply the restrained Settings design pass.

Checkpoint:

- Coherent, Point by Point, and Plain outputs differ exactly as specified.
- Editing a draft does not change output before Save.
- Save as New does not mutate the source profile.
- A failed clipboard write never clears the session.
- A successful export clears only when the active profile requests it, leaves Markdown on the clipboard, and can be undone.
- Preview and copied Markdown contain the same information in the same order.

### Milestone 7: Shortcut cleanup, documentation, and full smoke test

Goal: remove avoidable custom shortcut code only if the package preserves behavior, then verify the real app.

- Evaluate and, if accepted, migrate atomically to `KeyboardShortcuts`.
- Delete obsolete shortcut files after every caller is migrated.
- Update README.
- Build and launch the app.
- Exercise the full typed and voice flow in Ghostty and Helium.

Checkpoint:

- Capture, hold/release voice, copy/paste, show stack, and clear shortcuts remain rebindable and survive restart.
- No duplicate hotkey registration exists.
- The actual app passes the end-to-end scenarios below.

## Test requirements

Tests should defend observable contracts, not source layout.

Required pure tests:

- `Subject` Codable round trip for selection and standalone.
- `Provenance` Codable round trip with no enrichment, URL enrichment, working-directory enrichment, and both enrichment fields.
- Store session invariants and reload.
- Clear/undo across a session switch.
- Annotation update targets original session by UUID.
- Profile encode/decode and default values.
- Draft dirty comparison, overwrite, clone, revert, and uniqueness rules.
- Markdown for selection and standalone entries.
- Preamble emitted exactly once.
- Each formatting toggle independently.
- Clear-after-export only after successful clipboard abstraction result. Use an injected pasteboard writer protocol/value, not the real global pasteboard in unit tests.
- Voice state transitions for early release, normal release, Escape from every state, failure timeout, and repeated cancellation.
- Cancelled provenance work cannot update the store even if its system call returns later.
- Setup readiness derives correctly from Accessibility, microphone, local-model, and optional Helium states.
- Completing or skipping voice setup persists without hiding later permission revocation in Settings.

Do not unit-test Accessibility or TCC. Verify those against the real apps.

## End-to-end acceptance scenarios

1. Create `A` and `B`. Capture in each. Restart. Both remain; the last active session remains active.
2. In Ghostty, capture selected text by typing a note. Export shows quote, note, Ghostty title, working directory, and time.
3. In Ghostty with no selection, hold the voice shortcut, speak, and release. Export shows no empty quote block and includes the working-directory enrichment.
4. In Helium, capture a page selection. Export shows the active tab title and URL.
5. Start a capture in Helium, let the panel activate, then switch apps before saving. The saved provenance still names the original Helium tab.
6. Deny or disable Helium Automation. Capture still succeeds with generic application identity and window-title provenance, with no UI delay.
7. Switch to Plain. Export contains no preamble, heading, provenance, or timestamps.
8. Switch to Coherent. Export begins with the exact coherent preamble once.
9. Edit Coherent's draft, then revert. Export remains unchanged. Edit again and save as a new profile. Both profiles remain distinct after restart.
10. Enable clear-after-export. Export A, verify A empties, B is untouched, Markdown remains on the system clipboard, and undo restores A.
11. Rebind every shortcut and restart. Each new binding still works, including key release for voice.
12. Inspect the rendered preview. It shows the same semantic order and fields as the copied Markdown without presenting raw Markdown syntax as the main view.
13. Press and release the voice shortcut before recording starts. The overlay disappears cleanly, no annotation is saved, and the next voice capture works.
14. Press Escape during starting, recording, transcribing, and failure. Each state tears down without leaving a panel or accepting a late result.
15. Capture from an unsupported app such as Chrome before a Chrome enricher exists. Provenance still contains the app identity and generic window title.
16. Launch with no setup flag. The setup window explains each capability, and text-only continuation remains available after Accessibility is granted.
17. Open Accessibility Settings from setup. The separate helper window remains visible, reflects the real grant, and closes when access appears.
18. Confirm that Input Monitoring is never requested by this build.

## Final architecture

```text
Global shortcuts / menu
          |
          v
 CaptureController ---- snapshots ----> session ID + app target + timestamp
      |          \
      |           \---- async ----> ProvenanceProbe
      v
 typed panel or voice transcription
      |
      v
 AnnotationStore ---- atomic JSON ----> Application Support/store.json
      |
      +---- current Session ----> StackView
      |
      +---- Session + active Profile ----> PromptComposer ----> clipboard/paste

 AppSettings ---- UserDefaults ----> profiles, active profile, machine settings
 PermissionState ---- system APIs ----> Accessibility, microphone, Automation
```

## Design constraints for the implementing agent

- Correct source state, not UI symptoms.
- Keep capture presentation independent from provenance latency.
- Capture session/app identity once; never consult mutable global context during a delayed save.
- Use closed enums for closed alternatives.
- Keep global settings out of the annotation store.
- Keep prompt formatting pure and testable.
- Use Swift Observation only for app-owned observable state.
- Prefer structured SwiftUI rendering over a Markdown dependency.
- Preserve voice hold/release semantics during any shortcut refactor.
- Never use `Task.detached` for lifecycle-owned work; cancel retained tasks and reject late results by capture identity.
- Do not add TCA or another state architecture beside the native Observation model.
- Request only permissions the current implementation needs; Carbon hotkeys do not justify Input Monitoring.
- Make a clean cutover: remove obsolete fields, globals, settings keys, code paths, imports, and files after callers move.
- Do not add bookmark, screenshot, iCloud, database, browser-generalization, or template-engine code.
