// Runs on web.whatsapp.com. Reads only the unsent draft in the open chat's composer.
// This file must never click Send or dispatch Enter: the user always sends.
(() => {
  const HOST_ID = 'waf-format-host';
  const COMPOSER_SELECTORS = [
    'footer [contenteditable="true"][role="textbox"]',
    'footer [contenteditable="true"][data-lexical-editor]',
    '#main [contenteditable="true"][data-tab="10"]',
    '#main footer [contenteditable="true"]',
  ];
  const SPARKLES = '<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" fill="currentColor"><path d="M11 3l1.9 5.1L18 10l-5.1 1.9L11 17l-1.9-5.1L4 10l5.1-1.9L11 3zm7.5 11l.9 2.6 2.6.9-2.6.9-.9 2.6-.9-2.6-2.6-.9 2.6-.9.9-2.6z"/></svg>';

  const CSS = `
    :host { all: initial; display: flex; align-items: center; flex: none; position: relative; margin: 0 6px;
      font: 500 13px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      --bg: #e7f8ee; --fg: #0b6b45; --hover: #d3f2e0; --line: #bfe8d0; --panel: #fff; --panel-fg: #111b21; --panel-hover: #f0f2f5; --err: #b42318; --err-bg: #fdecea; }
    :host([data-theme="dark"]) { --bg: #103529; --fg: #7fe3b4; --hover: #164534; --line: #1f5a44; --panel: #233138; --panel-fg: #e9edef; --panel-hover: #2f3f47; --err: #ffb4ab; --err-bg: #4a1f1b; }
    .pill { display: flex; height: 32px; border-radius: 16px; background: var(--bg); color: var(--fg); overflow: hidden; }
    .pill.error { background: var(--err-bg); color: var(--err); }
    button { all: unset; box-sizing: border-box; cursor: pointer; display: flex; align-items: center; gap: 6px; height: 100%; transition: background .15s; }
    button:hover { background: var(--hover); }
    .pill.error button:hover { background: transparent; }
    button:focus-visible { outline: 2px solid currentColor; outline-offset: -2px; border-radius: 16px; }
    .main { padding: 0 10px 0 12px; white-space: nowrap; }
    .caret { padding: 0 8px; border-left: 1px solid var(--line); font-size: 10px; }
    .spin { width: 13px; height: 13px; border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin .8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .menu, .toast { position: absolute; bottom: calc(100% + 10px); right: 0; z-index: 1000; background: var(--panel); color: var(--panel-fg); border-radius: 12px; box-shadow: 0 6px 24px rgba(0,0,0,.25); }
    .menu { padding: 6px; min-width: 210px; }
    .menu button { width: 100%; height: 34px; padding: 0 10px; border-radius: 8px; }
    .menu button:hover { background: var(--panel-hover); }
    .menu button[aria-checked="true"]::after { content: "✓"; margin-left: auto; }
    .menu hr { border: 0; border-top: 1px solid var(--panel-hover); margin: 6px 0; }
    .toast { padding: 10px 12px; width: 280px; line-height: 1.4; font-weight: 400; }
    [hidden] { display: none !important; }
    @media (prefers-reduced-motion: reduce) { .spin { animation-duration: 2.4s; } button { transition: none; } }
  `;

  function findComposer() {
    for (const selector of COMPOSER_SELECTORS) {
      const el = [...document.querySelectorAll(selector)].find((e) => !e.closest('#side'));
      if (el) return el;
    }
    return null;
  }

  function textOf(node) {
    let out = '';
    for (const child of node.childNodes) {
      if (child.nodeType === 3) out += child.nodeValue;
      else if (child.nodeName === 'BR') out += '\n';
      else if (child.nodeName === 'IMG') out += child.getAttribute('alt') ?? '';
      else out += textOf(child);
    }
    return out;
  }

  // Each line is its own <p>, and a blank line is <p><br></p>. innerText would double the breaks.
  function readDraft(composer) {
    const lines = [...composer.children].filter((c) => c.nodeName === 'P');
    return (lines.length ? lines.map((p) => textOf(p).replace(/\n$/, '')).join('\n') : textOf(composer)).trim();
  }

  function selectAll(composer) {
    composer.focus();
    const range = document.createRange();
    range.selectNodeContents(composer);
    const selection = getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  const settle = () => new Promise((resolve) => setTimeout(resolve, 60));

  async function writeDraft(composer, text) {
    // A synthetic paste goes through the editor's own handler, so its state stays correct.
    selectAll(composer);
    const clipboardData = new DataTransfer();
    clipboardData.setData('text/plain', text);
    composer.dispatchEvent(new ClipboardEvent('paste', { clipboardData, bubbles: true, cancelable: true }));
    await settle();
    if (readDraft(composer) === text) return true;
    selectAll(composer);
    document.execCommand?.('insertText', false, text);
    await settle();
    return readDraft(composer) === text;
  }

  async function replaceDraft(composer, original, text) {
    if (await writeDraft(composer, text)) return true;
    if (readDraft(composer) !== original) await writeDraft(composer, original);
    return false;
  }

  let ui = null;
  let port = null;
  let keepalive = null;
  let resetTimer = null;
  let modes = [];
  let currentMode = 'professional';

  function setState(state, message) {
    if (!ui) return;
    clearTimeout(resetTimer);
    const labels = { idle: 'Format', loading: 'Formatting...', success: 'Formatted', error: 'Format failed' };
    ui.pill.classList.toggle('error', state === 'error');
    ui.main.textContent = '';
    if (state === 'loading') {
      const spinner = document.createElement('span');
      spinner.className = 'spin';
      ui.main.append(spinner);
    } else {
      ui.main.insertAdjacentHTML('beforeend', SPARKLES);
    }
    ui.main.append(labels[state]);
    ui.main.title = state === 'loading' ? 'Click to cancel' : 'Format message professionally';
    ui.main.setAttribute('aria-label', state === 'loading' ? 'Formatting. Click to cancel.' : labels[state]);
    ui.main.dataset.state = state;
    ui.toast.textContent = message ?? '';
    ui.toast.hidden = !message;
    if (state === 'success') resetTimer = setTimeout(() => setState('idle'), 2500);
    if (state === 'error') resetTimer = setTimeout(() => setState('idle'), 9000);
  }

  function closePort() {
    clearInterval(keepalive);
    const p = port;
    port = null;
    try {
      p?.disconnect();
    } catch {}
  }

  async function onReply(reply, draft) {
    closePort();
    if (reply.error) return setState('error', reply.error.message);
    const composer = findComposer();
    if (!composer) {
      return setState('error', 'The message box was not found, so nothing was changed. Reopen the chat and try again.');
    }
    if (readDraft(composer) !== draft) {
      return setState('error', 'The draft changed while formatting, so your version was kept. Click Format again.');
    }
    const replaced = await replaceDraft(composer, draft, reply.text);
    if (replaced) setState('success');
    else setState('error', "Could not update the draft. WhatsApp's interface may have changed. Your draft was kept.");
  }

  function startFormatting() {
    const composer = findComposer();
    if (!composer) return setState('error', 'The message box was not found. Open a chat first.');
    const draft = readDraft(composer);
    if (!draft) return setState('error', 'Write a message first.');
    setState('loading');
    try {
      port = chrome.runtime.connect({ name: 'format' });
    } catch {
      return setState('error', 'The extension was updated. Reload this page.');
    }
    const thisPort = port;
    thisPort.onMessage.addListener((reply) => onReply(reply, draft));
    thisPort.onDisconnect.addListener(() => {
      if (port !== thisPort) return;
      closePort();
      setState('error', 'The formatter stopped unexpectedly. Your draft was not changed. Try again.');
    });
    thisPort.postMessage({ type: 'start', draft, modeId: currentMode });
    // Keeps the extension's service worker alive while a slow local model works.
    keepalive = setInterval(() => thisPort.postMessage({ type: 'ping' }), 20000);
  }

  function onMainClick() {
    ui.menu.hidden = true;
    if (port) {
      closePort();
      setState('idle');
    } else {
      startFormatting();
    }
  }

  function renderMenu() {
    ui.menu.textContent = '';
    for (const mode of modes) {
      const item = document.createElement('button');
      item.type = 'button';
      item.setAttribute('role', 'menuitemradio');
      item.setAttribute('aria-checked', String(mode.id === currentMode));
      item.textContent = mode.name;
      item.addEventListener('click', () => {
        currentMode = mode.id;
        chrome.runtime.sendMessage({ type: 'setMode', mode: mode.id });
        ui.menu.hidden = true;
        renderMenu();
      });
      ui.menu.append(item);
    }
    ui.menu.append(document.createElement('hr'));
    const settings = document.createElement('button');
    settings.type = 'button';
    settings.textContent = 'Settings…';
    settings.addEventListener('click', () => {
      ui.menu.hidden = true;
      chrome.runtime.sendMessage({ type: 'openSettings' });
    });
    ui.menu.append(settings);
  }

  function buildUi() {
    const host = document.createElement('div');
    host.id = HOST_ID;
    const root = host.attachShadow({ mode: 'open' });
    const style = document.createElement('style');
    style.textContent = CSS;
    const pill = document.createElement('div');
    pill.className = 'pill';
    const main = document.createElement('button');
    main.type = 'button';
    main.className = 'main';
    const caret = document.createElement('button');
    caret.type = 'button';
    caret.className = 'caret';
    caret.textContent = '▾';
    caret.title = 'Formatting mode';
    caret.setAttribute('aria-label', 'Choose formatting mode');
    caret.setAttribute('aria-haspopup', 'menu');
    const menu = document.createElement('div');
    menu.className = 'menu';
    menu.setAttribute('role', 'menu');
    menu.hidden = true;
    const toast = document.createElement('div');
    toast.className = 'toast';
    toast.setAttribute('role', 'status');
    toast.hidden = true;
    pill.append(main, caret);
    root.append(style, pill, menu, toast);
    // Keep focus and the caret in the composer when the pill is clicked.
    root.addEventListener('mousedown', (e) => e.preventDefault());
    main.addEventListener('click', onMainClick);
    caret.addEventListener('click', () => {
      ui.toast.hidden = true;
      ui.menu.hidden = !ui.menu.hidden;
    });
    return { host, pill, main, caret, menu, toast };
  }

  function matchTheme(composer) {
    const rgb = getComputedStyle(composer).color.match(/\d+/g)?.map(Number) ?? [0, 0, 0];
    ui.host.dataset.theme = rgb[0] + rgb[1] + rgb[2] > 384 ? 'dark' : 'light';
  }

  // Button goes right after the composer in its flex row. If that row is ever gone, it still
  // appears at the end of the footer.
  function mountPoint(composer) {
    let child = composer;
    while (child.parentElement && child.parentElement.nodeName !== 'FOOTER') {
      const parent = child.parentElement;
      if (parent.children.length >= 3 && getComputedStyle(parent).display === 'flex') {
        return { parent, before: child.nextSibling };
      }
      child = parent;
    }
    return { parent: composer.closest('footer') ?? composer.parentElement, before: null };
  }

  function ensureButton() {
    for (const stale of document.querySelectorAll(`#${HOST_ID}`)) {
      if (!ui || stale !== ui.host) stale.remove();
    }
    const composer = findComposer();
    if (!composer) {
      ui?.host.remove();
      return;
    }
    if (!ui) {
      ui = buildUi();
      renderMenu();
      setState('idle');
    }
    const { parent, before } = mountPoint(composer);
    if (ui.host.parentElement !== parent) parent.insertBefore(ui.host, before);
    matchTheme(composer);
  }

  async function init() {
    try {
      const state = await chrome.runtime.sendMessage({ type: 'uiState' });
      if (state) {
        modes = state.modes;
        currentMode = state.mode;
      }
    } catch {}
    if (ui) renderMenu();
    ensureButton();
    // WhatsApp re-renders constantly, so coalesce the checks.
    let queued = false;
    new MutationObserver(() => {
      if (queued) return;
      queued = true;
      setTimeout(() => {
        queued = false;
        ensureButton();
      }, 150);
    }).observe(document.body, { childList: true, subtree: true });
  }

  if (globalThis.__WAF_TEST__) {
    globalThis.__WAF_TEST__.api = { findComposer, readDraft, replaceDraft, ensureButton, init, getUi: () => ui };
  } else {
    init();
  }
})();
