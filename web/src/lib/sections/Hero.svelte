<script lang="ts">
	import CodeBlock from '$lib/components/CodeBlock.svelte';

	const pullCommand = 'docker pull ghcr.io/quinnjr/safeclaw:latest';
</script>

<section class="relative overflow-hidden pt-32 pb-20 md:pt-44 md:pb-32">
	<!-- Background glow -->
	<div
		class="pointer-events-none absolute top-0 left-1/2 -z-10 h-[600px] w-[800px] -translate-x-1/2 rounded-full bg-accent/5 blur-3xl"
	></div>

	<div class="mx-auto max-w-4xl px-6 text-center">
		<div class="mb-6 inline-flex items-center gap-2 rounded-full border border-accent/20 bg-accent/5 px-4 py-1.5 text-sm text-accent-light">
			<i class="fa-solid fa-shield-halved"></i>
			Now open source
		</div>

		<h1 class="mb-6 text-4xl font-black tracking-tight text-white md:text-6xl lg:text-7xl">
			Your AI agent.<br />
			Your hardware.<br />
			<span class="text-accent">Your rules.</span>
		</h1>

		<p class="mx-auto mb-10 max-w-2xl text-lg text-slate-400 md:text-xl">
			A self-hosted AI agent that proposes actions — you approve them.
			Six LLM backends, a skill system that grows itself, and a knowledge graph
			that never forgets. One <code class="rounded bg-surface-raised px-1.5 py-0.5 font-mono text-sm text-accent-light">docker pull</code> and you're running.
		</p>

		<div class="mx-auto mb-10 max-w-xl">
			<CodeBlock code={pullCommand} title="terminal" />
			<p class="mt-3 text-center text-xs text-slate-500">
				<i class="fa-brands fa-docker mr-1"></i>
				Multi-arch image (amd64 + arm64) &mdash; works on x86 servers, Raspberry Pi, and Apple Silicon
			</p>
		</div>

		<div class="flex flex-col items-center justify-center gap-4 sm:flex-row">
			<a
				href="#quickstart"
				class="inline-flex items-center gap-2 rounded-xl bg-accent px-6 py-3 font-semibold text-slate-950 transition-all hover:bg-accent-light hover:shadow-lg hover:shadow-accent/20"
			>
				<i class="fa-solid fa-rocket"></i>
				Get Started
			</a>
			<a
				href="https://github.com/quinnjr/safeclaw"
				target="_blank"
				rel="noopener"
				class="inline-flex items-center gap-2 rounded-xl border border-slate-700 bg-surface-raised px-6 py-3 font-semibold text-slate-300 transition-all hover:border-slate-600 hover:bg-surface-overlay"
			>
				<i class="fa-brands fa-github"></i>
				View on GitHub
			</a>
		</div>
	</div>
</section>
