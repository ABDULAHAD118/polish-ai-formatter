import AppKit
import FormatterCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    let reregisterShortcut: (Shortcut) -> HotKeyManager.RegisterResult

    private let config = SharedConfig.shared
    @State private var apiKey = ""
    @State private var model = ""
    @State private var models: [String] = []
    @State private var status = "Not checked"
    @State private var statusColor = Color.secondary
    @State private var checking = false
    @State private var trusted = Accessibility.isTrusted
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError = ""
    @State private var recording = false
    @State private var recorder: Any?
    @State private var shortcutMessage = ""

    private let trustTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    private var isLocal: Bool { config.providers[settings.provider]?.local ?? false }

    var body: some View {
        Form {
            Section("AI provider") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(SharedConfig.providerOrder, id: \.self) { id in
                        Text(config.providers[id]?.name ?? id).tag(id)
                    }
                }
                Text(isLocal ? "Drafts stay on this computer." : "Drafts you format are sent to \(config.providers[settings.provider]?.name ?? ""). Choose Ollama to keep them on this computer.")
                    .font(.caption)
                    .foregroundStyle(isLocal ? Color.secondary : Color.orange)
                if isLocal {
                    TextField("Ollama address", text: $settings.ollamaBaseUrl)
                } else {
                    SecureField("API key", text: $apiKey)
                        .onChange(of: apiKey) { Keychain.write(settings.provider, $0) }
                    Text("Stored in your macOS Keychain. Sent only to the provider you selected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Model", text: $model)
                        .onChange(of: model) { settings.setModel($0, for: settings.provider) }
                    if !models.isEmpty {
                        Menu("Choose") {
                            ForEach(models, id: \.self) { name in Button(name) { model = name } }
                        }
                        .fixedSize()
                    }
                }
                HStack {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(status).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(checking ? "Checking…" : "Test AI connection", action: test).disabled(checking)
                }
            }

            Section("Formatting") {
                Picker("Default mode", selection: $settings.mode) {
                    ForEach(config.modes) { Text($0.name).tag($0.id) }
                }
                TextField("Custom instructions", text: $settings.customInstructions, axis: .vertical)
                    .lineLimit(2...4)
                Stepper(value: $settings.timeoutSeconds, in: 10...600, step: 10) {
                    Text("Request timeout: \(Int(settings.timeoutSeconds)) seconds")
                }
            }

            Section("Keyboard shortcut") {
                HStack {
                    Text("Format the WhatsApp draft")
                    Spacer()
                    Button(recording ? "Press keys… (Esc cancels)" : settings.shortcut.display, action: toggleRecording)
                }
                if !shortcutMessage.isEmpty {
                    Text(shortcutMessage).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Permissions") {
                HStack {
                    Circle().fill(trusted ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text(trusted ? "Accessibility access granted" : "Accessibility access needed")
                    Spacer()
                    if !trusted {
                        Button("Open System Settings") {
                            Accessibility.requestPrompt()
                            Accessibility.openSettings()
                        }
                    }
                }
                if !trusted {
                    Text("System Settings › Privacy & Security › Accessibility: turn on TextPolish. It is used only to read and replace the draft in the focused message box.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            try LaunchAtLogin.set(enabled)
                            launchError = ""
                        } catch {
                            launchError = "Could not change this. Move the app to Applications and try again."
                        }
                    }
                if !launchError.isEmpty { Text(launchError).font(.caption).foregroundStyle(.orange) }
            }

            Section("About") {
                Text("TextPolish \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")").font(.callout)
                Text("Rewrites only the unsent draft in the focused message box. It never sends messages and never stores drafts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 660)
        .onAppear { loadProvider(); test() }
        .onChange(of: settings.provider) { _ in loadProvider(); test() }
        .onReceive(trustTimer) { _ in trusted = Accessibility.isTrusted }
        .onDisappear { stopRecording() }
    }

    private func loadProvider() {
        model = settings.model(for: settings.provider)
        apiKey = isLocal ? "" : Keychain.read(settings.provider)
        models = []
    }

    private func test() {
        checking = true
        status = "Checking…"
        statusColor = .secondary
        let s = settings.aiSettings(apiKey: apiKey)
        Task {
            defer { checking = false }
            do {
                let result = try await AIClient().checkConnection(s)
                models = result.models
                if result.modelAvailable {
                    status = "Connected: \(s.model)"
                    statusColor = .green
                } else {
                    status = isLocal
                        ? "Connected, but \"\(s.model)\" is not installed. Run: ollama pull \(s.model). If it is downloading, wait for it to finish."
                        : "Connected, but \"\(s.model)\" is not available. Choose a model."
                    statusColor = .orange
                }
            } catch let error as AIError {
                status = error.message
                statusColor = .red
            } catch {
                status = "Connection failed."
                statusColor = .red
            }
        }
    }

    private func toggleRecording() {
        if recording { return stopRecording() }
        recording = true
        shortcutMessage = ""
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let mods = Shortcut.carbonModifiers(from: event.modifierFlags)
            // Shift alone would collide with ordinary typing.
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false else {
                shortcutMessage = "Use at least one of Command, Control, or Option."
                return nil
            }
            apply(Shortcut(keyCode: UInt32(event.keyCode), carbonModifiers: mods))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recording = false
    }

    private func apply(_ shortcut: Shortcut) {
        let previous = settings.shortcut
        switch reregisterShortcut(shortcut) {
        case .ok:
            settings.shortcut = shortcut
            shortcutMessage = ""
        case .conflict:
            _ = reregisterShortcut(previous)
            shortcutMessage = "\(shortcut.display) is already used by another app. Kept \(previous.display)."
        case .failed:
            _ = reregisterShortcut(previous)
            shortcutMessage = "macOS rejected \(shortcut.display). Kept \(previous.display)."
        }
    }
}
