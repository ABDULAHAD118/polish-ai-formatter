// Provider client for the extension. apps/macos-app/Sources/FormatterCore/AIClient.swift mirrors it.
// Never log drafts or model output here.

export class AIError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '[::1]']);

export function resolveSettings(stored, config) {
  const providers = {};
  for (const [id, p] of Object.entries(config.providers)) {
    const saved = stored?.providers?.[id] ?? {};
    providers[id] = {
      baseUrl: (p.local && saved.baseUrl) || p.baseUrl,
      model: saved.model || p.defaultModel,
      apiKey: saved.apiKey || '',
    };
  }
  return {
    provider: config.providers[stored?.provider] ? stored.provider : config.defaults.provider,
    mode: config.modes.some((m) => m.id === stored?.mode) ? stored.mode : config.defaults.mode,
    customInstructions: stored?.customInstructions || '',
    timeoutSeconds: stored?.timeoutSeconds > 0 ? stored.timeoutSeconds : config.defaults.timeoutSeconds,
    providers,
  };
}

export function buildSystemPrompt(config, modeId, customInstructions) {
  if (modeId === 'custom') {
    if (!customInstructions.trim()) {
      throw new AIError('custom_empty', 'Custom mode has no instructions. Add them in the extension settings.');
    }
    return `${config.systemPrompt}\n\nAdditional formatting instructions from the user:\n${customInstructions.trim()}`;
  }
  const mode = config.modes.find((m) => m.id === modeId) ?? config.modes[0];
  return `${config.systemPrompt}\n\nFormatting mode: ${mode.name}. ${mode.instruction}`;
}

// A "local" setting must never quietly send drafts to another machine.
function assertLoopback(baseUrl) {
  let url;
  try {
    url = new URL(baseUrl);
  } catch {
    throw new AIError('bad_url', 'The Ollama address is not a valid URL.');
  }
  if (!LOOPBACK_HOSTS.has(url.hostname) || !url.protocol.startsWith('http')) {
    throw new AIError('bad_url', 'The Ollama address must be on this computer (127.0.0.1 or localhost).');
  }
}

function requireKey(providerName, apiKey) {
  if (!apiKey) throw new AIError('missing_key', `Add your ${providerName} key in settings.`);
}

function authHeaders(providerId, apiKey) {
  if (providerId === 'claude') {
    return {
      'x-api-key': apiKey,
      'anthropic-version': '2026-10-21',
      // Requests come from an extension origin, and the key is the user's own.
      'anthropic-dangerous-direct-browser-access': 'true',
    };
  }
  if (providerId === 'openai') return { Authorization: `Bearer ${apiKey}` };
  if (providerId === 'gemini') return { 'x-goog-api-key': apiKey };
  return {};
}

export function buildChatRequest(settings, config, system, rawDraft) {
  // Tags stop models from treating a draft that asks a question as a question to them.
  const draft = `<draft>\n${rawDraft}\n</draft>`;
  const id = settings.provider;
  const p = settings.providers[id];
  const providerName = config.providers[id].name;
  const headers = { 'Content-Type': 'application/json' };
  let url;
  let body;

  if (id === 'ollama') {
    assertLoopback(p.baseUrl);
    url = `${p.baseUrl.replace(/\/+$/, '')}/api/chat`;
    body = {
      model: p.model,
      stream: false,
      messages: [{ role: 'system', content: system }, { role: 'user', content: draft }],
      options: { temperature: config.defaults.temperature },
    };
  } else {
    requireKey(providerName, p.apiKey);
    Object.assign(headers, authHeaders(id, p.apiKey));
    if (id === 'claude') {
      url = `${p.baseUrl}/v1/messages`;
      body = { model: p.model, max_tokens: 16000, system, messages: [{ role: 'user', content: draft }] };
      // Sampling parameters are rejected on this API version, so temperature is left out.
      if (/^claude-(fable|opus|sonnet|haiku)-5/.test(p.model)) body.output_config = { effort: 'low' };
      if (/^claude-(fable-5-1|opus-5|sonnet-5-5)/.test(p.model)) {
        headers['anthropic-beta'] = 'server-side-fallback-2026-07-01';
        body.fallbacks = 'default';
      }
    } else if (id === 'openai') {
      url = `${p.baseUrl}/v1/chat/completions`;
      // Some OpenAI models reject non-default temperature, so it is left out.
      body = { model: p.model, messages: [{ role: 'system', content: system }, { role: 'user', content: draft }] };
    } else {
      url = `${p.baseUrl}/v1beta/models/${encodeURIComponent(p.model)}:generateContent`;
      body = {
        systemInstruction: { parts: [{ text: system }] },
        contents: [{ role: 'user', parts: [{ text: draft }] }],
        generationConfig: { temperature: config.defaults.temperature },
      };
    }
  }
  return { url, init: { method: 'POST', headers, body: JSON.stringify(body) } };
}

