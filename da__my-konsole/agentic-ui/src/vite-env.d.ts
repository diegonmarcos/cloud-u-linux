/// <reference types="vite/client" />

declare module '*.json' {
  const value: Record<string, unknown>;
  export default value;
}

declare module '*.png' {
  const value: string;
  export default value;
}

declare module '*.jpg' {
  const value: string;
  export default value;
}

declare module '*.jpeg' {
  const value: string;
  export default value;
}

declare module '*.gif' {
  const value: string;
  export default value;
}

declare module '*.svg' {
  const value: string;
  export default value;
}

declare module '*.mp3' {
  const value: string;
  export default value;
}

declare module '*.mp4' {
  const value: string;
  export default value;
}

declare module '*.md?raw' {
  const value: string;
  export default value;
}

declare global {
  interface Window {
    isCreatingRecipe?: boolean;
    // TODO(agentic-ui): stubbed - was Electron-only (see src/electronShim.ts).
    // Typed loosely (not the full upstream ElectronAPI/AppConfigAPI shape)
    // since this build only ever calls the shim, never the real Electron API.
    electron: Record<string, (...args: never[]) => unknown> & {
      platform: string;
      on: (channel: string, cb: (...args: never[]) => void) => void;
      off: (channel: string, cb: (...args: never[]) => void) => void;
    };
    appConfig: {
      get: (key: string) => unknown;
      getAll: () => Record<string, unknown>;
    };
  }

  interface WindowEventMap {
    'add-active-session': CustomEvent<{
      sessionId: string;
      initialMessage?: string;
    }>;
    'clear-initial-message': CustomEvent<{
      sessionId: string;
    }>;
    responseStyleChanged: CustomEvent;
    'session-created': CustomEvent<{ session?: import('./types/session').Session }>;
    'session-deleted': CustomEvent<{ sessionId: string }>;
    'session-renamed': CustomEvent<{
      sessionId: string;
      newName: string;
      userInitiated?: boolean;
    }>;
  }
}

export {};
