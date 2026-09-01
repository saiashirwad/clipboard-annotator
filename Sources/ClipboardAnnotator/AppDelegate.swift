import AppKit
import ClipboardAnnotatorDomain
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var stackWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private enum StoreState {
        case loading
        case available(AnnotationStore)
        case unavailable(String)
    }

    private var storeState: StoreState = .loading
    private var bootstrapTask: Task<Void, Never>?
    private var captureObserver: NSObjectProtocol?

    private var flashToken = 0
    private var flashing = false

    private let settings: AppSettings
    private let captureController: CaptureController

    override init() {
        let settings = AppSettings.shared
        self.settings = settings
        self.captureController = CaptureController(settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diag.log("=== launch pid=\(ProcessInfo.processInfo.processIdentifier) ===")
        installMainMenu()
        setUpStatusItem()
        settings.onHotKeysChanged = { [weak self] in self?.registerHotKeys() }
        registerHotKeys()

        bootstrapStore()

        // The capture panel needs the app frontmost to take keystrokes, and
        // activating brings every window forward. Get the others out of the way.
        captureObserver = NotificationCenter.default.addObserver(
            forName: .captureWillPresent, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideAuxiliaryWindows() }
        }

        if !PermissionCheck.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                PermissionCheck.ensureAccessibility()
            }
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

    func applicationWillTerminate(_ notification: Notification) {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        captureController.teardown()
        store?.teardown()
        if let captureObserver {
            NotificationCenter.default.removeObserver(captureObserver)
            self.captureObserver = nil
        }
        settings.onHotKeysChanged = nil
        for name in ["capture", "voiceCapture", "copy", "stack", "clear"] {
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

        menu.addItem(.separator())

        let count = store?.currentEntries.count ?? 0
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

        let clear = NSMenuItem(title: "Clear Stack", action: count > 0 ? #selector(clearStack) : nil, keyEquivalent: "")
        clear.target = self
        apply(settings.clearCombo, to: clear)
        menu.addItem(clear)

        if let undoCount = store?.lastCleared?.entries.count, undoCount > 0 {
            let undo = NSMenuItem(
                title: "Undo Clear (\(undoCount))",
                action: #selector(undoClear),
                keyEquivalent: "z"
            )
            undo.keyEquivalentModifierMask = [.command]
            undo.target = self
            menu.addItem(undo)
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
        let count = store.currentEntries.count
        let target = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        Diag.log("copyMarkdown invoked, count=\(count) paste=\(settings.pasteDirectly) front=\(target)")
        guard CurrentSessionExport.copy(store: store, settings: settings) else {
            NSSound.beep()
            return
        }

        guard settings.pasteDirectly else {
            flashStatus("Copied \(count)")
            return
        }
        // Give the target app a moment to see the new pasteboard before ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            SelectionCapture.pasteIntoFrontmostApp()
        }
        flashStatus("Pasted \(count)")
    }

    @objc private func clearStack() {
        guard let store else { NSSound.beep(); return }
        let count = store.currentEntries.count
        Diag.log("clearStack invoked, count=\(count)")
        guard count > 0 else { NSSound.beep(); return }
        store.mutate(.clearSession(sessionID: store.currentSessionID))
        flashStatus("Cleared \(count)")
    }

    @objc private func undoClear() {
        guard let store else { NSSound.beep(); return }
        store.mutate(.undoClear)
    }

    @objc private func showStack() {
        guard let store else { NSSound.beep(); return }
        if let stackWindow {
            NSApp.activate(ignoringOtherApps: true)
            stackWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Annotation Stack"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: StackView(store: store, settings: settings))
        window.delegate = self
        stackWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        let hosting = NSHostingView(rootView: SettingsView(settings: settings))
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.delegate = self
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Tuck away the stack and settings windows so a capture shows the note box
    /// alone. They keep their contents and position; ⌃⌘S brings the stack back.
    private func hideAuxiliaryWindows() {
        Diag.log("hideAuxiliaryWindows stack=\(stackWindow?.isVisible ?? false) settings=\(settingsWindow?.isVisible ?? false)")
        stackWindow?.orderOut(nil)
        settingsWindow?.orderOut(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === stackWindow { stackWindow = nil }
        if window === settingsWindow { settingsWindow = nil }
    }
}
