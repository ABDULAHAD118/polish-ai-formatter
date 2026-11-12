// Presses Ctrl+A/C/V in the focused WhatsApp window with xdotool.
// shortcut: X11 (and XWayland windows) only; native Wayland windows need ydotool or a portal.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { AIError } from './shared/src/ai-core.js';

const run = promisify(execFile);

async function xdotool(args) {
  try {
    return (await run('xdotool', args)).stdout;
  } catch (e) {
    throw new AIError('keys_failed', e.code === 'ENOENT'
      ? 'Install xdotool (for example: sudo apt install xdotool) so TextPolish can read the draft.'
      : 'TextPolish could not reach the focused window. On Wayland, run WhatsApp under XWayland.');
  }
}

async function requireWhatsApp() {
  // WhatsApp Web in a browser and the Linux wrapper apps all carry "WhatsApp" in the window title.
  if (!/whatsapp/i.test(await xdotool(['getactivewindow', 'getwindowname']))) {
    throw new AIError('not_whatsapp', 'Open a WhatsApp chat and click in the message box first.');
  }
}

export async function selectAllCopy() {
  await requireWhatsApp();
  await xdotool(['key', '--clearmodifiers', 'ctrl+a', 'ctrl+c']);
}

export async function paste() {
  await requireWhatsApp();
  await xdotool(['key', '--clearmodifiers', 'ctrl+v']);
}
