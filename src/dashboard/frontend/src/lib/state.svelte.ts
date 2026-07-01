import type { ToolEvent } from './types';

const MAX_FEED_EVENTS = 100;

export type TabId = 'overview' | 'chat' | 'goals' | 'trading' | 'skills' | 'knowledge' | 'tools' | 'trash' | 'security' | 'operations' | 'settings';

export const dashboard = $state({
    refreshCounter: 0,
    currentTab: 'overview' as TabId,
    currentMemoryTab: 'core' as 'core' | 'conversation' | 'archival',
    mobileMenuOpen: false,
    theme: 'dark' as 'dark' | 'light',
    notificationsEnabled: false,
});

export const auth = $state({
    checked: false,
    authenticated: false,
    userId: null as string | null,
    role: null as string | null,
    subject: null as string | null,
    onboardingCompleted: null as boolean | null,
});

export function initTheme(): void {
    const stored = localStorage.getItem('safeclaw-theme');
    if (stored === 'light' || stored === 'dark') {
        dashboard.theme = stored;
    }
    applyTheme(dashboard.theme);
}

export function toggleTheme(): void {
    dashboard.theme = dashboard.theme === 'dark' ? 'light' : 'dark';
    localStorage.setItem('safeclaw-theme', dashboard.theme);
    applyTheme(dashboard.theme);
}

function applyTheme(theme: 'dark' | 'light'): void {
    document.documentElement.setAttribute('data-theme', theme);
}

export function requestNotifications(): void {
    if (!('Notification' in window)) return;
    if (Notification.permission === 'granted') {
        dashboard.notificationsEnabled = true;
        return;
    }
    if (Notification.permission !== 'denied') {
        Notification.requestPermission().then((perm) => {
            dashboard.notificationsEnabled = perm === 'granted';
        });
    }
}

export function sendApprovalNotification(tool: string, id: string): void {
    if (!dashboard.notificationsEnabled) return;
    if (document.hasFocus()) return;
    const n = new Notification('Approval Required', {
        body: `${tool} needs your approval`,
        icon: '/manifest-icon-192.png',
        tag: `approval-${id}`,
    });
    n.onclick = () => {
        window.focus();
        dashboard.currentTab = 'overview';
        n.close();
    };
}

/** Live feed of streaming tool progress events. */
export const liveFeed = $state({
    events: [] as ToolEvent[],
    /** True while the LLM is thinking (between `thinking` and `turn_complete`). */
    isThinking: false,
    /** Name of the currently-executing tool, if any. */
    activeTool: null as string | null,
});

export function refreshAll(): void {
    dashboard.refreshCounter++;
}

/** Push a parsed SSE tool event into the live feed. */
export function pushToolEvent(event: ToolEvent): void {
    liveFeed.events = [event, ...liveFeed.events].slice(0, MAX_FEED_EVENTS);

    switch (event.type) {
        case 'thinking':
            liveFeed.isThinking = true;
            liveFeed.activeTool = null;
            break;
        case 'tool_start':
            liveFeed.activeTool = event.tool;
            break;
        case 'tool_result':
            liveFeed.activeTool = null;
            break;
        case 'turn_complete':
        case 'error':
            liveFeed.isThinking = false;
            liveFeed.activeTool = null;
            break;
    }
}

/** Clear the live feed (e.g. on disconnect). */
export function clearLiveFeed(): void {
    liveFeed.events = [];
    liveFeed.isThinking = false;
    liveFeed.activeTool = null;
}
