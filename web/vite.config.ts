import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

// The API serves /api on the same origin in production (behind the proxy); in development Vite
// forwards it, so the session cookie (SameSite=Strict) stays first-party. O_API_URL names the API.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
    proxy: { '/api': process.env.O_API_URL ?? 'http://127.0.0.1:8770' },
  },
});
