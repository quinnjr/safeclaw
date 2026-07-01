<script lang="ts">
    import { onDestroy } from 'svelte';
    import { createChart, type IChartApi, type ISeriesApi } from 'lightweight-charts';
    import { t } from '../lib/i18n';
    import { api } from '../lib/api';
    import { dashboard } from '../lib/state.svelte';
    import { formatDateTime } from '../lib/time';
    import type { ActionResponse } from '../lib/types';

    interface WatchlistEntry {
        symbol: string;
        added_at: string;
    }

    interface PaperTrade {
        id: number;
        symbol: string;
        side: 'buy' | 'sell';
        qty: number;
        price: number;
        rationale: string;
        decided_at: string;
    }

    interface TradingStatus {
        enabled: boolean;
        interval_minutes: number;
        last_tick: string | null;
        pnl_summary: number;
    }

    interface TradingConfig {
        interval_minutes: number;
        enabled: boolean;
        strategy: string;
    }

    let watchlist = $state<WatchlistEntry[]>([]);
    let trades = $state<PaperTrade[]>([]);
    let status = $state<TradingStatus | null>(null);
    let config = $state<TradingConfig>({ interval_minutes: 5, enabled: false, strategy: '' });
    let error = $state(false);
    let newSymbol = $state('');
    let savingConfig = $state(false);

    let chartEl = $state<HTMLDivElement | null>(null);
    let chart: IChartApi | null = null;
    let pnlSeries: ISeriesApi<'Line'> | null = null;

    async function load() {
        error = false;
        try {
            const [w, tr, st, cfg] = await Promise.all([
                api<WatchlistEntry[]>('GET', '/api/trading/watchlist'),
                api<PaperTrade[]>('GET', '/api/trading/trades'),
                api<TradingStatus>('GET', '/api/trading/status'),
                api<TradingConfig>('GET', '/api/trading/config'),
            ]);
            watchlist = w;
            trades = tr;
            status = st;
            config = cfg;
            renderChart();
        } catch (e) {
            error = true;
            console.error('loadTrading:', e);
        }
    }

    function renderChart() {
        if (!chartEl) return;
        if (!chart) {
            chart = createChart(chartEl, {
                height: 220,
                layout: { background: { color: 'transparent' }, textColor: '#9aa4b2' },
                grid: {
                    vertLines: { color: 'rgba(255,255,255,0.06)' },
                    horzLines: { color: 'rgba(255,255,255,0.06)' },
                },
                timeScale: { timeVisible: true },
            });
            pnlSeries = chart.addLineSeries({ color: '#22c55e', lineWidth: 2 });
        }

        // Cumulative simulated P&L over time, oldest first, one point per trade.
        const sorted = [...trades].sort(
            (a, b) => new Date(a.decided_at).getTime() - new Date(b.decided_at).getTime(),
        );
        let running = 0;
        const points = sorted.map((tr) => {
            running += (tr.side === 'sell' ? 1 : -1) * tr.qty * tr.price;
            return {
                time: Math.floor(new Date(tr.decided_at.replace(' ', 'T') + 'Z').getTime() / 1000) as never,
                value: running,
            };
        });
        pnlSeries?.setData(points);
        chart?.timeScale().fitContent();
    }

    async function addSymbol() {
        const symbol = newSymbol.trim().toUpperCase();
        if (!symbol) return;
        try {
            await api<ActionResponse>('POST', '/api/trading/watchlist', { symbol });
            newSymbol = '';
            load();
        } catch (e) {
            alert((e as Error).message);
        }
    }

    async function removeSymbol(symbol: string) {
        try {
            await api<ActionResponse>('DELETE', `/api/trading/watchlist/${encodeURIComponent(symbol)}`);
            load();
        } catch (e) {
            alert((e as Error).message);
        }
    }

    async function saveConfig() {
        savingConfig = true;
        try {
            await api<ActionResponse>('PUT', '/api/trading/config', config);
            load();
        } catch (e) {
            alert((e as Error).message);
        } finally {
            savingConfig = false;
        }
    }

    $effect(() => {
        if (dashboard.currentTab === 'trading') {
            dashboard.refreshCounter;
            load();
        }
    });

    onDestroy(() => {
        chart?.remove();
        chart = null;
    });
</script>

