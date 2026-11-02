import { resolveSettings } from '../src/ai-core.js';

const config = await (await fetch(chrome.runtime.getURL('src/config.json'))).json();
const $ = (id) => document.getElementById(id);
const stored = (await chrome.storage.local.get('settings')).settings ?? {};
const settings = resolveSettings(stored, config);

const fill = (select, entries) => {
  for (const [value, label] of entries) select.add(new Option(label, value));
};
fill($('provider'), Object.entries(config.providers).map(([id, p]) => [id, p.name]));
fill($('mode'), config.modes.map((m) => [m.id, m.name]));

let shown = settings.provider;

// Provider fields are kept per provider, so switching never loses a saved key or model.
function stashProviderFields() {
  const p = settings.providers[shown];
  p.model = $('model').value.trim() || config.providers[shown].defaultModel;
  p.apiKey = $('apiKey').value.trim();
  if (config.providers[shown].local) p.baseUrl = $('baseUrl').value.trim() || config.providers[shown].baseUrl;
}

function showProvider() {
  const def = config.providers[shown];
  const p = settings.providers[shown];
  $('baseUrlRow').hidden = !def.local;
  $('apiKeyRow').hidden = def.local;
  $('baseUrl').value = p.baseUrl;
  $('apiKey').value = p.apiKey;
  $('model').value = p.model;
  $('models').replaceChildren();
  $('modelHelp').hidden = true;
  $('privacy').textContent = def.local
    ? 'Drafts stay on this computer.'
    : `Drafts you format are sent to ${def.name}. Choose Ollama to keep them on this computer.`;
  $('privacy').classList.toggle('warn', !def.local);
  setStatus('idle', 'Not checked');
}

function setStatus(state, text) {
  $('status').dataset.state = state;
  $('statusText').textContent = text;
}

function collect() {
  stashProviderFields();
  return {
    ...settings,
    provider: shown,
    mode: $('mode').value,
    customInstructions: $('customInstructions').value,
    timeoutSeconds: Number($('timeoutSeconds').value) || config.defaults.timeoutSeconds,
  };
}

async function test() {
  setStatus('idle', 'Checking…');
  const result = await chrome.runtime.sendMessage({ type: 'checkConnection', settings: collect() });
  if (result?.error) return setStatus('bad', result.error.message);
  $('models').replaceChildren(...result.models.map((m) => new Option(m, m)));
  const def = config.providers[shown];
  if (!result.modelAvailable) {
    setStatus('bad', `Connected, but "${result.model}" is not available.`);
    $('modelHelp').hidden = false;
    $('modelHelp').textContent = def.local
      ? `Install it with: ollama pull ${result.model}. If it is downloading, wait for it to finish.`
      : 'Pick one of the models your key can use from the Model list.';
    return;
  }
  $('modelHelp').hidden = true;
  setStatus('ok', `Connected to ${def.name}: ${result.model}`);
}

$('provider').value = shown;
$('mode').value = settings.mode;
$('customInstructions').value = settings.customInstructions;
$('timeoutSeconds').value = settings.timeoutSeconds;
showProvider();

$('provider').addEventListener('change', () => {
  stashProviderFields();
  shown = $('provider').value;
  showProvider();
});
$('test').addEventListener('click', test);
$('save').addEventListener('click', async () => {
  const next = collect();
  await chrome.storage.local.set({ settings: next });
  $('saved').textContent = 'Saved. Reload WhatsApp Web to apply a new default mode.';
  test();
});
test();
