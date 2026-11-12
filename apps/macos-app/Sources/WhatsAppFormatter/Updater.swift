import AppKit
import FormatterCore

/// Checks GitHub Releases for a newer universal macOS build, asks, then swaps the app bundle and relaunches.
@MainActor
enum Updater {
    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// `userInitiated` shows "up to date" and errors; the launch check stays silent unless there is an update.
    static func check(userInitiated: Bool) {
        Task {
            do {
                let url = URL(string: "https://api.github.com/repos/\(SharedConfig.shared.releasesRepo)/releases/latest")!
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let release = try JSONDecoder().decode(Release.self, from: data)
                guard isNewerVersion(release.tag_name, than: currentVersion) else {
                    if userInitiated { alert("You're up to date", "TextPolish \(currentVersion) is the latest version.") }
                    return
                }
                offer(release)
            } catch {
                if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    private static func offer(_ release: Release) {
        let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let a = NSAlert()
        a.messageText = "\(release.name ?? "TextPolish \(release.tag_name)") is available"
        a.informativeText = "You have \(currentVersion).\n\n" + (notes.count > 1500 ? notes.prefix(1500) + "…" : notes)
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let asset = release.assets.first(where: { $0.name.hasSuffix("-macOS-universal.zip") }) else {
            NSWorkspace.shared.open(release.html_url)
            return
        }
        Task {
            do {
                try await install(from: asset.browser_download_url)
            } catch {
                alert("Update failed", "\(error.localizedDescription)\n\nYou can download it from the release page instead.")
                NSWorkspace.shared.open(release.html_url)
            }
        }
    }

    private static func install(from url: URL) async throws {
        let dest = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "TextPolish can't write to \(dest.deletingLastPathComponent().path)."])
        }
        let (zip, _) = try await URLSession.shared.download(from: url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TextPolish-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "The download isn't a TextPolish app."])
        }
        // Paths go in as arguments, never into the script text. The script outlives this process.
        let script = #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; rm -rf "$3" && /usr/bin/ditto "$2" "$3" && /usr/bin/open "$3""#
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), app.path, dest.path]
        try swap.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Updater", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Couldn't unpack the update."])
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
