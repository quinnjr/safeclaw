<script lang="ts">
    import { onMount, untrack } from 'svelte';
    import { t, initLocale } from './lib/i18n';
    import { dashboard, auth, refreshAll, pushToolEvent, clearLiveFeed, initTheme, sendApprovalNotification } from './lib/state.svelte';
    import type { TabId } from './lib/state.svelte';
    import type { ToolEvent, ApprovalNeededEvent } from './lib/types';
    import LoginOverlay from './components/LoginOverlay.svelte';
    import OnboardingWizard from './components/OnboardingWizard.svelte';
    import Header from './components/Header.svelte';
    import PendingActions from './components/PendingActions.svelte';
    import ActivityLog from './components/ActivityLog.svelte';
    import LiveFeed from './components/LiveFeed.svelte';
    import MemoryPanel from './components/MemoryPanel.svelte';
    import StatsPanel from './components/StatsPanel.svelte';
    import ChatTab from './components/ChatTab.svelte';
    import GoalsTab from './components/GoalsTab.svelte';
    import TradingTab from './components/TradingTab.svelte';
    import SkillsTab from './components/SkillsTab.svelte';
    import KnowledgeTab from './components/KnowledgeTab.svelte';
    import ToolsTab from './components/ToolsTab.svelte';
    import TrashTab from './components/TrashTab.svelte';
    import SecurityTab from './components/SecurityTab.svelte';
    import OperationsTab from './components/OperationsTab.svelte';
    import SettingsTab from './components/SettingsTab.svelte';

    const POLL_INTERVAL_MS = 30_000;

    const tabs: { id: TabId; label: string; icon: string }[] = [
        { id: 'overview', label: 'Overview', icon: 'fa-chart-line' },
        { id: 'chat', label: 'Chat', icon: 'fa-comments' },
        { id: 'goals', label: 'Goals', icon: 'fa-bullseye' },
        { id: 'trading', label: 'Trading', icon: 'fa-chart-candlestick' },
        { id: 'skills', label: 'Skills', icon: 'fa-puzzle-piece' },
        { id: 'knowledge', label: 'Knowledge', icon: 'fa-diagram-project' },
        { id: 'tools', label: 'Tools', icon: 'fa-screwdriver-wrench' },
        { id: 'trash', label: 'Trash', icon: 'fa-trash-can' },
        { id: 'security', label: 'Security', icon: 'fa-shield-halved' },
        { id: 'operations', label: 'Ops', icon: 'fa-server' },
        { id: 'settings', label: 'Settings', icon: 'fa-gear' },
    ];

    function switchTab(id: TabId) {
        dashboard.currentTab = id;
        dashboard.mobileMenuOpen = false;
    }

    async function checkAuth() {
        try {
            const res = await fetch('/api/auth/check');
            const data = await res.json();
            auth.authenticated = data.authenticated === true;
            auth.userId = data.user_id || null;
            auth.role = data.role || null;
            auth.subject = data.subject || null;
        } catch {
            auth.authenticated = false;
        } finally {
            auth.checked = true;
        }
    }

    async function checkOnboarding() {
        try {
            const res = await fetch('/api/onboarding/status');
            const data = await res.json();
            auth.onboardingCompleted = data.completed === true;
        } catch {
            auth.onboardingCompleted = true;
        }
    }

    function handleOnboardingComplete() {
        auth.onboardingCompleted = true;
    }

    let deferredPrompt: Event & { prompt?: () => void } | null = $state(null);
    let showInstallBanner = $state(false);

    onMount(() => {
        initLocale();
        initTheme();
        checkOnboarding();
        checkAuth();
        window.addEventListener('onboarding-complete', handleOnboardingComplete);

        // PWA install prompt
        window.addEventListener('beforeinstallprompt', (e) => {
            e.preventDefault();
            deferredPrompt = e as Event & { prompt: () => void };
            if (!localStorage.getItem('safeclaw-pwa-dismissed')) {
                showInstallBanner = true;
            }
        });

        // Register service worker
        if ('serviceWorker' in navigator) {
            navigator.serviceWorker.register('/sw.js').catch(() => {});
        }

        // Check if notifications were previously granted
        if ('Notification' in window && Notification.permission === 'granted') {
            dashboard.notificationsEnabled = true;
        }

        return () => {
            window.removeEventListener('onboarding-complete', handleOnboardingComplete);
        };
    });

    function installPwa() {
        if (deferredPrompt?.prompt) {
            deferredPrompt.prompt();
            deferredPrompt = null;
            showInstallBanner = false;
        }
    }

    function dismissInstall() {
        showInstallBanner = false;
        localStorage.setItem('safeclaw-pwa-dismissed', '1');
    }

    let evtSource: EventSource | undefined;
    let interval: ReturnType<typeof setInterval> | undefined;

    $effect(() => {
        if (auth.authenticated) {
            untrack(() => refreshAll());

            evtSource = new EventSource('/api/events');
            evtSource.onmessage = (e) => {
                const data = e.data;
                if (data && data.startsWith('{')) {
                    try {
                        const evt = JSON.parse(data) as ToolEvent;
                        if (evt.type) {
                            pushToolEvent(evt);
                            if (evt.type === 'turn_complete' || evt.type === 'approval_needed') {
                                refreshAll();
                            }
                            if (evt.type === 'approval_needed') {
                                const ae = evt as ApprovalNeededEvent;
                                sendApprovalNotification(ae.tool, ae.id);
                            }
                            return;
                        }
                    } catch { /* not JSON, fall through */ }
                }
                refreshAll();
            };
            evtSource.onerror = () => {
                console.error('SSE connection lost, will retry...');
                clearLiveFeed();
            };

            interval = setInterval(refreshAll, POLL_INTERVAL_MS);
        }

        return () => {
            evtSource?.close();
            evtSource = undefined;
            if (interval) {
                clearInterval(interval);
                interval = undefined;
            }
        };
    });
