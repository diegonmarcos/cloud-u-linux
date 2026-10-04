// Runtime configuration for the standalone (non-Electron) agentic-ui build.
//
// In upstream goose-desktop, the renderer got the ACP websocket URL and
// secret key from the Electron main process via IPC (window.electron.getAcpUrl()
// / window.electron.getSecretKey()). This build has no Electron main process,
// so instead we fetch a small runtime JSON file, `/config.json`, served
// alongside the built static assets. This keeps the built JS bundle
// environment-agnostic: the same `dist/` output can point at different
// goosed backends just by swapping config.json next to it (no rebuild).
//
// Expected shape of /config.json:
//   { "goosedUrl": "http://10.0.0.6:3227", "secretKey": "..." }

import { acpWebSocketUrlFromHttpBase } from './url';

export type RuntimeConfig = {
  goosedUrl: string;
  secretKey: string;
};

let cachedConfig: Promise<RuntimeConfig> | null = null;

async function fetchRuntimeConfig(): Promise<RuntimeConfig> {
  const response = await fetch('/config.json', { cache: 'no-store' });
  if (!response.ok) {
    throw new Error(`Failed to load /config.json: ${response.status} ${response.statusText}`);
  }

  const data = (await response.json()) as Partial<RuntimeConfig>;
  if (!data.goosedUrl || !data.secretKey) {
    throw new Error('/config.json must contain "goosedUrl" and "secretKey"');
  }

  return { goosedUrl: data.goosedUrl, secretKey: data.secretKey };
}

export function getRuntimeConfig(): Promise<RuntimeConfig> {
  if (!cachedConfig) {
    cachedConfig = fetchRuntimeConfig().catch((error) => {
      // Allow retrying on next call if the fetch failed.
      cachedConfig = null;
      throw error;
    });
  }
  return cachedConfig;
}

export async function getAcpWebSocketUrl(): Promise<string> {
  const { goosedUrl, secretKey } = await getRuntimeConfig();
  return acpWebSocketUrlFromHttpBase(goosedUrl, secretKey);
}
