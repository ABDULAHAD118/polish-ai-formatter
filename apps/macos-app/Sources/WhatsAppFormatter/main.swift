import AppKit
import FormatterCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let controller = FormatController()
    private let hotKey = HotKeyManager()
    private let hud = HUD()
    private lazy var composerButton = ComposerButton { [weak self] in self?.controller.trigger() }
    private var settingsWindow: NSWindow?
    private let cancelItem = NSMenuItem(title: "Cancel Formatting", action: #selector(cancel), keyEquivalent: "")
    private let shortcutItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let modeMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenuBar()
        controller.onStateChange = { [weak self] running in
            self?.statusItem?.button?.image = Self.icon(running ? "sparkles.rectangle.stack" : "sparkles")
            self?.cancelItem.isHidden = !running
            self?.composerButton.setRunning(running)
        }
        if case .conflict = registerShortcut(Settings.shared.shortcut) {
            hud.show("\(Settings.shared.shortcut.display) is used by another app. Choose another shortcut in Settings.", style: .error)
            openSettings()
        }
        if !Accessibility.isTrusted { openSettings() }
        composerButton.start()
        Updater.check(userInitiated: false)
    }

    private static func icon(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "TextPolish")
        image?.isTemplate = true
        return image
    }

    private func registerShortcut(_ shortcut: Shortcut) -> HotKeyManager.RegisterResult {
        hotKey.register(shortcut) { [weak self] in
            MainActor.assumeIsolated { self?.controller.trigger() }
        }
    }

    private func buildMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon("sparkles")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)
        cancelItem.target = self
        cancelItem.isHidden = true
        menu.addItem(cancelItem)
        menu.addItem(.separator())
        let modeItem = NSMenuItem(title: "Formatting Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        shortcutItem.title = "Format with \(Settings.shared.shortcut.display)"
        modeMenu.removeAllItems()
        for mode in SharedConfig.shared.modes {
            let item = NSMenuItem(title: mode.name, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id
            item.state = mode.id == Settings.shared.mode ? .on : .off
            modeMenu.addItem(item)
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { Settings.shared.mode = id }
    }

    @objc private func checkForUpdates() {
        Updater.check(userInitiated: true)
    }

    @objc private func cancel() {
        if controller.isRunning { controller.trigger() }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView { [weak self] shortcut in
                self?.registerShortcut(shortcut) ?? .failed(-1)
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "TextPolish"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Checks that need AppKit, the real status bar and Carbon. Run with --self-test.
@MainActor
func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ passed: Bool) {
        print("\(passed ? "PASS" : "FAIL") \(name)")
        if !passed { failures += 1 }
    }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    check("status item is created", item.button != nil)
    check("sparkles menu-bar icon exists", NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) != nil)
    NSStatusBar.system.removeStatusItem(item)

    let first = HotKeyManager()
    let second = HotKeyManager()
    if case .ok = first.register(.default, action: {}) {
        check("default shortcut registers", true)
    } else {
        check("default shortcut registers (another app may own it)", false)
    }
    if case .conflict = second.register(.default, action: {}) {
        check("conflict is reported, not ignored", true)
    } else {
        check("conflict is reported, not ignored", false)
    }
    first.unregister()
    second.unregister()
    check("default shortcut is ⌃⌥⌘F", Shortcut.default.display == "⌃⌥⌘F")

    check("WhatsApp bundle is recognised", Composer.isWhatsApp(bundleId: "net.whatsapp.WhatsApp"))
    check("other apps are rejected", !Composer.isWhatsApp(bundleId: "com.apple.Notes") && !Composer.isWhatsApp(bundleId: nil))

    check("text area with settable value is a composer", Composer.looksLikeComposer(role: "AXTextArea", subrole: nil, labels: ["Message"], valueSettable: true))
    check("search field is not a composer", !Composer.looksLikeComposer(role: "AXTextField", subrole: "AXSearchField", labels: [], valueSettable: true))
    check("field labelled search is not a composer", !Composer.looksLikeComposer(role: "AXTextField", subrole: nil, labels: ["Search or start a new chat"], valueSettable: true))
    check("read-only text is not a composer", !Composer.looksLikeComposer(role: "AXTextArea", subrole: nil, labels: [], valueSettable: false))
    check("a button is not a composer", !Composer.looksLikeComposer(role: "AXButton", subrole: nil, labels: [], valueSettable: true))

    let oneLine = ComposerButton.frame(composer: CGRect(x: 100, y: 800, width: 400, height: 36), primaryScreenHeight: 1000)
    check("button sits at the composer's right edge", oneLine == NSRect(x: 468, y: 168, width: 28, height: 28))
    let tall = ComposerButton.frame(composer: CGRect(x: 100, y: 700, width: 400, height: 100), primaryScreenHeight: 1000)
    check("button stays on a tall composer's last line", tall.minY == 204)
    let screens = [NSRect(x: 0, y: 0, width: 1000, height: 1000)]
    check("button on a screen is placed", ComposerButton.isOnScreen(oneLine, screens: screens))
    check("off-screen button is hidden", !ComposerButton.isOnScreen(NSRect(x: 5000, y: 5000, width: 28, height: 28), screens: screens))
    check("non-finite button frame is hidden", !ComposerButton.isOnScreen(NSRect(x: CGFloat.nan, y: 0, width: 28, height: 28), screens: screens))

    // A private pasteboard, so the user's real clipboard is untouched by this test.
    let board = NSPasteboard(name: NSPasteboard.Name("waf-self-test"))
    board.clearContents()
    let original = NSPasteboardItem()
    original.setString("plain", forType: .string)
    original.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.waf.custom"))
    board.writeObjects([original])
    let snapshot = ClipboardSnapshot(board)
    board.clearContents()
    board.setString("temporary", forType: .string)
    snapshot.restore(board)
    check("clipboard text is restored", board.string(forType: .string) == "plain")
    check("clipboard custom formats are restored", board.data(forType: NSPasteboard.PasteboardType("com.waf.custom")) == Data([1, 2, 3]))
    board.releaseGlobally()

    Keychain.write("self-test", "secret")
    check("keychain stores a key", Keychain.read("self-test") == "secret")
    Keychain.write("self-test", "")
    check("keychain removes a key", Keychain.read("self-test").isEmpty)

    print(failures == 0 ? "All self-tests passed" : "\(failures) self-test(s) failed")
    return failures == 0 ? 0 : 1
}

if CommandLine.arguments.contains("--ax-dump") {
    print(Composer.diagnostics())
    exit(0)
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--self-test") {
    app.setActivationPolicy(.accessory)
    exit(MainActor.assumeIsolated { runSelfTest() })
}
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
