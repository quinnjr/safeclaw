<script lang="ts">
    import { t } from '../lib/i18n';
    import { api } from '../lib/api';
    import type { ActionResponse } from '../lib/types';

    interface CommunitySkill {
        name: string;
        description: string;
        author: string;
        repo: string;
        category: string;
        tags: string[];
        stars: number;
    }

    const FEATURED_SKILLS: CommunitySkill[] = [
        {
            name: 'google-calendar',
            description: 'Monitor and manage Google Calendar events with automatic reminders',
            author: 'safeclaw',
            repo: 'https://github.com/quinnjr/safeclaw-skill-google-calendar',
            category: 'productivity',
            tags: ['calendar', 'google', 'reminders'],
            stars: 0,
        },
        {
            name: 'web-monitor',
            description: 'Monitor websites for changes and send notifications',
            author: 'safeclaw',
            repo: 'https://github.com/quinnjr/safeclaw-skill-web-monitor',
            category: 'data',
            tags: ['monitoring', 'web', 'alerts'],
            stars: 0,
        },
        {
            name: 'email-digest',
            description: 'Summarize and categorize incoming emails with AI-powered triage',
            author: 'safeclaw',
            repo: 'https://github.com/quinnjr/safeclaw-skill-email-digest',
            category: 'communication',
            tags: ['email', 'digest', 'summary'],
            stars: 0,
        },
        {
            name: 'github-issues',
            description: 'Track GitHub issues and PRs, auto-triage with labels',
            author: 'safeclaw',
            repo: 'https://github.com/quinnjr/safeclaw-skill-github-issues',
            category: 'development',
            tags: ['github', 'issues', 'development'],
            stars: 0,
        },
        {
            name: 'rss-reader',
            description: 'Follow RSS/Atom feeds and get AI-summarized updates',
            author: 'safeclaw',
            repo: 'https://github.com/quinnjr/safeclaw-skill-rss-reader',
            category: 'data',
            tags: ['rss', 'feeds', 'news'],
            stars: 0,
        },
        {
            name: 'daily-briefing',
            description: 'Generate a personalized morning briefing from your calendars, email, and news',
            author: 'safeclaw',
            repo: 'https://github.com/quinnjr/safeclaw-skill-daily-briefing',
            category: 'productivity',
            tags: ['briefing', 'summary', 'daily'],
            stars: 0,
        },
    ];

    let searchQuery = $state('');
    let categoryFilter = $state('all');
    let installing = $state<string | null>(null);
    let installStatus = $state<Record<string, 'ok' | 'error'>>({});

    const categories = ['all', 'productivity', 'development', 'communication', 'data'];

    const filtered = $derived(
        FEATURED_SKILLS.filter(s => {
            if (categoryFilter !== 'all' && s.category !== categoryFilter) return false;
            if (searchQuery) {
                const q = searchQuery.toLowerCase();
                return s.name.toLowerCase().includes(q)
                    || s.description.toLowerCase().includes(q)
                    || s.tags.some(t => t.includes(q));
            }
            return true;
        })
    );

    function categoryLabel(cat: string): string {
        const map: Record<string, string> = {
            all: t('marketplace.category_all'),
            productivity: t('marketplace.category_productivity'),
            development: t('marketplace.category_development'),
            communication: t('marketplace.category_communication'),
            data: t('marketplace.category_data'),
        };
        return map[cat] ?? cat;
    }

    function categoryIcon(cat: string): string {
        const map: Record<string, string> = {
            productivity: 'fa-briefcase',
            development: 'fa-code',
            communication: 'fa-envelope',
            data: 'fa-chart-bar',
        };
        return map[cat] ?? 'fa-puzzle-piece';
    }

    async function installSkill(skill: CommunitySkill) {
        installing = skill.name;
        try {
            const resp = await api<ActionResponse>('POST', '/api/skills/import', {
                source: 'git',
                location: skill.repo,
            });
            installStatus = { ...installStatus, [skill.name]: resp.ok ? 'ok' : 'error' };
        } catch {
            installStatus = { ...installStatus, [skill.name]: 'error' };
        }
        installing = null;
    }
