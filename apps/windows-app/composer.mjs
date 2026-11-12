// Presses Ctrl+A/C/V in the focused WhatsApp window through user32, via one long-lived PowerShell
// process so the C# helper compiles once rather than on every key press.
import { spawn } from 'node:child_process';
import { AIError } from './shared/src/ai-core.js';

const SCRIPT = String.raw`
Add-Type @"
using System; using System.Diagnostics; using System.Runtime.InteropServices; using System.Text;
public static class K {
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  public static bool IsWhatsApp() {
    IntPtr h = GetForegroundWindow();
    var title = new StringBuilder(512); GetWindowText(h, title, 512);
    uint pid; GetWindowThreadProcessId(h, out pid);
    string name = ""; try { name = Process.GetProcessById((int)pid).ProcessName; } catch {}
    return name.IndexOf("WhatsApp", StringComparison.OrdinalIgnoreCase) >= 0
        || title.ToString().IndexOf("WhatsApp", StringComparison.OrdinalIgnoreCase) >= 0;
  }
  static void Down(byte vk) { keybd_event(vk, 0, 0, UIntPtr.Zero); }
  static void Up(byte vk) { keybd_event(vk, 0, 2, UIntPtr.Zero); }
  public static void Ctrl(byte key) {
    Down(0x11); // Ctrl first, so releasing the shortcut's held Alt doesn't open a menu.
    foreach (byte m in new byte[] { 0x10, 0x12, 0x5B, 0x5C, 0xA0, 0xA1, 0xA4, 0xA5 }) Up(m);
    Down(key); Up(key); Up(0x11);
  }
}
"@
while ($null -ne ($line = [Console]::In.ReadLine())) {
  if (-not [K]::IsWhatsApp()) { [Console]::Out.WriteLine('not-whatsapp'); continue }
  if ($line -eq 'copy') { [K]::Ctrl(0x41); Start-Sleep -Milliseconds 40; [K]::Ctrl(0x43) } else { [K]::Ctrl(0x56) }
  [Console]::Out.WriteLine('ok')
}
`;

let ps = null;
const waiters = [];

function shell() {
  if (ps) return ps;
  ps = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand',
    Buffer.from(SCRIPT, 'utf16le').toString('base64')], { windowsHide: true });
  let buffer = '';
  ps.stdout.setEncoding('utf8');
  ps.stdout.on('data', (chunk) => {
    buffer += chunk;
    for (let i; (i = buffer.indexOf('\n')) >= 0; buffer = buffer.slice(i + 1)) waiters.shift()?.(buffer.slice(0, i).trim());
  });
  const reset = () => {
    ps = null;
    while (waiters.length) waiters.shift()('exited');
  };
  ps.on('exit', reset);
  ps.on('error', reset);
  ps.stdin.on('error', reset);
  return ps;
}

function send(command) {
  return new Promise((resolve, reject) => {
    waiters.push((reply) => {
      if (reply === 'ok') resolve();
      else if (reply === 'not-whatsapp') reject(new AIError('not_whatsapp', 'Open a WhatsApp chat and click in the message box first.'));
      else reject(new AIError('keys_failed', 'TextPolish could not press keys in WhatsApp. Your draft was not changed.'));
    });
    shell().stdin.write(`${command}\n`);
  });
}

export const warmUp = shell;
export const selectAllCopy = () => send('copy');
export const paste = () => send('paste');
