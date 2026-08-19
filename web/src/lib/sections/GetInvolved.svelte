<script lang="ts">
	const links = [
		{
			icon: 'fa-brands fa-github',
			title: 'Star on GitHub',
			desc: 'Browse the source, file issues, and send PRs.',
			href: 'https://github.com/quinnjr/safeclaw',
			cta: 'View repository',
			color: 'hover:border-slate-600'
		},
		{
			icon: 'fa-solid fa-book-open',
			title: 'Read CONTRIBUTING.md',
			desc: 'Git workflow, commit standards, code style, and AI co-authorship policy.',
			href: 'https://github.com/quinnjr/safeclaw/blob/main/CONTRIBUTING.md',
			cta: 'Contributing guide',
			color: 'hover:border-accent/40'
		}
	];
</script>

<section id="involved" class="scroll-mt-20 py-20 md:py-28">
	<div class="mx-auto max-w-4xl px-6">
		<div class="mb-14 text-center">
			<h2 class="mb-4 text-3xl font-bold text-white md:text-4xl">Get involved</h2>
			<p class="mx-auto max-w-2xl text-slate-400">
				safeclaw is open source and built in the open. We'd love your help —
				whether that's code, bug reports, docs, or just telling a friend.
			</p>
		</div>

		<div class="grid gap-6 md:grid-cols-3">
			{#each links as link}
				<a
					href={link.href}
					target="_blank"
					rel="noopener"
					class="group flex flex-col rounded-xl border border-slate-800 bg-surface-raised p-6 transition-all {link.color}"
				>
					<i class="{link.icon} mb-4 text-2xl text-slate-500 transition-colors group-hover:text-slate-300"></i>
					<h3 class="mb-2 font-semibold text-white">{link.title}</h3>
					<p class="mb-4 flex-1 text-sm text-slate-400">{link.desc}</p>
					<span class="text-sm font-medium text-accent-light">
						{link.cta}
						<i class="fa-solid fa-arrow-right ml-1 text-xs transition-transform group-hover:translate-x-1"></i>
					</span>
				</a>
			{/each}
		</div>
	</div>
</section>
