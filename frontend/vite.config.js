import { defineConfig } from 'vite';

const BACKEND_URL = import.meta.env.VITE_API_URL || 'http://backend:8000';
export default defineConfig({
    root: '.',
    build: {
        minify: "terser",
        outDir: 'dist',
        emptyOutDir: true,
        terserOptions: {
            compress: {
                drop_console: true
            },
            mangle: true
        },
        rollupOptions: {
            input: '/setup.js',

        }
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
