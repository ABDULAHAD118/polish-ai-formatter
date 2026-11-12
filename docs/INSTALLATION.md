# Installation

## 1. Choose an AI provider

### Ollama (default: local and free)

1. Install and start it:
   ```bash
   brew install --cask ollama-app
   open /Applications/Ollama.app
   ```
   You can also install the app from https://ollama.com. Avoid `brew install ollama` on Intel Macs, because it can compile LLVM from source for hours.
2. Download the default model, about 2 GB:
   ```bash
   ollama pull qwen2.5:3b
   ```

On an Intel Mac, the first request after startup can take a minute or more while the model loads. Later requests are faster.

### Claude, OpenAI, or Gemini (your own key)

Create a key with the provider, then choose the provider and paste the key in Settings. Use **Test connection** to list the models your key can use. Your draft is sent to that provider, and usage is billed by them.

| Provider | Create a key at | Default model |
| --- | --- | --- |
| Claude | https://console.anthropic.com | `claude-opus-5-5` |
| OpenAI | https://platform.openai.com/api-keys | `gpt-6-luna` |
| Gemini | https://aistudio.google.com/apikey | `gemini-3.8-flash` |

Model names change over time. If one stops working, pick another from the Model list in Settings.

## 2. Build

You need Node.js and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```bash
npm install
npm run build
```

This creates:

- `dist/TextPolish-extension/` and `dist/TextPolish-extension.zip`
- `dist/TextPolish.app` and `dist/TextPolish-macOS-<arch>.zip`

The macOS app is built for the architecture of the Mac that builds it. `ARCHS="arm64 x86_64" bash scripts/build-mac.sh` builds a universal app for Apple Silicon and Intel.

`npm run build:windows` and `npm run build:linux` build `dist/windows/TextPolish-Windows-Setup-<version>.exe` and `dist/linux/TextPolish-Linux-<version>-x86_64.AppImage`. Both build on macOS too.

## 3. Install the Chrome extension

1. Open `chrome://extensions`.
2. Turn on **Developer mode**.
3. Click **Load unpacked** and choose `dist/TextPolish-extension`.
4. Reload WhatsApp Web, and open a chat. A **Format** button appears next to the message box.
5. Click the extension icon to choose a provider and test the connection.

To use it: write a message, click **Format**, review the result, and send it yourself. The arrow next to the button changes the mode. Click the button while it says **Formatting...** to cancel.

## 4. Install the macOS app

1. Move `TextPolish.app` to Applications.
2. Open it. The app is not notarized, so macOS may block it the first time. If so, go to System Settings > Privacy & Security and click **Open Anyway**.
3. Settings opens. Click **Open System Settings** and turn on **TextPolish** under Privacy & Security > Accessibility.

To use it: click in the WhatsApp message box and write a message. A green sparkles button appears at the right of the box. Click it or press `⌃⌥⌘F`, review the result, and send it yourself. Click **✕** or press the shortcut again to cancel. The sparkles icon in the menu bar has the mode list and Settings.

After you rebuild the app, macOS treats it as a new app. Remove its Accessibility entry with the minus button, then add it again.

## 5. Install on Windows or Linux

- **Windows:** run `TextPolish-Windows-Setup-<version>.exe`. The installer isn't signed, so SmartScreen may warn: click **More info** > **Run anyway**.
- **Linux:** install `xdotool` (`sudo apt install xdotool`), then `chmod +x TextPolish-Linux-*.AppImage` and run it. It needs an X11 session, or WhatsApp running under XWayland.

To use it: click in the WhatsApp message box (the WhatsApp app, or WhatsApp Web in a browser), write a message, and press `Ctrl+Alt+F`. TextPolish copies the draft, formats it, and pastes the result, then restores your clipboard. Press the shortcut again to cancel. The tray icon has the mode list, Settings, and **Check for Updates**.

## Updates

Every app checks GitHub Releases when it starts, and on demand from **Check for Updates**. It shows what's new and asks before installing:

- **macOS, Windows, Linux AppImage:** downloads the new build, replaces the app, and restarts.
- **Chrome extension:** Settings shows a download link. Unzip it over your extension folder, then click **Reload** in `chrome://extensions`.

On macOS, an ad-hoc signed update counts as a new app, so turn Accessibility on again for it after updating.

## Releasing

Push a version tag. `.github/workflows/release.yml` tests, builds every app, and publishes a release named `TextPolish v1.2.0` with a changelog of the commits since the previous tag:

```bash
git tag v1.2.0 && git push origin v1.2.0
```

You can also run the **Release** workflow from the Actions tab with a version number. `node scripts/set-version.mjs 1.2.0` sets the same version in every app locally.

## Signing for distribution

Builds are ad-hoc signed. To distribute to other Macs, use a Developer ID certificate, then notarize the zip with `notarytool`, which needs an Apple Developer account:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash scripts/build-mac.sh
```
