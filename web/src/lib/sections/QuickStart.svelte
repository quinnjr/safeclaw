<script lang="ts">
	import CodeBlock from '$lib/components/CodeBlock.svelte';

	const steps = [
		{
			num: '01',
			title: 'Create your directories',
			desc: 'One folder for data, one for config. That\'s it.',
			code: `mkdir -p ~/.local/share/safeclaw
mkdir -p ~/.config/safeclaw
curl -fsSL https://raw.githubusercontent.com/quinnjr/safeclaw/main/config.example.toml \\
  -o ~/.config/safeclaw/config.toml
curl -fsSL https://raw.githubusercontent.com/quinnjr/safeclaw/main/.env.example \\
  -o ~/.config/safeclaw/.env`
		},
		{
			num: '02',
			title: 'Set your secrets',
			desc: 'Edit the .env file with your dashboard password and a JWT secret.',
			code: `# Edit ~/.config/safeclaw/.env
DASHBOARD_PASSWORD=pick-a-strong-password
JWT_SECRET=$(openssl rand -hex 32)`
		},
		{
			num: '03',
			title: 'Run the container',
			desc: 'One command. Dashboard is at localhost:3031.',
			code: `docker run -d \\
  --name safeclaw \\
  --restart unless-stopped \\
  -p 3031:3031 \\
  -v ~/.local/share/safeclaw:/data/safeclaw \\
  -v ~/.config/safeclaw/config.toml:/config/safeclaw/config.toml:ro \\
  --env-file ~/.config/safeclaw/.env \\
  -e NO_JAIL=1 \\
  --entrypoint safeclaw \\
  ghcr.io/quinnjr/safeclaw:latest`
		}
	];
</script>

<section id="quickstart" class="scroll-mt-20 py-20 md:py-28">
	<div class="mx-auto max-w-4xl px-6">
		<div class="mb-14 text-center">
			<div class="mb-4 inline-flex items-center gap-2 rounded-full border border-accent/20 bg-accent/5 px-4 py-1.5 text-sm text-accent-light">
				<i class="fa-brands fa-docker"></i>
				Recommended
			</div>
			<h2 class="mb-4 text-3xl font-bold text-white md:text-4xl">Up and running in 3 steps</h2>
			<p class="mx-auto max-w-2xl text-slate-400">
				Pull the image, set two environment variables, and you're done.
				No Kubernetes. No Terraform. No Rust toolchain. Just Docker.
			</p>
		</div>

		<div class="space-y-10">
			{#each steps as step}
				<div class="relative">
					<div class="mb-4 flex items-center gap-4">
						<span class="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-accent/10 font-mono text-sm font-bold text-accent">
							{step.num}
						</span>
						<div>
							<h3 class="font-semibold text-white">{step.title}</h3>
							<p class="text-sm text-slate-400">{step.desc}</p>
						</div>
					</div>
					<CodeBlock code={step.code} title="terminal" />
				</div>
			{/each}
		</div>

		<div class="mt-12 space-y-4">
			<div class="rounded-xl border border-accent/20 bg-accent/5 p-6 text-center">
				<p class="text-sm text-slate-300">
					<i class="fa-solid fa-circle-info mr-2 text-accent"></i>
					Want Docker Compose instead? Check the
					<a
						href="https://github.com/quinnjr/safeclaw#docker-compose"
						target="_blank"
						rel="noopener"
						class="font-medium text-accent-light underline decoration-accent/30 underline-offset-2 hover:decoration-accent"
					>
						full docs
					</a>
					for a ready-to-use compose file.
				</p>
			</div>
			<p class="text-center text-xs text-slate-600">
				Prefer building from source? You can, but you'll need Rust (stable), Node.js, and pnpm.
				See the
				<a
					href="https://github.com/quinnjr/safeclaw#from-source-no-docker"
					target="_blank"
					rel="noopener"
					class="text-slate-500 underline decoration-slate-700 underline-offset-2 hover:text-slate-400"
				>
					README
				</a>
				for details.
			</p>
		</div>
	</div>
</section>
