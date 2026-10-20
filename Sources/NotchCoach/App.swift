import AppKit
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var panelController: PrompterPanelController?
    private let editor = EditorWindowController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        panelController = PrompterPanelController(state: state)
        panelController?.layout()
        panelController?.setVisible(true)
        setupStatusItem()
        setupHotKeys()
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
        menu.addItem(makeItem("Open Script & Settings…", #selector(openEditor), "e"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Play / Pause  (⌃⌥Space)", #selector(togglePlay), ""))
        menu.addItem(makeItem("Restart from top", #selector(restart), ""))
        menu.addItem(makeItem("Show / Hide Prompter  (⌃⌥H)", #selector(toggleVisible), ""))
        menu.addItem(makeItem("Switch Auto-scroll / Follow Voice  (⌃⌥V)", #selector(toggleMode), ""))
        menu.addItem(makeItem("Live Call Cues On / Off  (⌃⌥C)", #selector(toggleCues), ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit NotchCoach", #selector(quit), "q"))
        item.menu = menu
        statusItem = item
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
    }

    @objc private func openEditor() { editor.show(state: state) }
    @objc private func togglePlay() { state.togglePlay() }
    @objc private func restart() { state.restart() }
    @objc private func toggleVisible() { state.isPrompterVisible.toggle() }
    @objc private func toggleMode() { state.setMode(state.mode == .timed ? .voice : .timed) }
    @objc private func toggleCues() { state.toggleCues() }
    @objc private func quit() { NSApp.terminate(nil) }
}
