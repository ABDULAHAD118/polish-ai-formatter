import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FormatterCore
import Security
import ServiceManagement

enum Keychain {
    private static let service = "com.local.whatsapp-ai-formatter"

    static func read(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ account: String, _ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct Shortcut: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(controlKey | optionKey | cmdKey))

    var display: String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out + Shortcut.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(code)" }
        let data = unsafeBitCast(raw, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        return length > 0 ? String(utf16CodeUnits: chars, count: length).uppercased() : "Key \(code)"
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if flags.contains(.command) { out |= UInt32(cmdKey) }
        if flags.contains(.option) { out |= UInt32(optionKey) }
        if flags.contains(.control) { out |= UInt32(controlKey) }
        if flags.contains(.shift) { out |= UInt32(shiftKey) }
        return out
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    private let config = SharedConfig.shared

    @Published var provider: String { didSet { defaults.set(provider, forKey: "provider") } }
    @Published var mode: String { didSet { defaults.set(mode, forKey: "mode") } }
    @Published var customInstructions: String { didSet { defaults.set(customInstructions, forKey: "customInstructions") } }
    @Published var timeoutSeconds: Double { didSet { defaults.set(timeoutSeconds, forKey: "timeoutSeconds") } }
    @Published var ollamaBaseUrl: String { didSet { defaults.set(ollamaBaseUrl, forKey: "ollamaBaseUrl") } }
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    @Published var shortcut: Shortcut {
        didSet {
            defaults.set(Int(shortcut.keyCode), forKey: "shortcutKey")
            defaults.set(Int(shortcut.carbonModifiers), forKey: "shortcutMods")
        }
    }

    private init() {
        provider = defaults.string(forKey: "provider") ?? config.defaults.provider
        mode = defaults.string(forKey: "mode") ?? config.defaults.mode
        customInstructions = defaults.string(forKey: "customInstructions") ?? ""
        let timeout = defaults.double(forKey: "timeoutSeconds")
        timeoutSeconds = timeout > 0 ? timeout : config.defaults.timeoutSeconds
        ollamaBaseUrl = defaults.string(forKey: "ollamaBaseUrl") ?? config.providers["ollama"]!.baseUrl
        autoCheckUpdates = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
        if defaults.object(forKey: "shortcutKey") != nil {
            shortcut = Shortcut(keyCode: UInt32(defaults.integer(forKey: "shortcutKey")), carbonModifiers: UInt32(defaults.integer(forKey: "shortcutMods")))
        } else {
            shortcut = .default
        }
    }

    func model(for provider: String) -> String {
        defaults.string(forKey: "model.\(provider)") ?? config.providers[provider]?.defaultModel ?? ""
    }

    func setModel(_ model: String, for provider: String) {
        defaults.set(model, forKey: "model.\(provider)")
        objectWillChange.send()
    }

    func aiSettings(apiKey: String? = nil) -> AISettings {
        AISettings(
            provider: provider,
            model: model(for: provider),
            apiKey: apiKey ?? (provider == "ollama" ? "" : Keychain.read(provider)),
            baseUrl: ollamaBaseUrl,
            mode: mode,
            customInstructions: customInstructions,
            timeoutSeconds: timeoutSeconds
        )
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Global shortcut through Carbon, which reports when another app already owns the combination.
final class HotKeyManager {
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    fileprivate var action: (() -> Void)?

    enum RegisterResult { case ok, conflict, failed(OSStatus) }

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> RegisterResult {
        self.action = action
        unregister()
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().action?()
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x57414654), id: 1) // "WAFT"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetEventDispatcherTarget(), 0, &ref)
        if status == OSStatus(eventHotKeyExistsErr) { return .conflict }
        return status == noErr ? .ok : .failed(status)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// Saves every clipboard item and format, then restores them after a fallback copy or paste.
struct ClipboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard = .general) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(_ pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let restored = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