</script>

<!-- Mobile menu overlay -->
{#if dashboard.mobileMenuOpen}
    <div
        class="mobile-menu-overlay mobile-menu-overlay--open"
        onclick={() => dashboard.mobileMenuOpen = false}
        role="presentation"
    ></div>
    <nav class="mobile-menu mobile-menu--open">
        <div class="mobile-menu__header">
            <span class="text-sm font-semibold text-primary-400">
                <i class="fa-solid fa-robot mr-1"></i> {t('header.title')}
            </span>
            <button
                onclick={() => dashboard.mobileMenuOpen = false}
                class="btn btn--ghost btn--icon"
            >
                <i class="fa-solid fa-xmark"></i>
            </button>
        </div>
        <div class="mobile-menu__nav">
            {#each tabs as tab}
                <button
                    class="mobile-menu__nav-item"
                    class:mobile-menu__nav-item--active={dashboard.currentTab === tab.id}
                    onclick={() => switchTab(tab.id)}
                >
                    <i class="fa-solid {tab.icon} w-5 text-center"></i>
                    {t('nav.' + tab.id)}
                </button>
            {/each}
        </div>
    </nav>
{/if}

{#if !auth.checked}
    <!-- Loading: waiting for auth check -->
{:else if auth.onboardingCompleted === false}
    <OnboardingWizard />
{:else if !auth.authenticated}
    <LoginOverlay />
{:else}
    <Header />

    <!-- PWA install banner -->
    {#if showInstallBanner}
        <div class="pwa-banner">
            <div class="pwa-banner__message">
                <i class="fa-solid fa-download"></i>
                <span>{t('pwa.install_hint')}</span>
            </div>
            <div class="pwa-banner__actions">
                <button
                    onclick={installPwa}
                    class="pwa-banner__install-btn"
                >
                    {t('pwa.install')}
                </button>
                <button
                    onclick={dismissInstall}
                    class="pwa-banner__dismiss-btn"
                >
                    {t('pwa.dismiss')}
                </button>
            </div>
        </div>
    {/if}

    <main class="p-3 sm:p-6">
        <!-- Desktop tab bar (hidden on small screens) -->
        <div class="hidden sm:flex border-b border-border mb-4 tab-scroll">
            {#each tabs as tab}
                <button
                    class="nav-tab nav-tab--main"
                    class:nav-tab--active={dashboard.currentTab === tab.id}
                    onclick={() => switchTab(tab.id)}
                >
                    <i class="fa-solid {tab.icon} mr-1.5"></i> {t('nav.' + tab.id)}
                </button>
            {/each}
        </div>

        <!-- Mobile: current tab indicator (visible on small screens) -->
        <div class="flex sm:hidden items-center gap-2 mb-3 text-sm text-text-muted">
            <i class="fa-solid {tabs.find(t => t.id === dashboard.currentTab)?.icon} text-primary-500"></i>
            <span class="font-medium text-text">{t('nav.' + dashboard.currentTab)}</span>
        </div>

        {#if dashboard.currentTab === 'overview'}
            <LiveFeed />
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
                <PendingActions />
                <ActivityLog />
                <MemoryPanel />
                <StatsPanel />
            </div>
        {:else if dashboard.currentTab === 'chat'}
            <ChatTab />
        {:else if dashboard.currentTab === 'goals'}
            <GoalsTab />
        {:else if dashboard.currentTab === 'trading'}
            <TradingTab />
        {:else if dashboard.currentTab === 'skills'}
            <SkillsTab />
        {:else if dashboard.currentTab === 'knowledge'}
            <KnowledgeTab />
        {:else if dashboard.currentTab === 'tools'}
            <ToolsTab />
        {:else if dashboard.currentTab === 'trash'}
            <TrashTab />
        {:else if dashboard.currentTab === 'security'}
            <SecurityTab />
        {:else if dashboard.currentTab === 'operations'}
            <OperationsTab />
        {:else if dashboard.currentTab === 'settings'}
            <SettingsTab />
        {/if}
    </main>
{/if}
