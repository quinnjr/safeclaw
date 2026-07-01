/// <reference types="vitest" />
import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import { svelteTesting } from '@testing-library/svelte/vite';
import tailwindcss from '@tailwindcss/vite';
import { resolve } from 'path';

export default defineConfig({
    plugins: [tailwindcss(), svelte(), svelteTesting()],
    test: {
        globals: true,
        environment: 'jsdom',
        setupFiles: ['./src/test/setup.ts'],
        testTransformMode: { web: [/\.svelte$/, /\.svelte\.[jt]s$/] },
    },
    build: {
        outDir: resolve(import.meta.dirname!, '../ui'),
        emptyOutDir: false,
        rollupOptions: {
            input: resolve(import.meta.dirname!, 'src/main.ts'),
            output: {
                entryFileNames: 'app.js',
                assetFileNames: (info) => {
                    if (info.names?.some(n => n.endsWith('.css'))) return 'style.css';
                    return '[name][extname]';
                },
            },
        },
    },
});
