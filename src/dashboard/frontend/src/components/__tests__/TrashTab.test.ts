import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import TrashTab from '../TrashTab.svelte';

vi.mock('../../lib/api', () => ({
    api: vi.fn(() => Promise.resolve({ items: [], stats: { count: 1, total_bytes: 1024 } })),
}));

vi.mock('../../lib/state.svelte', () => ({
    dashboard: { refreshCounter: 0, currentTab: 'trash', currentMemoryTab: 'core' },
}));

describe('TrashTab', () => {
    beforeEach(() => {
        vi.clearAllMocks();
    });

    it('renders the Trash heading', () => {
        render(TrashTab);
        expect(screen.getByText('Trash')).toBeTruthy();
    });

    it('renders Empty Trash button', async () => {
        render(TrashTab);
        expect(await screen.findByText('Empty Trash')).toBeTruthy();
    });
});