const TRUNCATED = new AIError('truncated', 'The AI response was cut off. Your draft was not changed.');
const INVALID = new AIError('invalid_response', 'The AI returned an unexpected response. Your draft was not changed.');

export function parseChatResponse(providerId, json) {
  let text;
  if (providerId === 'ollama') {
    if (json?.done_reason === 'length') throw TRUNCATED;
    text = json?.message?.content;
  } else if (providerId === 'claude') {
    if (json?.stop_reason === 'refusal') {
      throw new AIError('refused', 'Claude declined this message. Your draft was not changed.');
    }
    if (json?.stop_reason === 'max_tokens') throw TRUNCATED;
    if (Array.isArray(json?.content)) {
      text = json.content.filter((b) => b.type === 'text').map((b) => b.text).join('');
    }
  } else if (providerId === 'openai') {
    const choice = json?.choices?.[0];
    if (choice?.finish_reason === 'length') throw TRUNCATED;
    if (choice?.finish_reason === 'content_filter') {
      throw new AIError('refused', 'OpenAI declined this message. Your draft was not changed.');
    }
    text = choice?.message?.content;
  } else {
    const candidate = json?.candidates?.[0];
    if (candidate?.finishReason === 'MAX_TOKENS') throw TRUNCATED;
    if (json?.promptFeedback?.blockReason || candidate?.finishReason === 'SAFETY') {
      throw new AIError('refused', 'Gemini declined this message. Your draft was not changed.');
    }
    if (Array.isArray(candidate?.content?.parts)) text = candidate.content.parts.map((p) => p.text ?? '').join('');
  }
  if (typeof text !== 'string') throw INVALID;
  return text;
}

const digitRuns = (s) => (s.match(/\d+/g) ?? []).map((n) => n.replace(/^0+(?=\d)/, '')).filter((n) => n !== '0');
const urls = (s) => (s.match(/https?:\/\/[^\s)]+/gi) ?? []).map((u) => u.replace(/[.,!?;:]+$/, ''));

