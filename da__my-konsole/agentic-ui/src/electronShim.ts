// TODO(agentic-ui): stubbed - was Electron-only.
//
// Upstream goose-desktop's renderer talks to the Electron main process via
// `window.electron` (see preload.ts) and reads static app config via
// `window.appConfig` (also injected by main.ts). Neither exists in this
// standalone, browser-only build (no Electron, no main process, no preload
// script), so every call site that references `window.electron.*` or
// `window.appConfig.*` would otherwise throw `Cannot read properties of
// undefined`.
//
// Rather than hand-edit each of the 100+ call sites individually (see
// agentic-ui/README.md for the full file:line list gathered while building
// this), this file installs a single global shim object that implements the
// same shape as upstream's ElectronAPI/AppConfigAPI, backed by:
//   - localStorage, for the handful of settings the UI actually needs at
//     runtime to look right (theme, language, etc) - these previously lived
//     in Electron's persisted settings store.
//   - no-ops (with a console.warn) for anything that triggers real OS/Electron
//     integration: native dialogs, dock/tray/menu-bar icons, deep links,
//     auto-updater, spawning new windows, filesystem access outside the
//     browser sandbox, etc. Those affordances still render in the UI (we did
//     not hide them) but clicking them logs a warning and does nothing.
//
// This must be imported before App.tsx renders; renderer.tsx does so.

import { defaultSettings, type Settings, type SettingKey } from './utils/settings';

function warnStub(name: string): void {
  console.warn(`[agentic-ui] window.electron.${name}() is stubbed (Electron-only, no-op)`);
}

function getStoredSettings(): Partial<Settings> {
  try {
    const raw = localStorage.getItem('agentic_ui_settings');
    return raw ? (JSON.parse(raw) as Partial<Settings>) : {};
  } catch {
    return {};
  }
}

function setStoredSetting<K extends SettingKey>(key: K, value: Settings[K]): void {
  try {
    const current = getStoredSettings();
    current[key] = value;
    localStorage.setItem('agentic_ui_settings', JSON.stringify(current));
  } catch {
    // ignore quota / serialization errors - matches upstream's best-effort persistence
  }
}

const eventTarget = new EventTarget();

const electronShim = {
  platform: 'linux',
  arch: 'x64',
  reactReady: () => warnStub('reactReady'),
  getConfig: () => {
    warnStub('getConfig');
    return {};
  },
  hideWindow: () => warnStub('hideWindow'),
  directoryChooser: async () => {
    warnStub('directoryChooser');
    return { canceled: true, filePaths: [] };
  },
  createChatWindow: () => warnStub('createChatWindow (multi-window unsupported in browser build)'),
  logInfo: (txt: string) => console.info(`[goose] ${txt}`),
  showNotification: () => warnStub('showNotification'),
  showMessageBox: async () => {
    warnStub('showMessageBox');
    return { response: 0 };
  },
  showSaveDialog: async () => {
    warnStub('showSaveDialog');
    return { canceled: true, filePath: undefined };
  },
  openInChrome: (url: string) => window.open(url, '_blank', 'noopener,noreferrer'),
  reloadApp: () => window.location.reload(),
  checkForOllama: async () => false,
  selectFileOrDirectory: async () => {
    warnStub('selectFileOrDirectory');
    return null;
  },
  selectImportSessionFile: async () => {
    warnStub('selectImportSessionFile');
    return null;
  },
  getBinaryPath: async (binaryName: string) => binaryName,
  readFile: async () => {
    warnStub('readFile');
    return { file: '', filePath: '', found: false };
  },
  writeFile: async () => {
    warnStub('writeFile');
    return false;
  },
  ensureDirectory: async () => {
    warnStub('ensureDirectory');
    return false;
  },
  listFiles: async () => {
    warnStub('listFiles');
    return [];
  },
  getAllowedExtensions: async () => [],
  getPathForFile: (file: File) => file.name,
  setMenuBarIcon: async () => false,
  getMenuBarIconState: async () => false,
  setDockIcon: async () => false,
  getDockIconState: async () => false,
  getSetting: async <K extends SettingKey>(key: K): Promise<Settings[K]> => {
    const stored = getStoredSettings();
    return (stored[key] ?? defaultSettings[key]) as Settings[K];
  },
  setSetting: async <K extends SettingKey>(key: K, value: Settings[K]): Promise<void> => {
    setStoredSetting(key, value);
  },
  // ACP connection details come from runtimeConfig.ts's /config.json fetch
  // instead - these two are unused but kept for type compatibility.
  getSecretKey: async () => {
    warnStub('getSecretKey (use acp/runtimeConfig.ts instead)');
    return null;
  },
  getAcpUrl: async () => {
    warnStub('getAcpUrl (use acp/runtimeConfig.ts instead)');
    return null;
  },
  setWakelock: async () => false,
  getWakelockState: async () => false,
  setSpellcheck: async () => false,
  getSpellcheckState: async () => false,
  openNotificationsSettings: async () => false,
  isAnyWindowFocused: async () => document.hasFocus(),
  getIsFullScreen: async () => Boolean(document.fullscreenElement),
  onMouseBackButtonClicked: () => warnStub('onMouseBackButtonClicked'),
  offMouseBackButtonClicked: () => warnStub('offMouseBackButtonClicked'),
  on: (channel: string, callback: (event: unknown, ...args: unknown[]) => void) => {
    eventTarget.addEventListener(channel, ((e: CustomEvent) =>
      callback(e, ...(e.detail ?? []))) as EventListener);
  },
  off: (channel: string, callback: (event: unknown, ...args: unknown[]) => void) => {
    eventTarget.removeEventListener(channel, callback as EventListener);
  },
  emit: (channel: string, ...args: unknown[]) => {
    eventTarget.dispatchEvent(new CustomEvent(channel, { detail: args }));
  },
  broadcastThemeChange: () => warnStub('broadcastThemeChange (single-window build, no-op)'),
  openExternal: async (url: string) => {
    window.open(url, '_blank', 'noopener,noreferrer');
  },
  getVersion: () => 'agentic-ui-dev',
  checkForUpdates: async () => {
    warnStub('checkForUpdates (no auto-updater in browser build)');
    return { updateInfo: null, error: null };
  },
  downloadUpdate: async () => ({ success: false, error: 'unsupported in agentic-ui' }),
  installUpdate: () => warnStub('installUpdate'),
  restartApp: () => window.location.reload(),
  onUpdaterEvent: () => warnStub('onUpdaterEvent'),
  getUpdateState: async () => null,
  isUsingGitHubFallback: async () => false,
  getAutoDownloadDisabled: async () => true,
  closeWindow: () => warnStub('closeWindow'),
  hasAcceptedRecipeBefore: async () => false,
  recordRecipeHash: async () => false,
  openDirectoryInExplorer: async () => {
    warnStub('openDirectoryInExplorer');
    return false;
  },
  launchApp: async () => warnStub('launchApp'),
  refreshApp: async () => warnStub('refreshApp'),
  closeApp: async () => warnStub('closeApp'),
  addRecentDir: async () => false,
  listRecentDirs: async () => [],
  listGitWorktreeDirs: async () => [],
};

const appConfigShim = {
  get: (_key: string) => undefined,
  getAll: () => ({}),
};

export function installElectronShim(): void {
  const w = window as unknown as { electron?: unknown; appConfig?: unknown };
  if (!w.electron) {
    w.electron = electronShim;
  }
  if (!w.appConfig) {
    w.appConfig = appConfigShim;
  }
}
