import { defineConfig, loadEnv } from 'vite';

// Vite is a plain upstream of the gateway (dev): it serves modules at :3000
// inside the app_network and knows nothing about /api or /.well-known/mercure.
// The gateway (gateway/Caddyfile) routes those to the backend; Vite's old
// `proxy` block and `VITE_API_URL` are gone (grep shows no other reader).
// HMR's clientPort is removed too: Vite 6 defaults to the page's own port,
// which is the gateway's — see `importMetaUrl.port` in vite/dist/client/client.mjs.
export default defineConfig(({ mode }) => {
    const env = loadEnv(mode, process.cwd(), ['VITE_']);
    return {
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
        },
        server: {
            host: '0.0.0.0',
            port: 3000,
            strictPort: true,
        },
    };
});
