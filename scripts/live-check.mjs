// Runs real drafts through the local model and prints pass/fail only, using test drafts.
import { readFileSync } from 'node:fs';
import { formatDraft, resolveSettings } from '../apps/chrome-extension/src/ai-core.js';

const config = JSON.parse(readFileSync(new URL('../packages/shared-config/config.json', import.meta.url)));
const settings = resolveSettings({ providers: { ollama: { model: process.argv[2] } } }, config);

const cases = [
  { mode: 'professional', draft: 'hi sir, ali fixed the login api yesterday, v2.3 deploy on staging is done but prod deploy pending till 15 nov', keep: ['Ali', 'API', '2.3', 'staging', '15'] },
  { mode: 'short', draft: 'so basically i wanted to tell that the jira ticket WEB-412 is still in review and sara will check it on monday', keep: ['WEB-412', 'Sara', 'Monday'] },
  { mode: 'polite', draft: 'send me the invoice 8841 today', keep: ['8841', 'invoice'] },
  { mode: 'grammar', draft: 'we has completed the docker migration\nredis is still pending', keep: ['Docker', 'Redis'], lines: 2 },
  { mode: 'friendly', draft: 'can you send me the report by friday?', keep: ['report', 'Friday'] },
];

let failed = 0;
for (const { mode, draft, keep, lines } of cases) {
  const started = Date.now();
  try {
    const text = await formatDraft({ settings, config, draft, modeId: mode });
    const missing = keep.filter((k) => !text.toLowerCase().includes(k.toLowerCase()));
    if (lines && text.split('\n').length !== lines) missing.push(`${lines} lines`);
    if (missing.length) failed++;
    console.log(`${missing.length ? 'FAIL' : 'PASS'} ${mode} ${Date.now() - started}ms${missing.length ? ` missing: ${missing}` : ''}\n  ${text.replace(/\n/g, '\n  ')}`);
  } catch (e) {
    failed++;
    console.log(`FAIL ${mode} ${Date.now() - started}ms ${e.code}: ${e.message}`);
  }
}
process.exit(failed ? 1 : 0);
