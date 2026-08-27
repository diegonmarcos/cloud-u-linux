import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

// Standalone build config for agentic-ui (no Electron Forge). Adapted from
// upstream goose-desktop's vite.renderer.config.mts:
//  - dropped the GOOSE_TUNNEL define (Electron-tunnel-only feature)
//  - dropped the @aaif/goose-sdk dev-only optimizeDeps exclusion (that was a
//    workaround for a local pnpm workspace symlink; we consume the published
//    npm package here instead)
//  - added @vitejs/plugin-react explicitly - Electron Forge's plugin-vite
//    injected it automatically upstream, but we run plain `vite build`
export default defineConfig({
  plugins: [react(), tailwindcss()],

  build: {
    target: 'esnext',
    outDir: 'dist',
  },
});
