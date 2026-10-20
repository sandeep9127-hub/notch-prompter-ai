import AppKit
import Combine
import Carbon.HIToolbox

@main
struct NotchCoachMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = AppState()
    private var panelController: PrompterPanelController?
    private let editor = EditorWindowController()
    private var statusItem: NSStatusItem?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        panelController = PrompterPanelController(state: state)
        panelController?.layout()
        panelController?.setVisible(true)
        setupStatusItem()
        setupHotKeys()
        Log.write("NotchCoach \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") launched")
        state.onOpenEditor = { [weak self] in
            MainActor.assumeIsolated { self?.openEditor() }
        }
        editor.show(state: state)
    }

    // An accessory app has no visible menu bar, but it still needs an Edit menu
    // so that Cmd+C / Cmd+V / Cmd+Z work in the script editor.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit NotchCoach", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "NotchCoach")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // The menu bar icon turns into a red waveform whenever the mic or call audio is live.
        Publishers.CombineLatest(state.$micActive, state.$cuesEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] mic, cues in
                guard let button = self?.statusItem?.button else { return }
                let live = mic || cues
                let image = NSImage(
                    systemSymbolName: live ? "waveform.circle.fill" : "text.bubble",
                    accessibilityDescription: live ? "NotchCoach is listening" : "NotchCoach"
                )
                image?.isTemplate = !live
                button.image = image
                button.contentTintColor = live ? .systemRed : nil
            }
            .store(in: &bag)
    }

    /// Rebuilt each time it opens so check marks and live status are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        var live: [String] = []
        if state.micActive { live.append("● Mic on") }
        if state.cuesEnabled { live.append("● Call audio on") }
        if state.aiBusy { live.append("● AI working") }
        let header = NSMenuItem(title: live.isEmpty ? "Nothing is listening" : live.joined(separator: "   "), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let stop = makeItem("Stop Everything", #selector(hardStop), "", shortcut: "⌃⌥Esc")
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        menu.addItem(stop)
        menu.addItem(.separator())

        menu.addItem(makeItem(state.isPlaying ? "Pause" : "Play", #selector(togglePlay), "", shortcut: "⌃⌥Space"))
        menu.addItem(makeItem("Restart from Top", #selector(restart), "", shortcut: "⌃⌥R"))
        menu.addItem(makeItem(state.isPrompterVisible ? "Hide Prompter" : "Show Prompter", #selector(toggleVisible), "", shortcut: "⌃⌥H"))
        if !state.sections.isEmpty {
            let sectionsItem = NSMenuItem(title: "Jump to Section", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for section in state.sections {
                let item = makeItem(section.title, #selector(jumpToSection(_:)), "", shortcut: section.id < 9 ? "⌃⌥\(section.id + 1)" : nil)
                item.tag = section.id
                item.state = state.currentSection?.id == section.id ? .on : .off
                sub.addItem(item)
            }
            sectionsItem.submenu = sub
            menu.addItem(sectionsItem)
        }
        menu.addItem(.separator())

        let voice = makeItem("Follow My Voice", #selector(toggleMode), "", shortcut: "⌃⌥V")
        voice.state = state.mode == .voice ? .on : .off
        menu.addItem(voice)
        let cues = makeItem("Live Call Cues", #selector(toggleCues), "", shortcut: "⌃⌥C")
        cues.state = state.cuesEnabled ? .on : .off
        menu.addItem(cues)

        let engineItem = NSMenuItem(title: "AI Engine", action: nil, keyEquivalent: "")
        let engines = NSMenu()
        for engine in AIEngineKind.allCases {
            let item = makeItem(engine.label, #selector(chooseEngine(_:)), "")
            item.representedObject = engine.rawValue
            item.state = state.aiEngine == engine ? .on : .off
            engines.addItem(item)
        }
        engineItem.submenu = engines
        menu.addItem(engineItem)

        let placementItem = NSMenuItem(title: "Prompter Position", action: nil, keyEquivalent: "")
        let placements = NSMenu()
        for placement in PrompterPlacement.allCases {
            let item = makeItem(placement.label, #selector(choosePlacement(_:)), "")
            item.representedObject = placement.rawValue
            item.state = state.placement == placement ? .on : .off
            placements.addItem(item)
        }
        placementItem.submenu = placements
        menu.addItem(placementItem)
        menu.addItem(.separator())

        menu.addItem(makeItem("Script & Settings…", #selector(openEditor), "e"))
        menu.addItem(makeItem("Open Log File", #selector(openLog), ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit NotchCoach", #selector(quit), "q"))
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String, shortcut: String?) -> NSMenuItem {
        // Global shortcuts can't be menu key equivalents, so they're shown as a dimmed suffix.
        let item = makeItem(title, action, key)
        if let shortcut {
            let text = NSMutableAttributedString(string: title)
            text.append(NSAttributedString(string: "    \(shortcut)", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = text
        }
        return item
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func setupHotKeys() {
        let keys = HotKeys.shared
        keys.register(keyCode: kVK_Space) { [weak self] in self?.state.togglePlay() }
        keys.register(keyCode: kVK_UpArrow) { [weak self] in self?.state.nudge(lines: -1) }
        keys.register(keyCode: kVK_DownArrow) { [weak self] in self?.state.nudge(lines: 1) }
        keys.register(keyCode: kVK_ANSI_Equal) { [weak self] in self?.state.changeSpeed(by: 5) }
        keys.register(keyCode: kVK_ANSI_Minus) { [weak self] in self?.state.changeSpeed(by: -5) }
        keys.register(keyCode: kVK_ANSI_H) { [weak self] in self?.state.isPrompterVisible.toggle() }
        keys.register(keyCode: kVK_ANSI_V) { [weak self] in self?.toggleMode() }
        keys.register(keyCode: kVK_ANSI_C) { [weak self] in self?.state.toggleCues() }
        keys.register(keyCode: kVK_ANSI_R) { [weak self] in self?.state.restart() }
        keys.register(keyCode: kVK_Escape) { [weak self] in self?.state.hardStop() }
        let numberKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in numberKeys.enumerated() {
            keys.register(keyCode: key) { [weak self] in self?.state.jump(toSection: index) }
        }
    }

    @objc private func openEditor() { editor.show(state: state) }
    @objc private func hardStop() { state.hardStop() }
    @objc private func togglePlay() { state.togglePlay() }
    @objc private func restart() { state.restart() }
    @objc private func toggleVisible() { state.isPrompterVisible.toggle() }
    @objc private func toggleMode() { state.setMode(state.mode == .timed ? .voice : .timed) }
    @objc private func toggleCues() { state.toggleCues() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func jumpToSection(_ sender: NSMenuItem) { state.jump(toSection: sender.tag) }
    @objc private func chooseEngine(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let engine = AIEngineKind(rawValue: raw) { state.aiEngine = engine }
    }
    @objc private func choosePlacement(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let placement = PrompterPlacement(rawValue: raw) {
            state.placement = placement
            state.isPrompterVisible = true
        }
    }
    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("Log opened") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSWorkspace.shared.open(Log.url) }
    }
}