<section class="card">
    <div class="card__header">
        <h2 class="card__header-title">
            <i class="fa-solid fa-chart-candlestick mr-1.5"></i> {t('trading.title')}
        </h2>
        <button onclick={load} class="btn btn--secondary btn--sm mr-3">
            <i class="fa-solid fa-arrows-rotate mr-1"></i> {t('common.refresh')}
        </button>
    </div>

    <div class="p-3 space-y-4">
        <p class="text-xs text-text-subtle italic">{t('trading.paper_only_notice')}</p>

        {#if error}
            <p class="text-text-subtle text-sm italic text-center py-4">{t('trading.error_loading')}</p>
        {:else}
            <!-- Status strip -->
            {#if status}
                <div class="flex flex-wrap items-center gap-4 p-3 border border-border rounded-md bg-surface-muted text-xs">
                    <span class="font-semibold uppercase tracking-wider text-text-muted">{t('trading.status')}</span>
                    <span class="px-2 py-0.5 rounded-full font-medium {status.enabled ? 'bg-success-500/15 text-success-500' : 'bg-text-subtle/10 text-text-subtle'}">
                        {status.enabled ? t('trading.enabled') : t('trading.disabled')}
                    </span>
                    <span class="text-text-muted">
                        {t('trading.last_tick')}: <span class="font-mono">{status.last_tick ? formatDateTime(status.last_tick) : t('trading.never')}</span>
                    </span>
                    <span class="text-text-muted">
                        {t('trading.simulated_pnl')}:
                        <span class="font-mono {status.pnl_summary >= 0 ? 'text-success-500' : 'text-error-400'}">
                            {status.pnl_summary >= 0 ? '+' : ''}{status.pnl_summary.toFixed(2)}
                        </span>
                    </span>
                </div>
                <p class="text-[11px] text-text-subtle -mt-2">{t('trading.pnl_disclaimer')}</p>
            {/if}

            <!-- P&L chart -->
            <div bind:this={chartEl} class="w-full"></div>

            <!-- Watchlist -->
            <div>
                <h3 class="text-xs font-semibold uppercase tracking-wider text-text-muted mb-2">{t('trading.watchlist')}</h3>
                <div class="flex gap-2 mb-2">
                    <input
                        bind:value={newSymbol}
                        onkeydown={(e) => e.key === 'Enter' && addSymbol()}
                        placeholder="AAPL"
                        class="text-xs px-2 py-1 border border-border rounded-md bg-surface text-text outline-none focus:border-primary-500 w-24"
                    />
                    <button onclick={addSymbol} class="btn btn--secondary btn--sm">{t('trading.add_symbol')}</button>
                </div>
                {#if watchlist.length === 0}
                    <p class="text-text-subtle text-sm italic py-2">{t('trading.no_watchlist')}</p>
                {:else}
                    <div class="flex flex-wrap gap-2">
                        {#each watchlist as w (w.symbol)}
                            <span class="inline-flex items-center gap-1.5 px-2 py-1 text-xs border border-border rounded-md bg-surface-muted">
                                {w.symbol}
                                <button onclick={() => removeSymbol(w.symbol)} class="text-text-subtle hover:text-error-400" aria-label={t('trading.remove')}>
                                    <i class="fa-solid fa-xmark"></i>
                                </button>
                            </span>
                        {/each}
                    </div>
                {/if}
            </div>

            <!-- Decision log -->
            <div>
                <h3 class="text-xs font-semibold uppercase tracking-wider text-text-muted mb-2">{t('trading.decision_log')}</h3>
                {#if trades.length === 0}
                    <p class="text-text-subtle text-sm italic py-2">{t('trading.no_trades')}</p>
                {:else}
                    <div class="space-y-2">
                        {#each trades as tr (tr.id)}
                            <div class="p-3 border border-border rounded-md bg-surface-muted">
                                <div class="flex items-center gap-2 text-sm">
                                    <span class="font-semibold">{tr.symbol}</span>
                                    <span class="px-1.5 py-0.5 rounded-full text-[11px] font-medium {tr.side === 'buy' ? 'bg-success-500/15 text-success-500' : 'bg-error-500/12 text-error-400'}">
                                        {tr.side}
                                    </span>
                                    <span class="text-text-muted text-xs">{tr.qty} @ {tr.price.toFixed(2)}</span>
                                    <span class="text-text-subtle text-[11px] ml-auto font-mono">{formatDateTime(tr.decided_at)}</span>
                                </div>
                                <div class="text-xs text-text-muted mt-1">{tr.rationale}</div>
                            </div>
                        {/each}
                    </div>
                {/if}
            </div>

            <!-- Config -->
            <div>
                <h3 class="text-xs font-semibold uppercase tracking-wider text-text-muted mb-2">{t('trading.config')}</h3>
                <div class="space-y-3 p-3 border border-border rounded-md bg-surface-muted">
                    <label class="flex items-center gap-2 text-sm">
                        <input type="checkbox" bind:checked={config.enabled} />
                        {t('trading.enabled')}
                    </label>
                    <label class="block text-sm">
                        {t('trading.interval_minutes')}
                        <input
                            type="number"
                            min="1"
                            bind:value={config.interval_minutes}
                            class="mt-1 w-24 text-xs px-2 py-1 border border-border rounded-md bg-surface text-text outline-none focus:border-primary-500"
                        />
                    </label>
                    <label class="block text-sm">
                        {t('trading.strategy')}
                        <textarea
                            bind:value={config.strategy}
                            placeholder={t('trading.strategy_placeholder')}
                            rows="3"
                            class="mt-1 w-full text-xs px-2 py-1.5 border border-border rounded-md bg-surface text-text outline-none focus:border-primary-500"
                        ></textarea>
                    </label>
                    <button onclick={saveConfig} disabled={savingConfig} class="btn btn--primary btn--sm">
                        {savingConfig ? t('common.saving') : t('trading.save_config')}
                    </button>
                </div>
            </div>
        {/if}
    </div>
</section>
