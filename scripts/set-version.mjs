// Sets one version everywhere a build reads it. Usage: node scripts/set-version.mjs 1.2.0 (CI passes the tag).
import { readFileSync, writeFileSync } from 'node:fs';

const version = process.argv[2]?.replace(/^v/, '');
if (!/^\d+\.\d+\.\d+$/.test(version ?? '')) throw new Error(`Expected a version like 1.2.0, got ${process.argv[2]}`);
const edit = (file, fn) => writeFileSync(file, fn(readFileSync(file, 'utf8')));
for (const file of ['package.json', 'apps/chrome-extension/manifest.json', 'apps/windows-app/package.json', 'apps/linux-app/package.json']) {
  edit(file, (s) => s.replace(/"version": "[^"]*"/, `"version": "${version}"`));
}
edit('apps/macos-app/Resources/Info.plist', (s) => s
  .replace(/(<key>CFBundleShortVersionString<\/key><string>)[^<]*/, `$1${version}`)
  .replace(/(<key>CFBundleVersion<\/key><string>)[^<]*/, `$1${version}`));
console.log(`Version set to ${version}`);
