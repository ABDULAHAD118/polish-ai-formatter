import AppKit
import FormatterCore

@MainActor
final class FormatController {
    private var task: Task<Void, Never>?
    private let hud = HUD()
    var onStateChange: ((Bool) -> Void)?

    var isRunning: Bool { task != nil }

    /// The shortcut or composer button starts formatting, and using either again cancels.
    func trigger() {
        if let task {
            task.cancel()
            return
        }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
            self?.onStateChange?(false)
        }
        onStateChange?(true)
    }

    private func fail(_ message: String) { hud.show(message, style: .error) }

    private func run() async {
        guard Accessibility.isTrusted else {
            Accessibility.requestPrompt()
            return fail("Allow Accessibility access in System Settings, then try again.")
        }
        guard let app = Composer.frontmostWhatsApp() else {
            return fail("Open WhatsApp and click in the message box first.")
        }
        guard let element = Composer.focusedElement(pid: app.processIdentifier), Composer.isComposer(element) else {
            return fail("Click in the WhatsApp message box first. Nothing was changed.")
        }

        var draft = Composer.read(element)
        var viaClipboard = false
        if draft == nil {
            draft = await Composer.copyDraftViaClipboard()
            viaClipboard = true
        }
        guard let draft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fail("Write a message first.")
        }

        hud.show("Formatting… Click ✕ or press the shortcut to cancel.", style: .progress)
        let text: String
        do {
            text = try await AIClient().format(draft: draft, settings: Settings.shared.aiSettings())
        } catch let error as AIError {
            if error.code == "cancelled" { return hud.show("Cancelled. Your draft was not changed.", style: .info) }
            return fail(error.message)
        } catch {
            return fail("Something went wrong. Your draft was not changed.")
        }
        if Task.isCancelled { return hud.show("Cancelled. Your draft was not changed.", style: .info) }

        // The user may have moved on while the model was working.
        guard let current = Composer.frontmostWhatsApp(), current.processIdentifier == app.processIdentifier,
              let focused = Composer.focusedElement(pid: current.processIdentifier), CFEqual(focused, element) else {
            return fail("You left the message box, so the draft was not changed. Try again.")
        }
        let latest = viaClipboard ? await Composer.copyDraftViaClipboard() : Composer.read(element)
        guard latest == draft else {
            return fail("The draft changed while formatting, so your version was kept. Try again.")
        }

        if !viaClipboard, Composer.replaceWithAccessibility(element, text: text, original: draft) {
            return hud.show("Formatted. Review it, then send it yourself.", style: .success)
        }
        await Composer.pasteViaClipboard(text)
        if viaClipboard || Composer.read(element) == text {
            return hud.show("Formatted. Review it, then send it yourself.", style: .success)
        }
        fail("Could not update the draft. WhatsApp's interface may have changed.")
    }
}

/// Small status panel that does not take focus from WhatsApp.
@MainActor
final class HUD {
    enum Style { case progress, success, error, info }

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 48), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        label.frame = effect.bounds.insetBy(dx: 14, dy: 8)
        label.autoresizingMask = [.width, .height]
        effect.addSubview(label)
        panel.contentView = effect
        return panel
    }()
    private let label: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        return label
    }()
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, style: Style) {
        hideTask?.cancel()
        let glyph: String
        switch style {
        case .progress: glyph = "✦ "
        case .success: glyph = "✓ "
        case .error: glyph = "⚠︎ "
        case .info: glyph = ""
        }
        label.stringValue = glyph + message
        let height = max(48, label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 332, height: 400)).height + 22)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - 180, y: screen.maxY - height - 16, width: 360, height: height), display: true)
        panel.orderFrontRegardless()
        if style == .progress { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: style == .error ? 7_000_000_000 : 3_000_000_000)
            if !Task.isCancelled { self?.panel.orderOut(nil) }
        }
    }
}

/// Button floating over the focused composer. The panel is non-activating, so clicking it keeps focus in WhatsApp.
@MainActor
final class ComposerButton {
    private final class FirstClickButton: NSButton {
        // WhatsApp stays active, so without this the first click would be swallowed.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    static let size: CGFloat = 28
    private let action: () -> Void
    private var timer: Timer?
    private lazy var button: NSButton = {
        let button = FirstClickButton(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.size / 2
        button.layer?.backgroundColor = NSColor.systemGreen.cgColor
        button.target = self
        button.action = #selector(clicked)
        return button
    }()
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: button.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = button
        return panel
    }()

    init(action: @escaping () -> Void) {
        self.action = action
        setRunning(false)
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.schedulePolling()
                self?.refresh()
            }
        }
        schedulePolling()
    }

    /// A timer whose callback throws an Objective-C exception never fires again, which would freeze the button on screen.
    /// Re-arming on every app switch means one bad frame cannot outlive WhatsApp being active.
    private func schedulePolling() {
        timer?.invalidate()
        // shortcut: polling lags window drags by up to 0.25s, switch to AXObserver if that feels bad.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func setRunning(_ running: Bool) {
        let label = running ? "Cancel formatting" : "Format message professionally"
        button.image = NSImage(systemSymbolName: running ? "xmark" : "sparkles", accessibilityDescription: label)
        button.toolTip = label
    }

    @objc private func clicked() { action() }

    /// Reads only the focused field's type and position, never its text.
    private func refresh() {
        guard Accessibility.isTrusted, let app = Composer.frontmostWhatsApp(),
              let element = Composer.focusedElement(pid: app.processIdentifier), Composer.isComposer(element),
              !Composer.isInMinimizedWindow(element),
              let composer = Composer.frame(element), let height = NSScreen.screens.first?.frame.height else {
            panel.orderOut(nil)
            return
        }
        let frame = Self.frame(composer: composer, primaryScreenHeight: height)
        guard Self.isOnScreen(frame, screens: NSScreen.screens.map(\.frame)) else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }

    /// Accessibility can report junk frames for windows that are going away, and AppKit throws on non-finite ones.
    static func isOnScreen(_ frame: NSRect, screens: [NSRect]) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && screens.contains { $0.intersects(frame) }
    }

    /// Accessibility frames start at the primary screen's top left, AppKit's at its bottom left.
    /// Tall composers keep the button on the last line.
    static func frame(composer: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(
            x: composer.maxX - size - 4,
            y: primaryScreenHeight - composer.maxY + (min(composer.height, 36) - size) / 2,
            width: size,
            height: size
        )
    }
}