export function cleanOutput(raw, draft) {
  let text = raw.replace(/<think>[\s\S]*?<\/think>/gi, '').replace(/<\/?draft>/gi, '').trim();
  const quoted = /^(["“])[\s\S]*(["”])$/.test(text);
  if (quoted && !/^["“]/.test(draft.trim())) text = text.slice(1, -1).trim();
  // Small models keep adding this opener despite the prompt, and it reads as a reply.
  const opener = /^(sure|certainly|of course)[,!.]\s+/i;
  if (opener.test(text) && !/^\s*(sure|certainly|of course)\b/i.test(draft)) {
    text = text.replace(opener, '');
    text = text[0].toUpperCase() + text.slice(1);
  }
  return text;
}

// Rejects output that cannot be trusted to replace the draft. Numbers and links are checked
// both ways: a missing one was dropped and a new one was invented. Custom mode skips this
// because the user may ask for something like translation.
export function validateOutput(text, draft, modeId) {
  if (!text) throw new AIError('empty_response', 'The AI returned an empty response. Your draft was not changed.');
  if (/^(here(’|')?s|here is|sure|certainly|of course)\b[^\n]*:\s*\n/i.test(text)) {
    throw new AIError('invalid_response', 'The AI added commentary instead of only the message. Your draft was not changed.');
  }
  if (modeId === 'custom') return;
  const inDraft = new Set(digitRuns(draft));
  const inText = new Set(digitRuns(text));
  const numbersChanged = [...inDraft].some((n) => !inText.has(n)) || [...inText].some((n) => !inDraft.has(n));
  const lowerText = text.toLowerCase();
  const linkDropped = urls(draft).some((u) => !lowerText.includes(u.toLowerCase()));
  if (numbersChanged || linkDropped) {
    throw new AIError('facts_changed', 'The AI changed a number or link, so your draft was kept. Try again.');
  }
}

function httpError(providerId, config, model, status, body) {
  const name = config.providers[providerId].name;
  let detail = '';
  try {
    const parsed = JSON.parse(body);
    detail = String(parsed?.error?.message ?? parsed?.error ?? '').slice(0, 200);
  } catch {}

  if (providerId === 'ollama') {
    if (status === 404) {
      return new AIError('model_missing', `Model "${model}" is not installed. Run: ollama pull ${model}. If it is still downloading, wait for it to finish.`);
    }
    if (status === 403) return new AIError('ollama_forbidden', 'Ollama refused the request origin. Set OLLAMA_ORIGINS=chrome-extension://* and restart Ollama.');
  }
  if (status === 401 || status === 403) return new AIError('auth', `${name} rejected the API key. Check it in settings.`);
  if (status === 404) return new AIError('model_missing', `${name} does not offer model "${model}". Pick another in settings.`);
  if (status === 429) return new AIError('rate_limited', `${name} rate limit or quota reached. Try again later or check your plan.`);
  return new AIError('http_error', `${name} returned an error (${status})${detail ? `: ${detail}` : ''}.`);
}

function unreachable(providerId, config) {
  if (providerId === 'ollama') {
    return new AIError('ollama_unavailable', 'Cannot reach Ollama. Install it from ollama.com, or start it with: ollama serve');
  }
  return new AIError('network', `Cannot reach ${config.providers[providerId].name}. Check your internet connection.`);
}

async function send(url, init, { fetchImpl, signal, timeoutMs, providerId, config }) {
  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  const onAbort = () => controller.abort();
  if (signal?.aborted) controller.abort();
  signal?.addEventListener('abort', onAbort);
  try {
    const res = await fetchImpl(url, { ...init, signal: controller.signal });
    return { status: res.status, ok: res.ok, body: await res.text() };
  } catch (e) {
    if (timedOut) throw new AIError('timeout', 'The AI took too long. Try again, or raise the timeout in settings.');
    if (e?.name === 'AbortError') throw new AIError('cancelled', 'Formatting cancelled.');
    throw unreachable(providerId, config);
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', onAbort);
  }
}

export async function formatDraft({ settings, config, draft, modeId, fetchImpl = fetch, signal }) {
  if (!draft.trim()) throw new AIError('empty_draft', 'Write a message first.');
  const id = settings.provider;
  const mode = modeId ?? settings.mode;
  const system = buildSystemPrompt(config, mode, settings.customInstructions);
  const { url, init } = buildChatRequest(settings, config, system, draft);
  const res = await send(url, init, {
    fetchImpl, signal, timeoutMs: settings.timeoutSeconds * 1000, providerId: id, config,
  });
  if (!res.ok) throw httpError(id, config, settings.providers[id].model, res.status, res.body);
  let json;
  try {
    json = JSON.parse(res.body);
  } catch {
    throw INVALID;
  }
  const text = cleanOutput(parseChatResponse(id, json), draft);
  validateOutput(text, draft, mode);
  return text;
}

export async function checkConnection({ settings, config, fetchImpl = fetch }) {
  const id = settings.provider;
  const p = settings.providers[id];
  let url;
  if (id === 'ollama') {
    assertLoopback(p.baseUrl);
    url = `${p.baseUrl.replace(/\/+$/, '')}/api/tags`;
  } else {
    requireKey(config.providers[id].name, p.apiKey);
    url = { claude: `${p.baseUrl}/v1/models?limit=100`, openai: `${p.baseUrl}/v1/models`, gemini: `${p.baseUrl}/v1beta/models?pageSize=200` }[id];
  }
  const res = await send(url, { headers: authHeaders(id, p.apiKey) }, {
    fetchImpl, timeoutMs: 10000, providerId: id, config,
  });
  if (!res.ok) throw httpError(id, config, p.model, res.status, res.body);
  let json;
  try {
    json = JSON.parse(res.body);
  } catch {
    throw INVALID;
  }
  let models;
  if (id === 'ollama') models = (json.models ?? []).map((m) => m.name);
  else if (id === 'gemini') {
    models = (json.models ?? [])
      .filter((m) => m.supportedGenerationMethods?.includes('generateContent'))
      .map((m) => m.name.replace(/^models\//, ''));
  } else models = (json.data ?? []).map((m) => m.id);
  const modelAvailable = models.includes(p.model) || models.includes(`${p.model}:latest`);
  return { models, modelAvailable, model: p.model };
}

// True when release tag `candidate` ("v1.2.0") is a higher version than `current` ("1.1.9").
export function isNewerVersion(candidate, current) {
  const parts = (v) => String(v).replace(/^v/i, '').split('.').map((n) => parseInt(n, 10) || 0);
  const a = parts(candidate);
  const b = parts(current);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0);
  }
  return false;
}
