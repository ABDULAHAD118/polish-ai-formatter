import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { AIError, buildChatRequest, buildSystemPrompt, checkConnection, cleanOutput, formatDraft, isNewerVersion, parseChatResponse, resolveSettings, validateOutput } from '../src/ai-core.js';

const config = JSON.parse(readFileSync(new URL('../../../packages/shared-config/config.json', import.meta.url)));
const settingsFor = (provider, extra = {}) => resolveSettings({ provider, providers: { [provider]: { apiKey: 'k', ...extra } } }, config);
const reply = (body, status = 200) => async () => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status });
const code = (c) => (e) => e instanceof AIError && e.code === c;
const run = (fetchImpl, draft = 'hello there', settings = settingsFor('ollama'), modeId) => formatDraft({ settings, config, draft, modeId, fetchImpl });

test('extension config copies match the shared config', () => {
  const shared = readFileSync(new URL('../../../packages/shared-config/config.json', import.meta.url), 'utf8');
  assert.equal(readFileSync(new URL('../src/config.json', import.meta.url), 'utf8'), shared);
  assert.equal(readFileSync(new URL('../../macos-app/Sources/FormatterCore/config.json', import.meta.url), 'utf8'), shared);
});

test('defaults: Ollama, qwen2.5:3b, Professional', () => {
  const s = resolveSettings(undefined, config);
  assert.equal(s.provider, 'ollama');
  assert.equal(s.providers.ollama.model, 'qwen2.5:3b');
  assert.equal(s.mode, 'professional');
});

test('successful formatting sends the spec request to Ollama', async () => {
  let sent;
  const text = await run(async (url, init) => {
    sent = { url, body: JSON.parse(init.body) };
    return new Response(JSON.stringify({ message: { content: 'Hello there.' } }));
  });
  assert.equal(text, 'Hello there.');
  assert.equal(sent.url, 'http://127.0.0.1:11434/api/chat');
  assert.equal(sent.body.stream, false);
  assert.equal(sent.body.options.temperature, 0.2);
  assert.deepEqual(sent.body.messages.map((m) => m.role), ['system', 'user']);
  assert.equal(sent.body.messages[1].content, '<draft>\nhello there\n</draft>');
});

test('empty input never calls the provider', async () => {
  await assert.rejects(run(() => assert.fail('called'), '   '), code('empty_draft'));
});

test('empty model response is rejected', async () => {
  await assert.rejects(run(reply({ message: { content: '  ' } })), code('empty_response'));
});

test('invalid JSON and wrong shapes are rejected', async () => {
  await assert.rejects(run(reply('<html>')), code('invalid_response'));
  await assert.rejects(run(reply({ nope: true })), code('invalid_response'));
});

test('Ollama unavailable gives setup instructions', async () => {
  await assert.rejects(run(async () => { throw new TypeError('fetch failed'); }), (e) => e.code === 'ollama_unavailable' && /ollama serve/.test(e.message));
});

test('timeout is reported as timeout', async () => {
  const settings = { ...settingsFor('ollama'), timeoutSeconds: 0.01 };
  const hang = (_u, init) => new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(new DOMException('x', 'AbortError'))));
  await assert.rejects(run(hang, 'hello', settings), code('timeout'));
});

test('cancel aborts the request', async () => {
  const controller = new AbortController();
  const hang = (_u, init) => new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(new DOMException('x', 'AbortError'))));
  const p = formatDraft({ settings: settingsFor('ollama'), config, draft: 'hi', fetchImpl: hang, signal: controller.signal });
  controller.abort();
  await assert.rejects(p, code('cancelled'));
});

test('missing model gives the pull command', async () => {
  await assert.rejects(run(reply({ error: 'model not found' }, 404)), (e) => e.code === 'model_missing' && /ollama pull qwen2\.5:3b/.test(e.message));
});

test('remote Ollama address is refused so local mode stays local', async () => {
  const settings = settingsFor('ollama', { baseUrl: 'http://evil.example:11434' });
  await assert.rejects(run(() => assert.fail('called'), 'hi', settings), code('bad_url'));
});

test('names, numbers, dates and technical terms: numbers and links are enforced', () => {
  const draft = 'ali said api v2 deploy on 5 nov at 10:30, see https://x.io/a';
  assert.doesNotThrow(() => validateOutput('Ali said the API v2 deployment is on 5 Nov at 10:30. See https://x.io/a.', draft, 'professional'));
  assert.throws(() => validateOutput('Ali said the API v2 deployment is on 6 Nov at 10:30. See https://x.io/a', draft, 'professional'), code('facts_changed'));
  assert.throws(() => validateOutput('Ali said the API v2 deployment is on 5 Nov at 10:30.', draft, 'professional'), code('facts_changed'));
  assert.throws(() => validateOutput('API v2 deploys on 5 Nov at 10:30, 99% done. See https://x.io/a', draft, 'professional'), code('facts_changed'));
  assert.doesNotThrow(() => validateOutput('Bonjour', draft, 'custom'));
});

test('commentary and thinking are not pasted into the draft', () => {
  assert.throws(() => validateOutput('Here is the improved message:\nHello.', 'hello', 'professional'), code('invalid_response'));
  assert.equal(cleanOutput('<think>hmm</think>\n"Hello."', 'hello'), 'Hello.');
  assert.equal(cleanOutput('"Hello."', '"hello"'), '"Hello."');
  assert.equal(cleanOutput('<draft>\nHello.\n</draft>', 'hello'), 'Hello.');
  assert.equal(cleanOutput('Sure, can you send it?', 'can you send it'), 'Can you send it?');
  assert.equal(cleanOutput('Sure, I will send it.', 'sure i will send it'), 'Sure, I will send it.');
});

