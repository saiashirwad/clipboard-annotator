import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var stackWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private var flashToken = 0
    private var flashing = false

    private let store = AnnotationStore.shared
    private let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diag.log("=== launch pid=\(ProcessInfo.processInfo.processIdentifier) ===")
        installMainMenu()
        setUpStatusItem()
        settings.onHotKeysChanged = { [weak self] in self?.registerHotKeys() }
        registerHotKeys()

        store.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)

        store.$lastCleared
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        // The capture panel needs the app frontmost to take keystrokes, and
        // activating brings every window forward. Get the others out of the way.
        NotificationCenter.default.addObserver(
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
        let count = store.entries.count
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

        let capture = NSMenuItem(title: "Capture Selection", action: #selector(captureSelection), keyEquivalent: "")
        capture.target = self
        apply(settings.captureCombo, to: capture)
        menu.addItem(capture)

        let show = NSMenuItem(title: "Show Stack…", action: #selector(showStack), keyEquivalent: "")
        show.target = self
        apply(settings.stackCombo, to: show)
        menu.addItem(show)

        menu.addItem(.separator())

        let count = store.entries.count
        let verb = settings.pasteDirectly ? "Paste" : "Copy"
        let copy = NSMenuItem(
            title: count > 0 ? "\(verb) \(count) Annotation\(count == 1 ? "" : "s") as Markdown" : "Nothing Captured Yet",
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

        if !store.lastCleared.isEmpty {
            let undo = NSMenuItem(
                title: "Undo Clear (\(store.lastCleared.count))",
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
            released: { CaptureController.shared.endVoiceCapture() }
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
        CaptureController.shared.beginCapture()
    }

    private func captureVoiceSelection() {
        Diag.log("voice capture invoked")
        CaptureController.shared.beginVoiceCapture()
    }

    @objc private func copyMarkdown() {
        let count = store.entries.count
        let target = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        Diag.log("copyMarkdown invoked, count=\(count) paste=\(settings.pasteDirectly) front=\(target)")
        guard store.copyMarkdownToPasteboard() else { NSSound.beep(); return }

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
        let count = store.entries.count
        Diag.log("clearStack invoked, count=\(count)")
        guard count > 0 else { NSSound.beep(); return }
        store.clear()
        flashStatus("Cleared \(count)")
    }

    @objc private func undoClear() {
        store.undoClear()
    }

    @objc private func showStack() {
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
