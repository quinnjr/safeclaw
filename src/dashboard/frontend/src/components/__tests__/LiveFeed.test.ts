import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import LiveFeed from '../LiveFeed.svelte';
import { liveFeed, clearLiveFeed, pushToolEvent } from '../../lib/state.svelte';
import * as api from '../../lib/api';

describe('LiveFeed', () => {
    beforeEach(() => {
        clearLiveFeed();
        vi.spyOn(api, 'api').mockResolvedValue([]);
    });

    it('renders "No tool events yet" when empty', async () => {
        render(LiveFeed);
        await vi.waitFor(() => {
            expect(screen.getByText(/No tool events yet/)).toBeInTheDocument();
        });
    });

    it('renders events when liveFeed has events', async () => {
        pushToolEvent({
            type: 'tool_start',
            timestamp: new Date().toISOString(),
            tool: 'exec',
            reasoning: 'run command',
            auto_approved: true,
        });
        render(LiveFeed);
        await vi.waitFor(() => {
            expect(screen.getByText(/Executing exec/)).toBeInTheDocument();
        });
    });

    it('collapse/expand toggle', async () => {
        render(LiveFeed);
        const button = screen.getByRole('button', { name: /Tool Activity/i });
        expect(button).toBeInTheDocument();
        // Initially expanded - content visible
        expect(screen.getByText(/No tool events yet/)).toBeInTheDocument();
        await fireEvent.click(button);
        // After click, collapsed - content hidden (section with max-h-72 is inside expanded block)
        await vi.waitFor(() => {
            expect(screen.queryByText(/No tool events yet/)).not.toBeInTheDocument();
        });
        await fireEvent.click(button);
        // Expand again
        await vi.waitFor(() => {
            expect(screen.getByText(/No tool events yet/)).toBeInTheDocument();
        });
    });
});