test('custom mode needs instructions and uses them', () => {
  assert.throws(() => buildSystemPrompt(config, 'custom', ' '), code('custom_empty'));
  assert.match(buildSystemPrompt(config, 'custom', 'Use Urdu'), /Use Urdu/);
  assert.match(buildSystemPrompt(config, 'short', ''), /Short & Clear/);
});

test('cloud providers require a key before any request', () => {
  const s = resolveSettings({ provider: 'openai' }, config);
  assert.throws(() => buildChatRequest(s, config, 'sys', 'hi'), code('missing_key'));
});

test('Claude request has no sampling parameters and parses text blocks only', () => {
  const { url, init } = buildChatRequest(settingsFor('claude'), config, 'sys', 'hi');
  const body = JSON.parse(init.body);
  assert.equal(url, 'https://api.anthropic.com/v1/messages');
  assert.equal(init.headers['x-api-key'], 'k');
  assert.equal(init.headers['anthropic-version'], '2026-10-21');
  assert.equal(body.temperature, undefined);
  assert.equal(body.system, 'sys');
  assert.equal(body.fallbacks, 'default');
  assert.equal(parseChatResponse('claude', { stop_reason: 'end_turn', content: [{ type: 'thinking', thinking: '' }, { type: 'text', text: 'Hi.' }] }), 'Hi.');
  assert.throws(() => parseChatResponse('claude', { stop_reason: 'refusal', content: [] }), code('refused'));
  assert.throws(() => parseChatResponse('claude', { stop_reason: 'max_tokens', content: [{ type: 'text', text: 'Hi' }] }), code('truncated'));
});

test('Claude model without server fallbacks does not send them', () => {
  const { init } = buildChatRequest(settingsFor('claude', { model: 'claude-haiku-5-5' }), config, 'sys', 'hi');
  assert.equal(JSON.parse(init.body).fallbacks, undefined);
  assert.equal(init.headers['anthropic-beta'], undefined);
});

test('OpenAI request and response', () => {
  const { url, init } = buildChatRequest(settingsFor('openai'), config, 'sys', 'hi');
  assert.equal(url, 'https://api.openai.com/v1/chat/completions');
  assert.equal(init.headers.Authorization, 'Bearer k');
  assert.deepEqual(JSON.parse(init.body).messages[0], { role: 'system', content: 'sys' });
  assert.equal(parseChatResponse('openai', { choices: [{ message: { content: 'Hi.' } }] }), 'Hi.');
  assert.throws(() => parseChatResponse('openai', { choices: [{ finish_reason: 'length', message: { content: 'H' } }] }), code('truncated'));
});

test('Gemini request and response', () => {
  const { url, init } = buildChatRequest(settingsFor('gemini'), config, 'sys', 'hi');
  assert.match(url, /v1beta\/models\/gemini-3\.8-flash:generateContent$/);
  assert.equal(init.headers['x-goog-api-key'], 'k');
  assert.ok(!url.includes('key='), 'key must not be in the URL');
  assert.equal(JSON.parse(init.body).systemInstruction.parts[0].text, 'sys');
  assert.equal(parseChatResponse('gemini', { candidates: [{ content: { parts: [{ text: 'Hi.' }] } }] }), 'Hi.');
  assert.throws(() => parseChatResponse('gemini', { promptFeedback: { blockReason: 'SAFETY' } }), code('refused'));
});

test('bad API key and rate limit messages', async () => {
  const s = settingsFor('openai');
  await assert.rejects(run(reply({ error: { message: 'bad' } }, 401), 'hi', s), code('auth'));
  await assert.rejects(run(reply({}, 429), 'hi', s), code('rate_limited'));
});

test('checkConnection reports installed models', async () => {
  const fetchImpl = reply({ models: [{ name: 'qwen2.5:3b' }, { name: 'other:latest' }] });
  const ok = await checkConnection({ settings: settingsFor('ollama'), config, fetchImpl });
  assert.equal(ok.modelAvailable, true);
  const missing = await checkConnection({ settings: settingsFor('ollama', { model: 'nope' }), config, fetchImpl });
  assert.equal(missing.modelAvailable, false);
});

test('checkConnection filters Gemini models to generateContent', async () => {
  const fetchImpl = reply({ models: [
    { name: 'models/gemini-3.8-flash', supportedGenerationMethods: ['generateContent'] },
    { name: 'models/embed', supportedGenerationMethods: ['embedContent'] },
  ] });
  const r = await checkConnection({ settings: settingsFor('gemini'), config, fetchImpl });
  assert.deepEqual(r.models, ['gemini-3.8-flash']);
});

test('service worker modules have no top-level await, which Chrome refuses to register', () => {
  for (const file of ['background.js', 'ai-core.js']) {
    const source = readFileSync(new URL(`../src/${file}`, import.meta.url), 'utf8');
    const topLevel = source.split('\n').filter((line) => /^\S/.test(line) && /\bawait\b/.test(line) && !/\basync\b/.test(line) && !line.startsWith('//'));
    assert.deepEqual(topLevel, [], file);
  }
});

test('update check compares versions numerically', () => {
  assert.equal(isNewerVersion('v1.10.0', '1.9.2'), true);
  assert.equal(isNewerVersion('v1.2.0', '1.2.0'), false);
  assert.equal(isNewerVersion('1.2', '1.2.0'), false);
  assert.equal(isNewerVersion('v1.1.9', '1.2.0'), false);
});
