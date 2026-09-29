import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    alias: {
      // Workers 内建模块在 Node 里不存在；生产由 wrangler/esbuild 当外部模块处理。
      'cloudflare:sockets': fileURLToPath(new URL('./test/stubs/cloudflare-sockets.js', import.meta.url)),
    },
  },
});
