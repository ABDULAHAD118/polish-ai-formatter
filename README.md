# TextPolish: Message Formatter

Not affiliated with or endorsed by WhatsApp or Meta.

Write a rough message in WhatsApp, trigger the formatter, and the draft is replaced with a polished version in the same message box. You review it and send it yourself. **It never sends messages.**

- **WhatsApp Web in Chrome:** a **Format** button next to the message box.
- **WhatsApp for macOS:** a menu-bar app with a button on the message box and a global shortcut, by default `⌃⌥⌘F`.
- **Windows and Linux:** a tray app with the shortcut `Ctrl+Alt+F`, for the WhatsApp app or WhatsApp Web.
- **Updates:** each app checks GitHub Releases, shows what's new, and asks before installing.
- **AI provider of your choice:** Ollama (local, default, free), or the Claude, OpenAI, or Gemini API with your own key.
- **Modes:** Professional (default), Professional + Friendly, Short & Clear, Polite, Grammar Fix, Custom Instructions.

| Provider | Where your draft goes | Needs |
| --- | --- | --- |
| Ollama (default) | Stays on your computer | Ollama and a model |
| Claude API | Anthropic | Your API key |
| OpenAI API | OpenAI | Your API key |
| Gemini API | Google | Your API key |

## Quick start

```bash
brew install --cask ollama-app && open /Applications/Ollama.app
ollama pull qwen2.5:3b
npm install
npm run build
```

- **Chrome:** open `chrome://extensions`, turn on Developer mode, click **Load unpacked**, and choose `dist/TextPolish-extension`.
- **macOS:** double-click `dist/TextPolish-macOS-<arch>.pkg` to install, open TextPolish, and allow Accessibility access. Or download the `.pkg` from the latest release.

Full steps: [docs/INSTALLATION.md](docs/INSTALLATION.md). Problems: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). Data handling: [docs/PRIVACY.md](docs/PRIVACY.md). Design: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Development

```bash
npm test           # extension and AI client tests (Node, jsdom)
npm run test:mac   # Swift core checks and app self-test
npm run live       # real drafts through local Ollama; optional model name after --
npm run build      # Chrome extension and macOS app into dist/
npm run build:windows  # Windows installer into dist/windows/
npm run build:linux    # Linux AppImage into dist/linux/
```

Releases: push a tag such as `v1.2.0`, and `.github/workflows/release.yml` builds and publishes everything. The Windows and Linux apps (`apps/windows-app`, `apps/linux-app`) share their Electron main process in `packages/desktop-core` and reuse the extension's AI client and settings page.

`packages/shared-config/config.json` holds the prompt, modes, providers, and defaults. Edit it there, because `scripts/sync-config.sh` copies it into both apps and a test fails if the copies differ.
