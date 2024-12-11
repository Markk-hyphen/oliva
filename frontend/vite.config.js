import { defineConfig } from 'vite';

const BACKEND_URL = import.meta.env.VITE_API_URL;
export default defineConfig({
    root: 'frontend',
    build: {
        outDir: 'dist',
        emptyOutDir: true,
    },
    server: {
        proxy: {
            host: '0.0.0.0',
            port: 3000,
            '/api': {
                target: BACKEND_URL, // Handled by Docker DNS
                changeOrigin: true, // Ensures the Host header matches the target
            },
            '/.well-known/mercure': {
                target: BACKEND_URL,
                changeOrigin: true,
            },
        },
    },
});
