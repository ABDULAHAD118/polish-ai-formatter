import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { JSDOM } from 'jsdom';

const script = readFileSync(new URL('../src/content.js', import.meta.url), 'utf8');

// Same markup as the real composer inspected on web.whatsapp.com.
const pageHtml = (footer = true) => `<body><div id="side"><div contenteditable="true" role="textbox" id="search"></div></div>
  <div id="main">${footer ? `<footer><div class="row" style="display:flex"><button id="attach"></button><button aria-label="Send" id="send"></button>
  <div class="wrap"><div contenteditable="true" role="textbox" data-lexical-editor="true" data-tab="10" id="composer"></div></div><div id="mic"></div></div></footer>` : ''}</div></body>`;

function setup({ footer = true, reply } = {}) {
  const dom = new JSDOM(pageHtml(footer), { runScripts: 'outside-only', pretendToBeVisual: true });
  const { window } = dom;
  const ports = [];
  window.__WAF_TEST__ = {};
  window.chrome = {
    runtime: {
      sendMessage: async () => ({ mode: 'professional', modes: [{ id: 'professional', name: 'Professional' }, { id: 'short', name: 'Short & Clear' }] }),
      connect: () => {
        const port = {
          sent: [], disconnected: false, listeners: [], onDisconnect: { addListener() {} },
          onMessage: { addListener: (fn) => port.listeners.push(fn) },
          postMessage: (m) => { port.sent.push(m); if (reply && m.type === 'start') setTimeout(() => port.listeners.forEach((fn) => fn(reply)), 0); },
          disconnect: () => { port.disconnected = true; },
        };
        ports.push(port);
        return port;
      },
    },
  };
  // jsdom has no clipboard classes. This stands in for Lexical's paste handler.
  window.DataTransfer = class { setData(_t, v) { this.v = v; } getData() { return this.v; } };
  window.ClipboardEvent = class extends window.Event {
    constructor(type, init) { super(type, init); this.clipboardData = init.clipboardData; }
  };
  const composer = window.document.getElementById('composer');
  composer?.addEventListener('paste', (e) => setDraft(window, e.clipboardData.getData()));
  // Fail on anything that would send the message.
  const sendEvents = [];
  window.document.addEventListener('keydown', (e) => sendEvents.push(e.key), true);
  window.document.getElementById('send')?.addEventListener('click', () => sendEvents.push('send-click'));
  window.eval(script);
  return { window, api: window.__WAF_TEST__.api, composer, ports, sendEvents };
}

function setDraft(window, text) {
  const c = window.document.getElementById('composer');
  c.innerHTML = '';
  for (const line of text.split('\n')) {
    const p = window.document.createElement('p');
    if (line) {
      const span = window.document.createElement('span');
      span.textContent = line;
      p.append(span);
    } else {
      p.append(window.document.createElement('br'));
    }
    c.append(p);
  }
}

const hosts = (window) => window.document.querySelectorAll('#waf-format-host');
const wait = (ms = 120) => new Promise((r) => setTimeout(r, ms));

test('composer detection ignores the chat search box', () => {
  const { api, composer } = setup();
  assert.equal(api.findComposer(), composer);
});

test('no chat open: no composer and no button', () => {
  const { api, window } = setup({ footer: false });
  assert.equal(api.findComposer(), null);
  api.ensureButton();
  assert.equal(hosts(window).length, 0);
});

test('button is injected right after the composer, with spec labels', () => {
  const { api, window } = setup();
  api.ensureButton();
  const host = hosts(window)[0];
  assert.equal(host.previousElementSibling.className, 'wrap');
  const main = host.shadowRoot.querySelector('.main');
  assert.match(main.textContent, /Format/);
  assert.equal(main.title, 'Format message professionally');
  assert.ok(main.querySelector('svg'), 'sparkles icon');
});

test('repeated checks do not create duplicate buttons', () => {
  const { api, window } = setup();
  for (let i = 0; i < 5; i++) api.ensureButton();
  assert.equal(hosts(window).length, 1);
  const leftover = window.document.createElement('div');
  leftover.id = 'waf-format-host';
  window.document.querySelector('footer').append(leftover);
  api.ensureButton();
  assert.equal(hosts(window).length, 1);
});

