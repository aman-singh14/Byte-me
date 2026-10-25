import { defineConfig } from 'vite';
import { viteSingleFile } from 'vite-plugin-singlefile';
export default defineConfig({
  plugins: [viteSingleFile(), {
    name: 'helper-room-links',
    configureServer(server) {
      server.middlewares.use((request, _response, next) => {
        if (/^\/h\/[^/?]+(?:\?|$)/.test(request.url || '')) {
          request.url = '/helper.html' + new URL(request.url, 'http://localhost').search;
        }
        next();
      });
    },
  }],
  build: { outDir: '../backend/static', emptyOutDir: false, rollupOptions: { input: 'helper.html' } },
  server: { proxy: { '/ws': { target: 'ws://localhost:8020', ws: true }, '/rooms': 'http://localhost:8020', '/room-info': 'http://localhost:8020', '/livekit-token': 'http://localhost:8020' } },
  test: { environment: 'jsdom' },
});
