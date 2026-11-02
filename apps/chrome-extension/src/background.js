import { AIError, checkConnection, formatDraft, resolveSettings } from './ai-core.js';

// Service workers reject top-level await, so handlers wait on this promise instead.
const configReady = fetch(chrome.runtime.getURL('src/config.json')).then((r) => r.json());

// API keys live here, so keep this storage away from the content script running on the page.
chrome.storage.local.setAccessLevel({ accessLevel: 'TRUSTED_CONTEXTS' });

// Ollama rejects chrome-extension:// origins. tabIds [-1] limits this to the extension's own
// worker, so web pages keep getting Ollama's normal origin check.
const originRuleReady = chrome.declarativeNetRequest.updateSessionRules({
  removeRuleIds: [1],
  addRules: [{
    id: 1,
    action: { type: 'modifyHeaders', requestHeaders: [{ header: 'origin', operation: 'remove' }] },
    condition: {
      requestDomains: ['127.0.0.1', 'localhost'],
      resourceTypes: ['xmlhttprequest', 'other'],
      tabIds: [chrome.tabs.TAB_ID_NONE],
    },
  }],
});

const loadSettings = async () => resolveSettings((await chrome.storage.local.get('settings')).settings, await configReady);

const errorPayload = (e) => ({
  error: { code: e instanceof AIError ? e.code : 'unexpected', message: e instanceof AIError ? e.message : 'Something went wrong. Your draft was not changed.' },
});

// One port per format request: closing it (cancel, or the tab going away) aborts the request.
chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'format') return;
  const controller = new AbortController();
  port.onDisconnect.addListener(() => controller.abort());
  port.onMessage.addListener(async (msg) => {
    if (msg.type !== 'start') return; // Other messages are keepalive pings for slow local models.
    let reply;
    try {
      await originRuleReady;
      const text = await formatDraft({
        settings: await loadSettings(), config: await configReady, draft: msg.draft, modeId: msg.modeId, signal: controller.signal,
      });
      reply = { text };
    } catch (e) {
      reply = errorPayload(e);
    }
    if (!controller.signal.aborted) port.postMessage(reply);
  });
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === 'uiState') {
    // Only what the composer button needs. Never settings with API keys.
    Promise.all([loadSettings(), configReady]).then(([s, config]) => sendResponse({
      mode: s.mode,
      modes: config.modes.map(({ id, name }) => ({ id, name })),
    }));
    return true;
  }
  if (msg.type === 'setMode') {
    chrome.storage.local.get('settings').then(({ settings }) => {
      chrome.storage.local.set({ settings: { ...settings, mode: msg.mode } }).then(() => sendResponse({}));
    });
    return true;
  }
  if (msg.type === 'checkConnection') {
    (async () => {
      try {
        await originRuleReady;
        const config = await configReady;
        sendResponse(await checkConnection({ settings: resolveSettings(msg.settings, config), config }));
      } catch (e) {
        sendResponse(errorPayload(e));
      }
    })();
    return true;
  }
  if (msg.type === 'openSettings') chrome.runtime.openOptionsPage();
  return false;
});
