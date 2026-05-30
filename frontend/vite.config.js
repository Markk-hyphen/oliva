import { defineConfig, loadEnv } from 'vite';

export default defineConfig(({ mode }) => {
    const env = loadEnv(mode, process.cwd(), ['VITE_']);
    return {
            define: {
                'import.meta.env.VITE_API_URL': JSON.stringify(env.VITE_API_URL)
            },
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
            hmr: {
                clientPort: 3000
            },
            proxy: {
                '/api': {
                    target: env.VITE_API_URL, // Handled by Docker DNS
                    changeOrigin: true, // Ensures the Host header matches the target
                },
                '/.well-known/mercure': {
                    target: env.VITE_API_URL,
                    changeOrigin: true,
                },
            },
        }
}});
