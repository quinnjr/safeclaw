import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import PendingActions from '../PendingActions.svelte';

vi.mock('../../lib/api', () => ({
    api: vi.fn(() => Promise.resolve([])),
}));

vi.mock('../../lib/state.svelte', () => ({
    dashboard: { refreshCounter: 0, currentTab: 'overview', currentMemoryTab: 'core' },
    refreshAll: vi.fn(),
}));

describe('PendingActions', () => {
    beforeEach(() => {
        vi.clearAllMocks();
    });

    it('renders the heading', () => {
        render(PendingActions);
        expect(screen.getByText('Pending Actions')).toBeTruthy();
    });

    it('renders Approve All and Reject All buttons', () => {
        render(PendingActions);
        expect(screen.getByText('Approve All')).toBeTruthy();
        expect(screen.getByText('Reject All')).toBeTruthy();
    });

    it('shows empty state when no actions', async () => {
        render(PendingActions);
        expect(await screen.findByText(/No pending actions/)).toBeTruthy();
    });
});
