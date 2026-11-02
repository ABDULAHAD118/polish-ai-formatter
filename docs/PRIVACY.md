# Privacy

## What is read

- Only the unsent draft in the message box of the open chat, and only when you click **Format** or press the shortcut.
- Chat history and contacts are not read. On the macOS app, the Accessibility permission technically allows more, but the code reads only the focused message box.

## Where your draft goes

| Provider | Destination |
| --- | --- |
| Ollama (default) | Your own computer. The app refuses an Ollama address that is not on this computer. |
| Claude API | Anthropic, under your API account's terms |
| OpenAI API | OpenAI, under your API account's terms |
| Gemini API | Google, under your API account's terms. Free-tier data may be used by Google to improve its products, so check its terms. |

Cloud providers are used only if you choose one and add your own key. Settings shows a notice while one is selected. The project has no server of its own and contains no analytics.

## What is stored

- **Drafts and results:** never stored or logged by this project. They exist in memory during the request. Ollama and cloud providers have their own logging and retention behaviour.
- **Settings:** in `chrome.storage.local` for the extension and `UserDefaults` for the macOS app.
- **API keys:** in `chrome.storage.local` for the extension, which is not synced and is blocked from the code that runs on the WhatsApp page. In the macOS Keychain for the app. Keys are sent only to the provider they belong to. Chrome storage is not encrypted on disk.

## Clipboard

The macOS app uses the clipboard only as a fallback when WhatsApp ignores an Accessibility action. It saves your clipboard first and restores it afterwards. Clipboard manager apps may still record the temporary contents.

## Sending

Neither app has code that clicks Send or presses Return. You always send the message yourself.

## Permissions

| Permission | Why |
| --- | --- |
| `web.whatsapp.com` page access | Show the button and read and replace the draft |
| `127.0.0.1`, `localhost` | Talk to local Ollama |
| `declarativeNetRequestWithHostAccess` | Remove the `Origin` header from the extension's own Ollama requests, because Ollama rejects extension origins by default. Web pages are not affected. |
| Anthropic, OpenAI, and Google API hosts | Used only when you choose that provider |
| `storage` | Save settings |
| macOS Accessibility | Read and replace the focused WhatsApp draft |
