<script lang="ts">
	import { base } from '$app/paths';

	let scrolled = $state(false);

	function onScroll() {
		scrolled = window.scrollY > 20;
	}

	const links = [
		{ label: 'Features', href: '#features' },
		{ label: 'Quick Start', href: '#quickstart' },
		{ label: 'Architecture', href: '#architecture' },
		{ label: 'Skills', href: '#skills' }
	];

	let mobileOpen = $state(false);
</script>

<svelte:window onscroll={onScroll} />

<nav
	class="fixed top-0 right-0 left-0 z-50 transition-all duration-300 {scrolled
		? 'bg-slate-950/95 shadow-lg shadow-black/20 backdrop-blur-md'
		: 'bg-transparent'}"
>
	<div class="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
		<a href="{base}/" class="flex items-center gap-3 text-lg font-bold tracking-tight">
			<span
				class="flex h-8 w-8 items-center justify-center rounded-lg bg-accent font-mono text-sm font-black text-slate-950"
				>SA</span
			>
			<span class="text-slate-100">safeclaw</span>
		</a>

		<div class="hidden items-center gap-8 md:flex">
			{#each links as link}
				<a
					href={link.href}
					class="text-sm text-slate-400 transition-colors hover:text-accent-light">{link.label}</a
				>
			{/each}
			<a
				href="https://github.com/quinnjr/safeclaw"
				target="_blank"
				rel="noopener"
				class="flex items-center gap-2 rounded-lg bg-surface-raised px-4 py-2 text-sm text-slate-300 transition-colors hover:bg-surface-overlay"
			>
				<i class="fa-brands fa-github"></i>
				GitHub
			</a>
		</div>

		<button
			class="text-slate-400 transition-colors hover:text-slate-100 md:hidden"
			onclick={() => (mobileOpen = !mobileOpen)}
			aria-label="Toggle menu"
		>
			<i class="fa-solid {mobileOpen ? 'fa-xmark' : 'fa-bars'} text-xl"></i>
		</button>
	</div>

	{#if mobileOpen}
		<div class="border-t border-slate-800 bg-slate-950/98 px-6 pb-4 backdrop-blur-md md:hidden">
			{#each links as link}
				<a
					href={link.href}
					class="block py-3 text-sm text-slate-400 transition-colors hover:text-accent-light"
					onclick={() => (mobileOpen = false)}>{link.label}</a
				>
			{/each}
			<a
				href="https://github.com/quinnjr/safeclaw"
				target="_blank"
				rel="noopener"
				class="mt-2 flex items-center gap-2 text-sm text-slate-400 transition-colors hover:text-accent-light"
			>
				<i class="fa-brands fa-github"></i>
				GitHub
			</a>
		</div>
	{/if}
</nav>