</script>

<section class="card mt-4">
    <div class="card__header">
        <h2 class="card__header-title">
            <i class="fa-solid fa-store mr-1.5"></i> {t('marketplace.title')}
        </h2>
        <a
            href="https://github.com/topics/safeclaw-skill"
            target="_blank"
            rel="noopener noreferrer"
            class="text-xs text-primary-400 hover:text-primary-300 transition-colors"
        >
            <i class="fa-brands fa-github mr-1"></i> {t('marketplace.browse_github')}
        </a>
    </div>

    <div class="px-4 py-2 border-b border-border flex flex-col sm:flex-row gap-2">
        <input
            type="text"
            bind:value={searchQuery}
            placeholder={t('marketplace.search')}
            class="form__input flex-1"
        />
        <div class="flex gap-1 flex-wrap">
            {#each categories as cat}
                <button
                    onclick={() => categoryFilter = cat}
                    class="px-2 py-1 text-xs rounded border transition-colors"
                    class:bg-primary-600={categoryFilter === cat}
                    class:text-white={categoryFilter === cat}
                    class:border-primary-600={categoryFilter === cat}
                    class:border-border={categoryFilter !== cat}
                    class:text-text-muted={categoryFilter !== cat}
                >
                    {categoryLabel(cat)}
                </button>
            {/each}
        </div>
    </div>

    <div class="p-3 grid grid-cols-1 md:grid-cols-2 gap-3 max-h-[500px] overflow-y-auto custom-scroll">
        {#if filtered.length === 0}
            <p class="text-text-subtle text-sm italic text-center py-4 col-span-full">{t('marketplace.no_results')}</p>
        {/if}
        {#each filtered as skill (skill.name)}
            <div class="p-3 rounded-lg border border-border bg-surface-muted hover:border-primary-500/30 transition-colors">
                <div class="flex items-start justify-between gap-2">
                    <div class="min-w-0 flex-1">
                        <div class="flex items-center gap-2">
                            <i class="fa-solid {categoryIcon(skill.category)} text-primary-400 text-sm"></i>
                            <span class="text-sm font-semibold text-text">{skill.name}</span>
                        </div>
                        <p class="text-xs text-text-muted mt-1">{skill.description}</p>
                        <div class="flex items-center gap-2 mt-2">
                            <span class="text-[10px] text-text-subtle">{t('marketplace.by')} {skill.author}</span>
                            <div class="flex gap-1">
                                {#each skill.tags.slice(0, 3) as tag}
                                    <span class="text-[10px] px-1.5 py-0.5 rounded bg-surface-elevated border border-border/50 text-text-subtle">{tag}</span>
                                {/each}
                            </div>
                        </div>
                    </div>
                    <div class="flex flex-col items-end gap-1 shrink-0">
                        {#if installStatus[skill.name] === 'ok'}
                            <span class="badge badge--success">
                                <i class="fa-solid fa-check mr-1"></i>{t('marketplace.installed')}
                            </span>
                        {:else if installStatus[skill.name] === 'error'}
                            <span class="badge badge--error">{t('marketplace.failed')}</span>
                        {:else}
                            <button
                                onclick={() => installSkill(skill)}
                                disabled={installing !== null}
                                class="px-3 py-1 text-xs font-medium rounded border border-primary-600 text-primary-400 hover:bg-primary-900/30 transition-colors disabled:opacity-50"
                            >
                                {#if installing === skill.name}
                                    <i class="fa-solid fa-spinner fa-spin mr-1"></i>{t('marketplace.installing')}
                                {:else}
                                    <i class="fa-solid fa-download mr-1"></i>{t('marketplace.install')}
                                {/if}
                            </button>
                        {/if}
                        <a
                            href={skill.repo}
                            target="_blank"
                            rel="noopener noreferrer"
                            class="text-[10px] text-text-subtle hover:text-primary-400 transition-colors"
                        >
                            <i class="fa-brands fa-github mr-0.5"></i> {t('marketplace.repo')}
                        </a>
                    </div>
                </div>
            </div>
        {/each}
    </div>
</section>
