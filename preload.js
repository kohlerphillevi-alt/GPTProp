const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  getSettings: () => ipcRenderer.invoke('settings:get'),
  setSettings: (s) => ipcRenderer.invoke('settings:set', s),
  testKey: (key) => ipcRenderer.invoke('gemini:test', key),
  testSpotify: (id, secret) => ipcRenderer.invoke('spotify:test', id, secret),
  listModels: (force) => ipcRenderer.invoke('gemini:models', force),
  generate: (body) => ipcRenderer.invoke('gemini:generate', body),
  tool: (name, args) => ipcRenderer.invoke('tool:run', name, args),
  onOpenSettings: (cb) => ipcRenderer.on('open-settings', () => cb()),
  transcribe: (b64) => ipcRenderer.invoke('voice:transcribe', b64),
  onVoiceWake: (cb) => ipcRenderer.on('voice-wake', () => cb()),
  checkUpdate: () => ipcRenderer.invoke('update:check'),
  installUpdate: () => ipcRenderer.invoke('update:install'),
  onUpdateState: (cb) => ipcRenderer.on('update-state', (e, s) => cb(s)),
  pauseHotkeys: () => ipcRenderer.invoke('hotkeys:pause'),
  resumeHotkeys: () => ipcRenderer.invoke('hotkeys:resume'),
  onVoicePtt: (cb) => ipcRenderer.on('voice-ptt', () => cb()),
  onVoiceState: (cb) => ipcRenderer.on('voice-state', (e, s) => cb(s)),
  onSettingsChanged: (cb) => ipcRenderer.on('settings-changed', () => cb()),
  onProgress: (cb) => ipcRenderer.on('gen-progress', (e, text) => cb(String(text || '')))
});
