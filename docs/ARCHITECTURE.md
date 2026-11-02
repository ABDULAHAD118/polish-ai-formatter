# Architecture

```
WhatsApp Web                          WhatsApp for macOS
     |                                       |
content.js (button, read, replace)    Composer.swift (Accessibility, clipboard fallback)
     | port (cancel = disconnect)            |
background.js (keys, Origin rule)     FormatController.swift (flow, edit checks)
     |                                       |
ai-core.js  <----- same behaviour ----->  AIClient.swift
     |                                       |
     +------- Ollama / Claude / OpenAI / Gemini -------+

packages/shared-config/config.json: prompt, modes, providers, defaults, copied into both apps
```

## Decisions

- **Shared config plus two thin clients, with no local daemon.** Ollama is already the shared local service. A second background service would add install steps and failure modes. JavaScript and Swift cannot share code, so the prompt and defaults are shared as data and both clients have matching tests.
- **The structure differs from the original outline.** `ai-core`, `prompt-engine`, and `shared-config` collapsed into one config file and one client per platform. Popup and options are the same page.
- **No build step for the extension.** Plain ES modules and one classic content script, with `jsdom` as the only dev dependency.
- **SwiftPM with Command Line Tools.** `CoreChecks` is an executable rather than an XCTest target, because Command Line Tools has no XCTest. The app has a `--self-test` flag for AppKit, Carbon, Keychain, and pasteboard checks.

## Replacing the draft

WhatsApp Web's composer is a Lexical editor, so editing its DOM would desynchronise it. The extension selects all and dispatches a synthetic `paste`, which goes through Lexical's own handler. `execCommand('insertText')` is the fallback. The result is read back and verified, and the original is restored on failure.

The macOS app sets the selected text through Accessibility, falls back to setting the value, then falls back to clipboard paste. Each result is verified when the field can be read.

## Safety checks before replacing

1. The response is parsed for its provider, and truncated or refused responses are rejected.
2. `<think>` blocks and wrapping quotes are removed.
3. Empty responses and commentary are rejected.
4. Digit runs must match the draft in both directions, and links must survive. Custom mode skips this, because you may ask for a translation.
5. The composer must still hold exactly the original draft. On macOS it must also still be focused, with WhatsApp frontmost.

## Keeping Ollama working from an extension

Ollama rejects `chrome-extension://` origins. A session `declarativeNetRequest` rule removes the `Origin` header, limited to `tabIds: [-1]` so it applies to the extension's worker and not to web pages. Without that limit, any web page could reach Ollama without an origin check.

## Slow local models

Requests are started in the service worker, so WhatsApp's page CSP does not apply. The content script pings the open port every 20 seconds so Chrome does not stop the worker during a slow request. Closing the port aborts the request.
