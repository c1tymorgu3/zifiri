import { defineConfig } from 'vite';

export default defineConfig({
  build: {
    target: 'es2022',
    assetsDir: 'assets',
    // Single entry, modern browsers: no preload polyfill, hence no fetch in the bundle.
    modulePreload: { polyfill: false },
  },
});
