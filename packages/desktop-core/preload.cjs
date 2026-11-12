// Gives the extension's options page the few chrome.* calls it uses, backed by the main process.
// Chromium already defines window.chrome, so options.js picks this up as desktopChrome.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('desktopChrome', {
  storage: {
    local: {
      get: () => ipcRenderer.invoke('storage:get'),
      set: (items) => ipcRenderer.invoke('storage:set', items),
    },
  },
  runtime: {
    getURL: (path) => `app://ui/${path}`,
    sendMessage: (msg) => ipcRenderer.invoke('message', msg),
  },
});
