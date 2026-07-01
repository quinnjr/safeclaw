<script lang="ts">
    import { onMount } from 'svelte';
    import { t } from '../lib/i18n';
    import { api } from '../lib/api';
    import { liveFeed, clearLiveFeed, pushToolEvent } from '../lib/state.svelte';
    import { formatTime as fmtTime } from '../lib/time';
    import type { ToolEvent } from '../lib/types';

    let expanded = $state(true);

    onMount(async () => {
        if (liveFeed.events.length === 0) {
            try {
                const buffered = await api<ToolEvent[]>('GET', '/api/tool-events?limit=50');
                for (const evt of buffered) {
                    pushToolEvent(evt);
                }
            } catch (e) {
                console.error('Failed to load buffered tool events:', e);
            }
        }
    });

    function eventIcon(evt: ToolEvent): string {
        switch (evt.type) {
            case 'thinking': return 'fa-brain';
            case 'tool_start': return 'fa-play';
            case 'tool_result': return evt.success ? 'fa-circle-check' : 'fa-circle-xmark';
            case 'approval_needed': return 'fa-shield-halved';
            case 'turn_complete': return 'fa-flag-checkered';
            case 'error': return 'fa-triangle-exclamation';
            default: return 'fa-circle';
        }
    }

    function eventColor(evt: ToolEvent): string {
        switch (evt.type) {
            case 'thinking': return 'text-info-500';
            case 'tool_start': return 'text-primary-500';
            case 'tool_result': return evt.success ? 'text-success-500' : 'text-error-500';
            case 'approval_needed': return 'text-warning-500';
            case 'turn_complete': return 'text-success-400';
            case 'error': return 'text-error-500';
            default: return 'text-text-muted';
        }
    }

    function bgColor(evt: ToolEvent): string {
        switch (evt.type) {
            case 'thinking': return 'border-l-info-500';
            case 'tool_start': return 'border-l-primary-500';
            case 'tool_result': return evt.success ? 'border-l-success-500' : 'border-l-error-500';
            case 'approval_needed': return 'border-l-warning-500';
            case 'turn_complete': return 'border-l-success-400';
            case 'error': return 'border-l-error-500';
            default: return 'border-l-border';
        }
    }

    function eventLabel(evt: ToolEvent): string {
        switch (evt.type) {
            case 'thinking':
                if (evt.context === 'follow_up_after_approval') return 'Generating follow-up reply…';
                return `Thinking (turn ${evt.turn + 1}/${evt.max_turns})…`;
            case 'tool_start': {
                const mode = evt.auto_approved ? 'auto' : evt.approved ? 'approved' : 'manual';
                return `Executing ${evt.tool} [${mode}]`;
            }
            case 'tool_result':
                return `${evt.tool}: ${evt.success ? 'success' : 'error'}`;
            case 'approval_needed':
                return `${evt.tool} needs approval`;
            case 'turn_complete': {
                if (evt.exhausted) return `Max turns exhausted (${evt.turns_used})`;
                const approvalNote = evt.pending_approvals ? `, ${evt.pending_approvals} awaiting approval` : '';
                return `Complete in ${evt.turns_used} turn${evt.turns_used === 1 ? '' : 's'}${approvalNote}`;
            }
            case 'error':
                return evt.message;
            default:
                return 'Unknown event';
        }
    }

    function eventDetail(evt: ToolEvent): string | null {
        switch (evt.type) {
            case 'tool_start':
                return evt.reasoning || null;
            case 'tool_result':
                return evt.output_preview || null;
            case 'approval_needed':
                return evt.reasoning || null;
            default:
                return null;
        }
    }

    function formatTime(ts: string): string {
        // LiveFeed timestamps are ISO strings from SSE events; use the shared
        // parser but add seconds for more precision in the feed.
        try {
            const d = new Date(ts);
            return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        } catch {
            return '';
        }
    }

    const hasEvents = $derived(liveFeed.events.length > 0);
    const isActive = $derived(liveFeed.isThinking || liveFeed.activeTool !== null);
</script>

<section class="card">
    <div class="flex justify-between items-center border-b border-border">
        <button
            class="flex items-center gap-2 text-xs font-semibold px-4 py-3 uppercase tracking-wider text-text-muted hover:text-text transition-colors"
            onclick={() => expanded = !expanded}
        >
            {#if isActive}
                <span class="relative flex h-2.5 w-2.5">
                    <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-primary-500 opacity-75"></span>
                    <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-primary-500"></span>
                </span>
            {:else}
                <i class="fa-solid fa-bolt"></i>
            {/if}
            {t('feed.title')}
            {#if hasEvents}
                <span class="text-[10px] bg-surface-muted text-text-subtle px-1.5 py-0.5 rounded-full normal-case tracking-normal font-normal">
                    {liveFeed.events.length}
                </span>
            {/if}
            <i class="fa-solid {expanded ? 'fa-chevron-up' : 'fa-chevron-down'} text-[10px] ml-1"></i>
        </button>
        <div class="flex items-center gap-2 pr-3">
            {#if liveFeed.activeTool}
                <span class="text-[11px] text-primary-400 font-mono animate-pulse">
                    <i class="fa-solid fa-gear fa-spin mr-1"></i>{liveFeed.activeTool}
                </span>
            {/if}
            {#if liveFeed.isThinking && !liveFeed.activeTool}
                <span class="text-[11px] text-info-400 animate-pulse">
                    <i class="fa-solid fa-brain mr-1"></i>{t('feed.thinking')}…
                </span>
            {/if}
            {#if hasEvents}
                <button
                    onclick={() => clearLiveFeed()}
                    class="text-[11px] text-text-subtle hover:text-text-muted transition-colors"
                    title="Clear feed"
                >
                    <i class="fa-solid fa-xmark"></i>
                </button>
            {/if}
        </div>
    </div>

    {#if expanded}
        <div class="max-h-72 overflow-y-auto custom-scroll">
            {#if !hasEvents}
                <p class="text-text-subtle text-sm italic text-center py-6">
                    {t('feed.no_events')}
                </p>
            {:else}
                <div class="divide-y divide-border-muted">
                    {#each liveFeed.events as evt, i}
                        <div class="flex items-start gap-2.5 px-4 py-2.5 border-l-2 {bgColor(evt)} {i === 0 && isActive ? 'bg-surface-muted/50' : ''}">
                            <i class="fa-solid {eventIcon(evt)} {eventColor(evt)} text-xs mt-0.5 w-4 text-center shrink-0"></i>
                            <div class="flex-1 min-w-0">
                                <div class="text-sm text-text leading-snug">
                                    {eventLabel(evt)}
                                </div>
                                {#if eventDetail(evt)}
                                    <div class="text-xs text-text-muted mt-0.5 truncate font-mono" title={eventDetail(evt) ?? undefined}>
                                        {eventDetail(evt)}
                                    </div>
                                {/if}
                            </div>
                            <div class="text-[10px] text-text-subtle whitespace-nowrap shrink-0 mt-0.5">
                                {formatTime(evt.timestamp)}
                            </div>
                        </div>
                    {/each}
                </div>
            {/if}
        </div>
    {/if}
</section>
