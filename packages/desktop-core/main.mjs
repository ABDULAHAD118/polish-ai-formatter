// Shared Electron main process for the Windows and Linux apps. Each app passes its own composer,
// which presses the keys (select all, copy, paste) in the focused WhatsApp window.
import {
  app, BrowserWindow, Menu, Notification, Tray, clipboard, dialog, globalShortcut, ipcMain, nativeImage, net, protocol, safeStorage, shell,
} from 'electron';
import electronUpdater from 'electron-updater';
import { readFileSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import { join, normalize, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { AIError, checkConnection, formatDraft, resolveSettings } from './src/ai-core.js';

const { autoUpdater } = electronUpdater;
const here = fileURLToPath(new URL('.', import.meta.url));
const config = JSON.parse(readFileSync(join(here, 'src/config.json'), 'utf8'));
const SHORTCUT = 'Control+Alt+F';
const releasesPage = `https://github.com/${config.releasesRepo}/releases/latest`;
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// The settings page is the extension's options page, served from app:// so fetch() and modules work.
protocol.registerSchemesAsPrivileged([{ scheme: 'app', privileges: { standard: true, secure: true, supportFetchAPI: true } }]);

// API keys are in here, so encrypt with the OS keyring when there is one.
const settingsFile = () => join(app.getPath('userData'), 'settings.bin');
async function loadStored() {
  try {
    const raw = await readFile(settingsFile());
    return JSON.parse(safeStorage.isEncryptionAvailable() ? safeStorage.decryptString(raw) : raw.toString('utf8'));
  } catch {
    return undefined;
  }
}
async function saveStored(settings) {
  const json = JSON.stringify(settings);
  await writeFile(settingsFile(), safeStorage.isEncryptionAvailable() ? safeStorage.encryptString(json) : json, { mode: 0o600 });
}
const loadSettings = async () => resolveSettings(await loadStored(), config);

export function start(composer) {
  if (!app.requestSingleInstanceLock()) return app.quit();
  let tray;
  let running = null;
  let settingsWindow;

  const notify = (body) => new Notification({ title: 'TextPolish', body }).show();

  async function trigger() {
    if (running) return running.abort(); // A second press cancels, like the macOS app.
    const controller = (running = new AbortController());
    refreshTray();
    const saved = { text: clipboard.readText(), html: clipboard.readHTML(), image: clipboard.readImage() };
    const copyDraft = async () => {
      clipboard.clear();
      await composer.selectAllCopy();
      await wait(150);
      return clipboard.readText();
    };
    try {
      const draft = await copyDraft();
      if (!draft.trim()) throw new AIError('empty_draft', 'Click in the WhatsApp message box and write a message first.');
      const settings = await loadSettings();
      const text = await formatDraft({ settings, config, draft, signal: controller.signal });
      if (controller.signal.aborted) return;
      if ((await copyDraft()) !== draft) throw new AIError('draft_changed', 'The draft changed while formatting, so it was not replaced.');
      clipboard.writeText(text);
      await composer.paste();
      await wait(300); // Let WhatsApp read the clipboard before it is restored.
    } catch (e) {
      if (!controller.signal.aborted) notify(e instanceof AIError ? e.message : 'Something went wrong. Your draft was not changed.');
    } finally {
      if (saved.text || saved.html || !saved.image.isEmpty()) clipboard.write(saved);
      else clipboard.clear();
      running = null;
      refreshTray();
    }
  }

  function openSettings() {
    if (settingsWindow) return settingsWindow.show();
    settingsWindow = new BrowserWindow({
      width: 520, height: 720, title: 'TextPolish', autoHideMenuBar: true, icon: join(here, 'icon.png'),
      webPreferences: { preload: join(here, 'preload.cjs'), contextIsolation: true, sandbox: true },
    });
    settingsWindow.loadURL('app://ui/options/options.html');
    settingsWindow.on('closed', () => { settingsWindow = null; });
  }

  // userInitiated shows "up to date" and errors; the launch check stays quiet unless there is an update.
  let manualCheck = false;
  async function checkForUpdates(userInitiated) {
    manualCheck = userInitiated;
    // Only the Windows installer and the AppImage can replace themselves.
    if (!autoUpdater.isUpdaterActive()) {
      if (userInitiated) shell.openExternal(releasesPage);
      return;
    }
    try {
      await autoUpdater.checkForUpdates();
    } catch (e) {
      if (userInitiated) dialog.showErrorBox("Couldn't check for updates", e.message);
    }
  }
  autoUpdater.autoDownload = false;
  autoUpdater.on('update-not-available', () => {
    if (manualCheck) dialog.showMessageBox({ message: "You're up to date", detail: `TextPolish ${app.getVersion()} is the latest version.` });
  });
  autoUpdater.on('update-available', async (info) => {
    const notes = (Array.isArray(info.releaseNotes) ? info.releaseNotes.map((n) => n.note).join('\n') : info.releaseNotes ?? '')
      .replace(/<[^>]+>/g, '').trim();
    const { response } = await dialog.showMessageBox({
      type: 'info', message: `TextPolish ${info.version} is available`,
      detail: `You have ${app.getVersion()}.\n\n${notes.slice(0, 1500)}`,
      buttons: ['Download and Install', 'Later'], defaultId: 0, cancelId: 1,
    });
    if (response === 0) autoUpdater.downloadUpdate().catch((e) => dialog.showErrorBox('Update failed', e.message));
  });
  autoUpdater.on('update-downloaded', async () => {
    const { response } = await dialog.showMessageBox({
      type: 'info', message: 'The update is ready', detail: 'Restart TextPolish to install it.',
      buttons: ['Restart and Install', 'Install When I Quit'], defaultId: 0, cancelId: 1,
    });
    if (response === 0) autoUpdater.quitAndInstall();
  });

  async function refreshTray() {
    if (!tray) return;
    const stored = await loadStored();
    const settings = resolveSettings(stored, config);
    tray.setToolTip(running ? 'TextPolish: formatting…' : 'TextPolish');
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: running ? 'Cancel Formatting' : 'Format WhatsApp Draft', accelerator: SHORTCUT, click: trigger },
      { type: 'separator' },
      {
        label: 'Formatting Mode',
        submenu: config.modes.map((m) => ({
          label: m.name, type: 'radio', checked: m.id === settings.mode,
          click: async () => { await saveStored({ ...((await loadStored()) ?? {}), mode: m.id }); refreshTray(); },
        })),
      },
      { label: 'Settings…', click: openSettings },
      { label: 'Check for Updates…', click: () => checkForUpdates(true) },
      {
        label: 'Check for Updates Automatically', type: 'checkbox', checked: stored?.autoCheckUpdates !== false,
        click: async (item) => { await saveStored({ ...((await loadStored()) ?? {}), autoCheckUpdates: item.checked }); },
      },
      ...(process.platform === 'win32' ? [{
        label: 'Launch at Login', type: 'checkbox', checked: app.getLoginItemSettings().openAtLogin,
        click: (item) => app.setLoginItemSettings({ openAtLogin: item.checked }),
      }] : []),
      { type: 'separator' },
      { label: `Quit TextPolish ${app.getVersion()}`, role: 'quit' },
    ]));
  }

  ipcMain.handle('storage:get', async () => ({ settings: await loadStored() }));
  ipcMain.handle('storage:set', async (_e, { settings }) => { await saveStored(settings); refreshTray(); });
  ipcMain.handle('message', async (_e, msg) => {
    if (msg?.type !== 'checkConnection') return undefined;
    try {
      return await checkConnection({ settings: resolveSettings(msg.settings, config), config });
    } catch (e) {
      return { error: { code: e.code ?? 'unexpected', message: e instanceof AIError ? e.message : 'Something went wrong.' } };
    }
  });

  app.on('second-instance', openSettings);
  app.on('window-all-closed', () => {}); // Keep running in the tray.
  app.on('will-quit', () => globalShortcut.unregisterAll());

  app.whenReady().then(async () => {
    protocol.handle('app', (req) => {
      const path = normalize(join(here, decodeURIComponent(new URL(req.url).pathname)));
      if (!path.startsWith(here.endsWith(sep) ? here : here + sep)) return new Response('Not found', { status: 404 });
      return net.fetch(pathToFileURL(path).href);
    });
    tray = new Tray(nativeImage.createFromPath(join(here, 'icon.png')).resize({ width: process.platform === 'win32' ? 16 : 22 }));
    tray.on('click', () => tray.popUpContextMenu());
    await refreshTray();
    composer.warmUp?.();
    if (!globalShortcut.register(SHORTCUT, trigger)) {
      notify('Ctrl+Alt+F is used by another app. Use Format WhatsApp Draft in the tray menu instead.');
    }
    if (!(await loadStored())) openSettings();
    const autoCheck = async () => { if ((await loadStored())?.autoCheckUpdates !== false) checkForUpdates(false); };
    autoCheck();
    setInterval(autoCheck, 24 * 60 * 60 * 1000); // A tray app can run for weeks.
  });
}
