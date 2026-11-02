import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FormatterCore

/// Finds and edits the focused WhatsApp composer. Reads only that field, never the chat.
/// This file must never post Return or Enter: the user always sends.
enum Composer {
    static let bundleId = SharedConfig.shared.whatsAppBundleId

    static func isWhatsApp(bundleId id: String?) -> Bool { id == bundleId }

    static func frontmostWhatsApp() -> NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        return isWhatsApp(bundleId: app?.bundleIdentifier) ? app : nil
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func looksLikeComposer(role: String?, subrole: String?, labels: [String], valueSettable: Bool) -> Bool {
        guard role == kAXTextAreaRole as String || role == kAXTextFieldRole as String else { return false }
        if subrole == kAXSearchFieldSubrole as String { return false }
        if labels.contains(where: { $0.lowercased().contains("search") }) { return false }
        return valueSettable
    }

    static func labels(_ element: AXUIElement) -> [String] {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXIdentifierAttribute]
            .compactMap { attribute(element, $0) as? String }
    }

    static func isComposer(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return looksLikeComposer(
            role: attribute(element, kAXRoleAttribute) as? String,
            subrole: attribute(element, kAXSubroleAttribute) as? String,
            labels: labels(element),
            valueSettable: settable.boolValue
        )
    }

    static func read(_ element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute) as? String
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func replaceWithAccessibility(_ element: AXUIElement, text: String, original: String) -> Bool {
        // Selecting then setting the selected text behaves like typing, so undo keeps working.
        var range = CFRange(location: 0, length: (original as NSString).length)
        if let axRange = AXValueCreate(.cfRange, &range),
           AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
           read(element) == text {
            return true
        }
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success && read(element) == text
    }

    // Clipboard fallback for fields that ignore Accessibility writes.

    private static func press(_ key: Int) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    /// The user may still be holding the shortcut, which would change what these key presses do.
    static func waitForModifierRelease() async {
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    static func copyDraftViaClipboard() async -> String? {
        await waitForModifierRelease()
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot(pasteboard)
        defer { snapshot.restore(pasteboard) }
        let before = pasteboard.changeCount
        press(kVK_ANSI_A)
        press(kVK_ANSI_C)
        for _ in 0..<20 where pasteboard.changeCount == before {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return pasteboard.changeCount == before ? nil : pasteboard.string(forType: .string)
    }

    static func pasteViaClipboard(_ text: String) async {
        await waitForModifierRelease()
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        press(kVK_ANSI_A)
        press(kVK_ANSI_V)
        // The target app reads the clipboard asynchronously, so restore only after it has pasted.
        try? await Task.sleep(nanoseconds: 400_000_000)
        snapshot.restore(pasteboard)
    }

    /// Prints the focused element's shape, never its text, for diagnosing WhatsApp UI changes.
    static func diagnostics() -> String {
        guard Accessibility.isTrusted else { return "Accessibility permission: not granted" }
        guard let app = frontmostWhatsApp() else { return "WhatsApp is not the active app. Frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")" }
        guard let element = focusedElement(pid: app.processIdentifier) else { return "WhatsApp has no focused element exposed" }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        return """
        role: \(attribute(element, kAXRoleAttribute) as? String ?? "nil")
        subrole: \(attribute(element, kAXSubroleAttribute) as? String ?? "nil")
        labels: \(labels(element))
        value length: \(read(element).map { String($0.count) } ?? "unreadable")
        value settable: \(settable.boolValue)
        detected as composer: \(isComposer(element))
        frame: \(frame(element).map { "\($0)" } ?? "nil")
        attributes: \((names as? [String]) ?? [])
        """
    }
}
