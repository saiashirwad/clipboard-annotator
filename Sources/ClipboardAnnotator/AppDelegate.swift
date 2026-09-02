import AppKit
import ClipboardAnnotatorDomain
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var stackWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var setupWindowController: SetupWindowController?
    private var accessibilityHelperWindowController: AccessibilityHelperWindowController?
    private var profileEditor: ProfileEditorState?
    private var quickSwitch: QuickSwitchWindowController?
    private enum StoreState {
        case loading
        case available(AnnotationStore)
        case unavailable(String)
    }

    private var storeState: StoreState = .loading
    private var bootstrapTask: Task<Void, Never>?
    private var menuMutationTask: Task<Void, Never>?
    private var pasteTask: Task<Void, Never>?
    private var captureObserver: NSObjectProtocol?

    private var flashToken = 0
    private var flashing = false

    private let settings: AppSettings
    private let captureController: CaptureController
    private let permissionState: PermissionState

    override init() {
        let settings = AppSettings.shared
        let permissionState = PermissionState()
        self.settings = settings
        self.permissionState = permissionState
        self.captureController = CaptureController(
            settings: settings,
            permissionState: permissionState
        )
        super.init()
        captureController.onAccessibilityRequired = { [weak self] in
            self?.presentPermissionHelpForCapture()
        }
        captureController.onStatusChange = { [weak self] in
            self?.refreshStatusItem()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diag.log("=== launch pid=\(ProcessInfo.processInfo.processIdentifier) ===")
        installMainMenu()
        setUpStatusItem()
        settings.onHotKeysChanged = { [weak self] in self?.registerHotKeys() }
        settings.onProfilesChanged = { [weak self] in self?.refreshStatusItem() }
        registerHotKeys()
        permissionState.refresh()

        bootstrapStore()

        // The capture panel needs the app frontmost to take keystrokes, and
        // activating brings every window forward. Get the others out of the way.
        captureObserver = NotificationCenter.default.addObserver(
            forName: .captureWillPresent, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideAuxiliaryWindows() }
        }

        if !settings.hasCompletedSetup {
            presentSetup()
        }
    }

    private func bootstrapStore() {
        bootstrapTask?.cancel()
        storeState = .loading
        refreshStatusItem()

        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            do {
                let store = try await AnnotationStore(
                    persistence: .live(),
                    onChange: { [weak self] in self?.storeDidChange() }
                )
                guard !Task.isCancelled else {
                    store.teardown()
                    return
                }
                bootstrapTask = nil
                storeState = .available(store)
                captureController.configure(store: store)
                refreshStatusItem()
            } catch is CancellationError {
                // App termination owns cancellation and teardown.
            } catch {
                guard !Task.isCancelled else { return }
                bootstrapTask = nil
                storeState = .unavailable(error.localizedDescription)
                Diag.log("store bootstrap failed: \(error)")
                refreshStatusItem()
            }
        }
    }

    private func storeDidChange() {
        refreshStatusItem()
    }

    private var store: AnnotationStore? {
        guard case let .available(store) = storeState else { return nil }
        return store
    }

    private var isStoreAvailable: Bool { store != nil }

    private var unavailableMenuTitle: String {
        switch storeState {
        case .loading:
            return "Loading Annotations…"
        case .available:
            return "Nothing Captured Yet"
        case let .unavailable(message):
            return "Annotations Unavailable: \(message)"
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissionState.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let profileEditor else { return .terminateNow }
        return ProfileDialogs.shouldClose(profileEditor) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        menuMutationTask?.cancel()
        menuMutationTask = nil
        pasteTask?.cancel()
        pasteTask = nil
        quickSwitch?.close()
        setupWindowController?.teardown()
        setupWindowController = nil
        accessibilityHelperWindowController?.teardown()
        accessibilityHelperWindowController = nil
        settingsWindow?.delegate = nil
        settingsWindow?.close()
        settingsWindow = nil
        stackWindow?.delegate = nil
        stackWindow?.close()
        stackWindow = nil
        captureController.teardown()
        permissionState.teardown()
        store?.teardown()
        if let captureObserver {
            NotificationCenter.default.removeObserver(captureObserver)
            self.captureObserver = nil
        }
        settings.onHotKeysChanged = nil
        settings.onProfilesChanged = nil
        for name in ["capture", "voiceCapture", "copy", "stack", "switchSession", "clear"] {
            HotKeyCenter.shared.unregister(name: name)
        }
    }

    // MARK: - Main menu

    /// A menu-bar app has no visible main menu, but AppKit still routes ⌘V,
    /// ⌘C, ⌘A and ⌘Z through one. Without it, a dictation tool that types by
    /// sending ⌘V to the note box gets nothing — the text stays stuck on the
    /// clipboard and turns up later, on top of the Markdown.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Clipboard Annotator")
        main.addItem(appItem)

        let file = NSMenu(title: "File")
        file.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        let fileItem = NSMenuItem()
        fileItem.submenu = file
        main.addItem(fileItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "quote.bubble", accessibilityDescription: "Clipboard Annotator")
        image?.isTemplate = true
        if let button = statusItem.button {
            button.image = image
            button.imagePosition = image == nil ? .noImage : .imageLeading
            if image == nil { button.title = "CA" }
        }
        statusItem.isVisible = true
        rebuildMenu()
        Diag.log("statusItem button=\(statusItem.button != nil) image=\(image != nil) visible=\(statusItem.isVisible)")
    }

    private func refreshStatusItem() {
        if !flashing { applyCountTitle() }
        rebuildMenu()
    }

    private func applyCountTitle() {
        let count = store?.currentEntries.count ?? 0
        statusItem.button?.title = count > 0 ? " \(count)" : ""
        let sessionName = store?.currentSession.name ?? "No session"
        statusItem.button?.toolTip = "\(sessionName) · \(settings.activeProfile.name)"
    }

    private func flashStatus(_ text: String) {
        flashToken += 1
        let token = flashToken
        flashing = true
        statusItem.button?.title = " \(text)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.flashing = false
            self.applyCountTitle()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let capture = NSMenuItem(
            title: "Capture Selection",
            action: isStoreAvailable ? #selector(captureSelection) : nil,
            keyEquivalent: ""
        )
        capture.target = self
        apply(settings.captureCombo, to: capture)
        menu.addItem(capture)

        let show = NSMenuItem(
            title: "Show Stack…",
            action: isStoreAvailable ? #selector(showStack) : nil,
            keyEquivalent: ""
        )
        show.target = self
        apply(settings.stackCombo, to: show)
        menu.addItem(show)

        let facts = store.map {
            SessionUIFacts(
                sessions: $0.sessions,
                currentSessionID: $0.currentSessionID,
                lastCleared: $0.lastCleared
            )
        }
        if let facts, let current = facts.current {
            let summary = NSMenuItem(title: facts.currentTitle, action: nil, keyEquivalent: "")
            menu.addItem(summary)

            let sessionMenu = NSMenu(title: "Session")
            for session in facts.sessions {
                let item = NSMenuItem(
                    title: "\(session.name) (\(session.annotationCount))",
                    action: #selector(switchToSession(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id as NSUUID
                item.state = session.isCurrent ? .on : .off
                sessionMenu.addItem(item)
            }
            sessionMenu.addItem(.separator())

            let quickSwitch = NSMenuItem(
                title: "Switch Session…",
                action: #selector(showQuickSwitcher),
                keyEquivalent: ""
            )
            quickSwitch.target = self
            apply(settings.switchSessionCombo, to: quickSwitch)
            sessionMenu.addItem(quickSwitch)
            sessionMenu.addItem(.separator())

            let newSession = NSMenuItem(
                title: "New Session…",
                action: #selector(newSession(_:)),
                keyEquivalent: ""
            )
            newSession.target = self
            sessionMenu.addItem(newSession)

            let rename = NSMenuItem(
                title: "Rename Current Session…",
                action: #selector(renameSession(_:)),
                keyEquivalent: ""
            )
            rename.target = self
            rename.representedObject = current.id as NSUUID
            sessionMenu.addItem(rename)

            let delete = NSMenuItem(
                title: "Delete Current Session…",
                action: facts.canDelete ? #selector(deleteSession(_:)) : nil,
                keyEquivalent: ""
            )
            delete.target = self
            delete.representedObject = current.id as NSUUID
            sessionMenu.addItem(delete)

            let sessionRoot = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")
            sessionRoot.submenu = sessionMenu
            menu.addItem(sessionRoot)
        }

        let profileMenu = NSMenu(title: "Profile")
        for profile in settings.profiles {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(selectProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id as NSUUID
            item.state = profile.id == settings.activeProfileID ? .on : .off
            profileMenu.addItem(item)
        }
        let profileRoot = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        profileRoot.submenu = profileMenu
        menu.addItem(profileRoot)

        menu.addItem(.separator())

        let count = facts?.current?.annotationCount ?? 0
        let verb = settings.pasteDirectly ? "Paste" : "Copy"
        let copy = NSMenuItem(
            title: count > 0
                ? "\(verb) \(count) Annotation\(count == 1 ? "" : "s") as Markdown"
                : unavailableMenuTitle,
            action: count > 0 ? #selector(copyMarkdown) : nil,
            keyEquivalent: ""
        )
        copy.target = self
        apply(settings.copyCombo, to: copy)
        menu.addItem(copy)

        let clear = NSMenuItem(
            title: facts?.current.map { "Clear \($0.name)" } ?? "Clear Current Session",
            action: count > 0 ? #selector(clearSession(_:)) : nil,
            keyEquivalent: ""
        )
        clear.target = self
        clear.representedObject = facts?.current?.id as NSUUID?
        apply(settings.clearCombo, to: clear)
        menu.addItem(clear)

        if let undo = facts?.undo {
            let item = NSMenuItem(
                title: undo.title,
                action: #selector(undoClear),
                keyEquivalent: "z"
            )
            item.keyEquivalentModifierMask = [.command]
            item.target = self
            menu.addItem(item)
        }

        if let error = store?.error {
            menu.addItem(.separator())
            let errorItem = NSMenuItem(
                title: annotationStoreErrorMessage(error),
                action: nil,
                keyEquivalent: ""
            )
            menu.addItem(errorItem)
            if store?.hasPendingMutations == true {
                let retry = NSMenuItem(
                    title: "Retry Pending Session Changes",
                    action: #selector(retryPendingMutations),
                    keyEquivalent: ""
                )
                retry.target = self
                menu.addItem(retry)
            }
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(title: "Quit Clipboard Annotator", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Show the global shortcut beside the menu item so it is discoverable.
    /// The Carbon hotkey swallows the event first, so this never double-fires.
    private func apply(_ combo: KeyCombo, to item: NSMenuItem) {
        guard combo.isValid else { return }
        if let equivalent = combo.menuKeyEquivalent {
            item.keyEquivalent = equivalent
            item.keyEquivalentModifierMask = combo.modifiers
        } else {
            item.toolTip = combo.displayString
        }
    }

    // MARK: - Hot keys

    private func registerHotKeys() {
        HotKeyCenter.shared.register(name: "capture", combo: settings.captureCombo) { [weak self] in
            self?.captureSelection()
        }
        HotKeyCenter.shared.registerHold(
            name: "voiceCapture",
            combo: settings.voiceCaptureCombo,
            pressed: { [weak self] in self?.captureVoiceSelection() },
            released: { [weak self] in self?.captureController.endVoiceCapture() }
        )
        HotKeyCenter.shared.register(name: "copy", combo: settings.copyCombo) { [weak self] in
            self?.copyMarkdown()
        }
        HotKeyCenter.shared.register(name: "stack", combo: settings.stackCombo) { [weak self] in
            self?.showStack()
        }
        HotKeyCenter.shared.register(name: "switchSession", combo: settings.switchSessionCombo) { [weak self] in
            self?.showQuickSwitcher()
        }
        HotKeyCenter.shared.register(name: "clear", combo: settings.clearCombo) { [weak self] in
            self?.clearStack()
        }
        rebuildMenu()
    }

    // MARK: - Actions

    @objc private func captureSelection() {
        Diag.log("captureSelection invoked")
        captureController.beginCapture()
    }

    private func captureVoiceSelection() {
        Diag.log("voice capture invoked")
        captureController.beginVoiceCapture()
    }

    @objc private func copyMarkdown() {
        guard let store else { NSSound.beep(); return }
        pasteTask?.cancel()
        pasteTask = nil
        let count = store.currentEntries.count
        let target = NSWorkspace.shared.frontmostApplication
        let targetName = target?.localizedName ?? "?"
        let targetProcessIdentifier = target?.processIdentifier ?? 0
        Diag.log("copyMarkdown invoked, count=\(count) paste=\(settings.pasteDirectly) front=\(targetName)")
        let clearsAfterExport = settings.activeProfile.clearSessionAfterExport
        guard CurrentSessionExport.copy(store: store, settings: settings) else {
            NSSound.beep()
            return
        }
        if clearsAfterExport {
            observeMenuMutation(store: store, presentsError: false)
        }

        guard settings.pasteDirectly else {
            flashStatus("Copied \(count)")
            return
        }
        // Give the target app a moment to see the new pasteboard before ⌘V.
        // Retain its PID so a focus change cannot redirect the paste.
        pasteTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            SelectionCapture.paste(into: targetProcessIdentifier)
            self?.pasteTask = nil
        }
        flashStatus("Pasted \(count)")
    }

    @objc private func clearStack() {
        guard let store else { NSSound.beep(); return }
        let sessionID = store.currentSessionID
        guard let session = store.sessions.first(where: { $0.id == sessionID }), !session.entries.isEmpty else {
            NSSound.beep()
            return
        }
        Diag.log("clearStack invoked, session=\(sessionID), count=\(session.entries.count)")
        enqueueMenuMutation(.clearSession(sessionID: sessionID))
    }

    @objc private func clearSession(_ sender: NSMenuItem) {
        guard let sessionID = capturedSessionID(from: sender) else { NSSound.beep(); return }
        enqueueMenuMutation(.clearSession(sessionID: sessionID))
    }

    @objc private func undoClear() {
        guard store != nil else { NSSound.beep(); return }
        enqueueMenuMutation(.undoClear)
    }

    @objc private func switchToSession(_ sender: NSMenuItem) {
        guard let sessionID = capturedSessionID(from: sender) else { NSSound.beep(); return }
        enqueueMenuMutation(.switchSession(sessionID: sessionID))
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let profileID = capturedSessionID(from: sender) else { NSSound.beep(); return }
        requestProfileSelection(profileID)
    }

    private func requestProfileSelection(_ profileID: UUID) {
        if let profileEditor {
            switch profileEditor.requestSelection(profileID) {
            case .needsDecision:
                _ = ProfileDialogs.resolvePendingSelection(profileEditor)
            case .selected, .unchanged:
                break
            case .rejected:
                NSSound.beep()
            }
            return
        }
        do {
            try settings.selectProfile(id: profileID)
        } catch {
            NSSound.beep()
        }
    }

    @objc private func newSession(_ sender: NSMenuItem) {
        guard let store else { NSSound.beep(); return }
        let sessions = store.sessions
        guard
            let draft = SessionDialogs.requestNewSessionName(sessions: sessions),
            let name = SessionDialogs.validateForEnqueue(
                draft,
                excluding: nil,
                sessions: store.sessions
            )
        else { return }
        enqueueMenuMutation(.createSession(Session(name: name)), presentsError: true)
    }

    @objc private func renameSession(_ sender: NSMenuItem) {
        guard let store, let sessionID = capturedSessionID(from: sender) else {
            NSSound.beep()
            return
        }
        let sessions = store.sessions
        guard
            let draft = SessionDialogs.requestRenamedSessionName(
                sessionID: sessionID,
                sessions: sessions
            ),
            let name = SessionDialogs.validateForEnqueue(
                draft,
                excluding: sessionID,
                sessions: store.sessions
            )
        else { return }
        enqueueMenuMutation(
            .renameSession(sessionID: sessionID, name: name),
            presentsError: true
        )
    }

    @objc private func deleteSession(_ sender: NSMenuItem) {
        guard let store, let sessionID = capturedSessionID(from: sender) else {
            NSSound.beep()
            return
        }
        let sessions = store.sessions
        guard SessionDialogs.confirmsDelete(
            sessionID: sessionID,
            sessions: sessions,
            lastCleared: store.lastCleared
        ) else { return }
        enqueueMenuMutation(.deleteSession(sessionID: sessionID), presentsError: true)
    }

    @objc private func retryPendingMutations() {
        guard let store else { NSSound.beep(); return }
        store.retryPendingMutations()
        observeMenuMutation(store: store, presentsError: true)
    }

    private func capturedSessionID(from sender: NSMenuItem) -> UUID? {
        if let id = sender.representedObject as? UUID { return id }
        if let id = sender.representedObject as? NSUUID { return id as UUID }
        return nil
    }

    private func enqueueMenuMutation(
        _ mutation: SessionDocumentMutation,
        presentsError: Bool = false
    ) {
        guard let store else { NSSound.beep(); return }
        store.mutate(mutation)
        observeMenuMutation(store: store, presentsError: presentsError)
    }

    private func observeMenuMutation(store: AnnotationStore, presentsError: Bool) {
        menuMutationTask?.cancel()
        menuMutationTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            await store.waitForIdle()
            guard !Task.isCancelled else { return }
            menuMutationTask = nil
            refreshStatusItem()
            if let error = store.error {
                NSSound.beep()
                if presentsError {
                    SessionDialogs.showMessage(annotationStoreErrorMessage(error))
                }
            }
        }
    }

    @objc private func showStack() {
        guard let store else { NSSound.beep(); return }
        if let stackWindow {
            NSApp.activate(ignoringOtherApps: true)
            stackWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Annotation Stack"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // An empty unified toolbar makes the title bar as tall as the header,
        // so the traffic lights centre on the same line as its controls.
        let toolbar = NSToolbar(identifier: "StackWindowToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: StackView(
            store: store,
            settings: settings,
            onSelectProfile: { [weak self] profileID in
                self?.requestProfileSelection(profileID)
            }
        ))
        window.contentView = hosting
        let fittingSize = hosting.fittingSize
        window.setContentSize(NSSize(
            width: max(680, fittingSize.width),
            height: max(460, fittingSize.height)
        ))
        window.center()
        window.delegate = self
        stackWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showQuickSwitcher() {
        guard let store else { NSSound.beep(); return }
        if quickSwitch == nil {
            quickSwitch = QuickSwitchWindowController(
                store: store,
                onSwitch: { [weak self] sessionID in
                    self?.switchFromQuickSwitcher(to: sessionID)
                },
                onDismiss: { [weak self] in self?.quickSwitch = nil }
            )
        }
        quickSwitch?.show()
    }

    private func switchFromQuickSwitcher(to sessionID: UUID) {
        enqueueMenuMutation(
            .switchSession(sessionID: sessionID),
            presentsError: true
        )
        quickSwitch?.close()
    }

    private func presentPermissionHelpForCapture() {
        permissionState.refresh()
        if settings.hasCompletedSetup {
            presentAccessibilityHelper()
        } else {
            presentSetup()
        }
    }

    private func presentSetup() {
        permissionState.refresh()
        if setupWindowController == nil {
            setupWindowController = SetupWindowController(
                settings: settings,
                permissionState: permissionState,
                onShowAccessibilityHelper: { [weak self] in
                    self?.presentAccessibilityHelper()
                },
                onComplete: { [weak self] in
                    self?.setupWindowController?.close()
                }
            )
        }
        setupWindowController?.show()
    }

    private func presentAccessibilityHelper() {
        if accessibilityHelperWindowController == nil {
            accessibilityHelperWindowController = AccessibilityHelperWindowController(
                permissionState: permissionState
            )
        }
        accessibilityHelperWindowController?.show()
    }

    @objc private func showSettings() {
        permissionState.refresh()
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier: "SettingsWindowToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        let profileEditor = ProfileEditorState(settings: settings)
        self.profileEditor = profileEditor
        let settingsView = SettingsView(
            settings: settings,
            profileEditor: profileEditor,
            permissionState: permissionState,
            onSelectProfile: { [weak self] profileID in
                self?.requestProfileSelection(profileID)
            },
            onShowAccessibilityHelper: { [weak self] in
                self?.presentAccessibilityHelper()
            },
            onRunSetup: { [weak self] in
                self?.presentSetup()
            }
        )
        // Each tab has its own natural height; follow it with the top edge still.
        let hosting = NSHostingView(rootView: settingsView
            .background(GeometryReader { proxy in
                Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(HeightKey.self) { [weak self] height in
                self?.fitSettingsWindow(toContentHeight: height)
            })
        hosting.sizingOptions = [.intrinsicContentSize]
        // The tab strip owns the title-bar band; no inset for the toolbar.
        hosting.safeAreaRegions = []
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.delegate = self
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Open calmly, without the first text field selected.
        window.makeFirstResponder(nil)
    }

    private func fitSettingsWindow(toContentHeight height: CGFloat) {
        guard let window = settingsWindow, height > 0 else { return }
        let frame = window.frame
        guard abs(height - frame.height) > 0.5 else { return }
        let target = NSRect(
            x: frame.minX,
            y: frame.maxY - height,
            width: frame.width,
            height: height
        )
        guard window.isVisible else {
            window.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().setFrame(target, display: true)
        }
    }

    /// Tuck away auxiliary windows so a capture shows the note box alone.
    private func hideAuxiliaryWindows() {
        Diag.log("hideAuxiliaryWindows stack=\(stackWindow?.isVisible ?? false) settings=\(settingsWindow?.isVisible ?? false) quickSwitch=\(quickSwitch != nil)")
        stackWindow?.orderOut(nil)
        settingsWindow?.orderOut(nil)
        setupWindowController?.close()
        accessibilityHelperWindowController?.close()
        quickSwitch?.close()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === settingsWindow, let profileEditor else { return true }
        return ProfileDialogs.shouldClose(profileEditor)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === stackWindow { stackWindow = nil }
        if window === settingsWindow {
            settingsWindow = nil
            profileEditor = nil
        }
    }
}
