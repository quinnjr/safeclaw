import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import ToolsTab from '../ToolsTab.svelte';

vi.mock('../../lib/api', () => ({
    api: vi.fn(() => Promise.resolve([])),
}));

vi.mock('../../lib/state.svelte', () => ({
    dashboard: { refreshCounter: 0, currentTab: 'tools', currentMemoryTab: 'core' },
}));

describe('ToolsTab', () => {
    beforeEach(() => {
        vi.clearAllMocks();
    });

    it('renders the heading', () => {
        render(ToolsTab);
        expect(screen.getByText('Registered Tools')).toBeTruthy();
    });

    it('shows empty state when no tools', async () => {
        render(ToolsTab);
        expect(await screen.findByText(/No tools loaded/)).toBeTruthy();
    });
});