test('switching chats moves the button to the new composer', () => {
  const { api, window } = setup();
  api.ensureButton();
  const footer = window.document.querySelector('footer');
  const fresh = footer.cloneNode(true);
  fresh.querySelector('#waf-format-host')?.remove();
  footer.replaceWith(fresh);
  api.ensureButton();
  assert.equal(hosts(window).length, 1);
  assert.equal(hosts(window)[0].closest('footer'), fresh);
});

test('observer re-adds the button after WhatsApp removes it', async () => {
  const { api, window } = setup();
  await api.init();
  hosts(window)[0].remove();
  await wait(250);
  assert.equal(hosts(window).length, 1);
});

test('multiline drafts read without doubled line breaks', () => {
  const { api, window, composer } = setup();
  setDraft(window, 'one\ntwo\n\nfour');
  assert.equal(api.readDraft(composer), 'one\ntwo\n\nfour');
});

test('empty composer placeholder reads as empty', () => {
  const { api, composer } = setup();
  composer.innerHTML = '<p><br data-lexical-managed-linebreak="true"></p>';
  assert.equal(api.readDraft(composer), '');
});

test('replacement keeps multiline text', async () => {
  const { api, window, composer } = setup();
  setDraft(window, 'old');
  assert.equal(await api.replaceDraft(composer, 'old', 'New one.\n\nNew two.'), true);
  assert.equal(api.readDraft(composer), 'New one.\n\nNew two.');
});

test('replacement that does not stick reports failure', async () => {
  const { api, window, composer } = setup();
  setDraft(window, 'old');
  composer.addEventListener('paste', (e) => { e.stopImmediatePropagation(); }, true);
  assert.equal(await api.replaceDraft(composer, 'old', 'new'), false);
  assert.equal(api.readDraft(composer), 'old');
});

async function clickFormat(ctx) {
  ctx.api.ensureButton();
  const main = hosts(ctx.window)[0].shadowRoot.querySelector('.main');
  main.click();
  return main;
}

test('success: draft replaced, Formatted shown, nothing sent', async () => {
  const ctx = setup({ reply: { text: 'Hello, the deploy is done.' } });
  setDraft(ctx.window, 'helo deploy done');
  const main = await clickFormat(ctx);
  assert.match(main.textContent, /Formatting\.\.\./);
  await wait();
  assert.equal(ctx.api.readDraft(ctx.composer), 'Hello, the deploy is done.');
  assert.match(main.textContent, /Formatted/);
  assert.deepEqual(ctx.sendEvents, [], 'no Enter and no Send click');
});

test('failure: draft kept and error shown', async () => {
  const ctx = setup({ reply: { error: { code: 'ollama_unavailable', message: 'Cannot reach Ollama.' } } });
  setDraft(ctx.window, 'my draft');
  const main = await clickFormat(ctx);
  await wait();
  assert.equal(ctx.api.readDraft(ctx.composer), 'my draft');
  assert.equal(main.dataset.state, 'error');
  assert.match(hosts(ctx.window)[0].shadowRoot.querySelector('.toast').textContent, /Cannot reach Ollama/);
});

test('user edit during formatting is never overwritten', async () => {
  const ctx = setup({ reply: { text: 'Formatted text.' } });
  setDraft(ctx.window, 'my draft');
  const main = await clickFormat(ctx);
  setDraft(ctx.window, 'my draft, edited');
  await wait();
  assert.equal(ctx.api.readDraft(ctx.composer), 'my draft, edited');
  assert.equal(main.dataset.state, 'error');
});

test('click while formatting cancels and keeps the draft', async () => {
  const ctx = setup();
  setDraft(ctx.window, 'my draft');
  const main = await clickFormat(ctx);
  main.click();
  assert.equal(ctx.ports[0].disconnected, true);
  assert.equal(main.dataset.state, 'idle');
  assert.equal(ctx.api.readDraft(ctx.composer), 'my draft');
});

test('empty draft never contacts the AI', async () => {
  const ctx = setup();
  const main = await clickFormat(ctx);
  assert.equal(ctx.ports.length, 0);
  assert.equal(main.dataset.state, 'error');
});

test('source never clicks Send or dispatches keyboard events', () => {
  assert.doesNotMatch(script, /KeyboardEvent|\.click\(\)|\[aria-label="Send"\]/);
});
