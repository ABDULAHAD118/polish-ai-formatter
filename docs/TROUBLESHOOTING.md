# Troubleshooting

Formatting failures never change your draft.

## AI errors

| Message | What to do |
| --- | --- |
| Cannot reach Ollama | Install Ollama from https://ollama.com, or start it with `open /Applications/Ollama.app` or `ollama serve`. Check it with `curl http://127.0.0.1:11434/api/version`. |
| Model is not installed | Run `ollama pull <model>`. If a download is running, wait for it to finish. Check with `ollama list`. |
| Ollama refused the request origin | Restart Chrome and reload the extension. If it continues, set `OLLAMA_ORIGINS=chrome-extension://*` and restart Ollama. |
| The AI took too long | The first request on a slower Mac can take minutes. Raise the timeout in Settings or use a smaller model. |
| AI returned an empty or unexpected response | Try again. If it repeats, try another model. |
| The AI changed a number or link | The result was rejected to protect your facts. Try again or switch to Grammar Fix. This also triggers if the model writes numbers differently, such as `5/11` as `May 11`. |
| Rejected the API key | Check or replace the key in Settings, and check that the account has API access. |
| Rate limit or quota reached | Wait, or check your provider plan and billing. |
| Claude, OpenAI, or Gemini declined this message | The provider's safety system refused it. Edit the draft or use Ollama. |
| Custom mode has no instructions | Add them in Settings, or choose another mode. |

## Chrome extension

- **No Format button.** Open a chat, then reload WhatsApp Web. Check that the extension is enabled in `chrome://extensions`. After you update the extension, reload WhatsApp Web.
- **"Could not update the draft" or the button is missing after a WhatsApp update.** WhatsApp may have changed its page. Selectors are at the top of `apps/chrome-extension/src/content.js`.
- **"The draft changed while formatting."** You typed or switched chats during formatting, so your version was kept. Click Format again.
- **"The formatter stopped unexpectedly."** Chrome stopped the extension's worker. Try again. Reload the extension if it repeats.

## macOS app

- **"Allow Accessibility access."** Turn on the app in System Settings > Privacy & Security > Accessibility. If it is already on after a rebuild, remove it with the minus button and add it again.
- **"Open WhatsApp and click in the message box first."** WhatsApp must be the active app with the cursor in the message box. Search boxes are refused on purpose.
- **Shortcut is used by another app.** Settings shows the conflict and keeps the working shortcut. Record a different one.
- **Diagnostics.** To print the focused field's type without its text, switch to WhatsApp within 5 seconds of running:
  ```bash
  sleep 5; "/Applications/TextPolish.app/Contents/MacOS/WhatsAppFormatter" --ax-dump
  ```
  Run this from a terminal that has Accessibility access.
- **Launch at login fails.** Move the app to Applications first.
