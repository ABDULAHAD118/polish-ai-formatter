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

- `dist/whatsapp-ai-formatter-extension/` and `dist/whatsapp-ai-formatter-extension.zip`
- `dist/WhatsApp AI Formatter.app` and `dist/WhatsApp-AI-Formatter-macOS-<arch>.zip`

The macOS app is built for the architecture of the Mac that builds it.

## 3. Install the Chrome extension

1. Open `chrome://extensions`.
2. Turn on **Developer mode**.
3. Click **Load unpacked** and choose `dist/whatsapp-ai-formatter-extension`.
4. Reload WhatsApp Web, and open a chat. A **Format** button appears next to the message box.
5. Click the extension icon to choose a provider and test the connection.

To use it: write a message, click **Format**, review the result, and send it yourself. The arrow next to the button changes the mode. Click the button while it says **Formatting...** to cancel.

## 4. Install the macOS app

1. Move `WhatsApp AI Formatter.app` to Applications.
2. Open it. The app is not notarized, so macOS may block it the first time. If so, go to System Settings > Privacy & Security and click **Open Anyway**.
3. Settings opens. Click **Open System Settings** and turn on **WhatsApp AI Formatter** under Privacy & Security > Accessibility.

To use it: click in the WhatsApp message box and write a message. A green sparkles button appears at the right of the box. Click it or press `⌃⌥⌘F`, review the result, and send it yourself. Click **✕** or press the shortcut again to cancel. The sparkles icon in the menu bar has the mode list and Settings.

After you rebuild the app, macOS treats it as a new app. Remove its Accessibility entry with the minus button, then add it again.

## Signing for distribution

Builds are ad-hoc signed. To distribute to other Macs, use a Developer ID certificate, then notarize the zip with `notarytool`, which needs an Apple Developer account:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash scripts/build-mac.sh
```
