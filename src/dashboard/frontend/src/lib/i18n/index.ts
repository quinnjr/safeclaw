// Re-export shim: bare `from '../lib/i18n'` imports resolve to this file,
// but the $state rune only compiles correctly in a `.svelte.ts` module, so
// the actual implementation lives in index.svelte.ts.
export * from './index.svelte';
