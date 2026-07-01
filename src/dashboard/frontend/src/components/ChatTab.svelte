<script lang="ts">
    import { onMount, tick } from 'svelte';
    import { t } from '../lib/i18n';
    import { api } from '../lib/api';
    import { dashboard, liveFeed, auth } from '../lib/state.svelte';
    import { formatTime } from '../lib/time';
    import type { ConversationMessage, ChatResponse } from '../lib/types';

    let messages = $state<ConversationMessage[]>([]);
    let input = $state('');
    let sending = $state(false);
    let error = $state('');
    let messagesEl: HTMLDivElement | undefined = $state();

    async function loadHistory() {
        try {
            messages = await api<ConversationMessage[]>('GET', '/api/memory/conversation');
            await tick();
            scrollToBottom();
        } catch (e) {
            console.error('loadChat:', e);
        }
    }

    function scrollToBottom() {
        if (messagesEl) {
            messagesEl.scrollTop = messagesEl.scrollHeight;
        }
    }

    async function send() {
        const text = input.trim();
        if (!text || sending) return;

        error = '';
        sending = true;
        input = '';

        // Optimistic: show user message immediately
        messages = [...messages, {
            id: Date.now(),
            role: 'user',
            content: text,
            created_at: new Date().toISOString(),
        }];
        await tick();
        scrollToBottom();

        try {
            const body: any = { message: text };
            if (auth.userId) body.user_id = auth.userId;
            const res = await api<ChatResponse>('POST', '/api/chat', body);
            // Replace optimistic history with real data
            await loadHistory();
        } catch (e: any) {
            error = e?.message || t('chat.send_failed');
            // Reload to get accurate state
            await loadHistory();
        } finally {
            sending = false;
            await tick();
            scrollToBottom();
        }
    }

    function handleKey(e: KeyboardEvent) {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            send();
        }
    }

    onMount(() => {
        loadHistory();
    });

    // Refresh when SSE fires an update (other panels use the same pattern)
    $effect(() => {
        dashboard.refreshCounter;
        if (!sending) {
            loadHistory();
        }
    });
</script>

<div class="flex flex-col h-[calc(100vh-140px)]">
    <!-- Messages area -->
    <div
        bind:this={messagesEl}
        class="flex-1 overflow-y-auto custom-scroll p-4 space-y-3"
    >
        {#if messages.length === 0 && !sending}
            <div class="flex items-center justify-center h-full">
                <div class="text-center text-text-subtle">
                    <i class="fa-solid fa-comments text-3xl mb-3 block text-text-subtle"></i>
                    <p class="text-sm">{t('chat.no_messages')}</p>
                </div>
            </div>
        {:else}
            {#each messages as msg (msg.id)}
                {#if msg.role === 'user'}
                    <div class="flex justify-end">
                        <div class="max-w-[70%] min-w-[120px]">
                            <div class="chat-bubble chat-bubble--user whitespace-pre-wrap break-words">
                                {msg.content}
                            </div>
                            <div class="text-[10px] text-text-subtle mt-0.5 text-right">
                                {formatTime(msg.created_at)}
                            </div>
                        </div>
                    </div>
                {:else if msg.role === 'assistant'}
                    <div class="flex justify-start">
                        <div class="max-w-[70%] min-w-[120px]">
                            <div class="chat-bubble chat-bubble--assistant whitespace-pre-wrap break-words">
                                {msg.content}
                            </div>
                            <div class="text-[10px] text-text-subtle mt-0.5">
                                {formatTime(msg.created_at)}
                            </div>
                        </div>
                    </div>
                {:else}
                    <!-- system messages -->
                    <div class="flex justify-center">
                        <div class="chat-bubble chat-bubble--system max-w-[80%] truncate">
                            {msg.content}
                        </div>
                    </div>
                {/if}
            {/each}

            {#if sending}
                <div class="flex justify-start">
                    <div class="min-w-[120px] max-w-[70%]">
                        <div class="chat-bubble chat-bubble--assistant text-text-muted">
                            {#if liveFeed.activeTool}
                                <i class="fa-solid fa-gear fa-spin mr-1.5 text-primary-500"></i>
                                <span class="text-primary-400 font-mono">{liveFeed.activeTool}</span>
                                <span class="text-text-subtle ml-1">running…</span>
                            {:else if liveFeed.isThinking}
                                <i class="fa-solid fa-brain mr-1.5 text-info-500 animate-pulse"></i>Thinking…
                            {:else}
                                <i class="fa-solid fa-circle-notch fa-spin mr-1.5"></i>{t('chat.processing')}
                            {/if}
                        </div>
                    </div>
                </div>
            {/if}
        {/if}
    </div>

    <!-- Error banner -->
    {#if error}
        <div class="mx-4 mb-2 px-3 py-2 rounded-md bg-error-950 border border-error-500/30 text-error-400 text-xs">
            <i class="fa-solid fa-triangle-exclamation mr-1"></i>{error}
        </div>
    {/if}

    <!-- Input bar -->
    <div class="border-t border-border bg-surface px-4 py-3">
        <div class="flex gap-2 items-end">
            <textarea
                bind:value={input}
                onkeydown={handleKey}
                placeholder="Type a message..."
                disabled={sending}
                rows="1"
                class="form__textarea flex-1 font-sans disabled:opacity-50 disabled:cursor-not-allowed"
            ></textarea>
            <button
                onclick={send}
                disabled={sending || !input.trim()}
                class="btn btn--primary btn--md shrink-0"
                aria-label="Send"
            >
                {#if sending}
                    <i class="fa-solid fa-circle-notch fa-spin" aria-hidden="true"></i>
                {:else}
                    <i class="fa-solid fa-paper-plane" aria-hidden="true"></i>
                {/if}
                <span class="sr-only">Send</span>
            </button>
        </div>
    </div>
</div>
