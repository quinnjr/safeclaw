# Robinhood agentic trading module — design

Date: 2026-07-01
Status: approved (pending user sign-off on this doc)

## Purpose

Add a paper-trading module to safeclaw that connects to Robinhood's agentic
API, lets the existing agent loop watch a self-managed list of symbols,
reason about them on a schedule, and log simulated ("paper") trade decisions
with rationale — without ever placing a real order. Real order execution is
explicitly out of scope for this iteration.

## Non-goals

- No real order placement. `paper_order` only ever writes a log row.
- No risk limits, position sizing, or kill switch — those matter once real
  execution is on the table, not before.
- No multi-broker abstraction. Robinhood only.
- No multiple/switchable named strategies — a single editable strategy text
  field, extendable later if actually needed.

## Architecture

Reuses safeclaw's existing infrastructure end to end: the tool trait, the
capability checker, the cron/goal scheduler, the shared sqlite connection,
and the dashboard's tab/SSE pattern. No new subsystem is introduced.

### 1. Tool — `src/tools/trading.rs`

`RobinhoodTool` implements the existing `Tool` trait (same shape as
`src/tools/email.rs`). Actions, dispatched via a single `action` param like
other tools:

| action             | effect                                                        |
|--------------------|----------------------------------------------------------------|
| `quote`             | real read-only call to Robinhood's agentic API for a symbol   |
| `positions`         | real read-only call — current holdings                        |
| `account`           | real read-only call — balance/buying power                    |
| `watchlist_add`     | insert symbol into local `watchlist` table                    |
| `watchlist_remove`  | delete symbol from `watchlist` table                           |
| `watchlist_list`    | read `watchlist` table                                         |
| `paper_order`       | **log-only**: writes a row to `paper_trades`; never calls any order-placing endpoint |

Auth token read once at startup from `ROBINHOOD_AGENT_TOKEN` env var, same
pattern as other credentialed tools.

The paper-only boundary is structural: there is no code path in this tool
that calls a real order-placement endpoint. It cannot be misconfigured open.

### 2. Capability gate — `src/security/capabilities.rs`

`"trading"` registered in `tool_capabilities` the same way other tools are,
so the read actions and watchlist actions can be scoped/allowed per the
existing capability config. No new enforcement mechanism.

### 3. Persistence

Two new tables in the existing sqlite DB (same `Connection` already shared
across the app — no new database file):

```sql
CREATE TABLE watchlist (
    symbol TEXT PRIMARY KEY,
    added_at TEXT NOT NULL
);

CREATE TABLE paper_trades (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    symbol TEXT NOT NULL,
    side TEXT NOT NULL,        -- 'buy' | 'sell'
    qty REAL NOT NULL,
    price REAL NOT NULL,       -- price at decision time
    rationale TEXT NOT NULL,
    decided_at TEXT NOT NULL
);
```

Simulated P&L is computed on read (mark paper positions against the latest
quote) — no separate ledger table.

### 4. Scheduling — existing cron/goal system

A goal registered through the existing cron runner (`agent/cron_runner.rs`),
same mechanism other scheduled goals already use. It fires every
`interval_minutes` (config, default e.g. 5), gated by a pure
`is_market_hours()` check (9:30–16:00 ET, Mon–Fri, using `chrono-tz`, already
a dependency — no new crate).

Each tick's goal prompt has two parts:

1. **Fixed scaffold (not user-editable, defined in code):**
   "Check your current watchlist, pull quotes and positions for each symbol,
   decide buy/sell/hold for each, and log a paper decision via `paper_order`
   with a rationale. You may also add or remove symbols from the watchlist."
2. **User-editable strategy text (config, appended after the scaffold):**
   free-form portfolio-management guidance, e.g. "Favor momentum breakouts on
   high volume, avoid entries during earnings week, prefer holds under one
   day." Stored as plain text, no schema/parsing.

Splitting fixed scaffold from editable strategy means the loop's basic duties
(watchlist upkeep, decision logging, SSE emission) can't be broken by an edit
to the strategy text — only the reasoning guidance changes.

### 5. Config

One config record (new table or existing config store, whichever the
existing goal/skill config pattern uses):

```
interval_minutes: u32   (default 5)
enabled: bool            (default false — must be turned on explicitly)
strategy: String         (free text, default empty)
```

### 6. Frontend — dashboard

New tab `src/dashboard/frontend/src/components/TradingTab.svelte`, added to
`App.svelte`'s nav alongside Goals/Skills/Operations, following the same
tab/component pattern already used there.

Sections:

- **Watchlist** — table of symbols with last quote, manual add/remove
  (overrides what the agent has picked)
- **Decision log** — recent `paper_trades` rows: symbol, side, qty, price,
  rationale, timestamp
- **Simulated P&L** — running total, mark-to-market against latest quotes,
  computed client- or server-side from `paper_trades`
- **Config panel** — `interval_minutes`, `enabled` toggle, `strategy` text
  editor
- **Status strip** — active/inactive, last tick time, next scheduled tick
- **Charts** — price chart per watched symbol (line, with paper buy/sell
  markers plotted at decision points) and a cumulative simulated P&L line
  over time. Built with `lightweight-charts` (TradingView's open-source
  charting library) — chosen over a generic library like Chart.js because
  it's purpose-built for financial time series (price/volume series, marker
  overlays) at a fraction of the bundle size, and it's the same library
  Robinhood-style trading UIs already use. Added as the one new frontend
  dependency in `src/dashboard/frontend/package.json`; no backend changes
  needed beyond the `/api/trading/trades` and `/api/trading/status` data it
  already renders from.

New axum routes (`routes.rs` + `handlers.rs`), mirroring the existing
goals/skills route style:

```
GET    /api/trading/watchlist
POST   /api/trading/watchlist        { symbol }
DELETE /api/trading/watchlist/{symbol}
GET    /api/trading/trades           (paginated)
GET    /api/trading/status           (active?, last_tick, next_tick, pnl_summary)
PUT    /api/trading/config           { interval_minutes, enabled, strategy }
```

All of these read/write the tables and config above — no new state model.

Live updates: trading decisions emit events on the existing SSE stream
(`dashboard/sse.rs`, `/api/events`) that other tabs already consume, rather
than a new channel.

## Error handling

- Robinhood API errors (auth failure, rate limit, symbol not found) are
  returned as tool errors through the existing `Tool`/`ToolOutput` error
  path — same handling every other tool already gets, no special casing.
- A failed tick (API error, LLM error) is logged and skipped; the cron
  schedule continues to the next interval rather than retrying or halting
  the loop.

## Testing

- Unit test for `is_market_hours()` covering weekday/weekend and open/close
  boundaries in ET.
- Unit test confirming `paper_order` never calls any network endpoint (pure
  DB write) — the structural safety guarantee for this iteration.
- Existing dashboard component test pattern (see
  `frontend/src/lib/__tests__`) extended with a smoke test for `TradingTab`
  rendering watchlist/decision-log data from mocked API responses.

## Future (explicitly deferred, not part of this spec)

- Real order execution behind an explicit opt-in flag, with position-size
  and daily-loss limits, plus a kill switch.
- Multiple named/switchable strategies.
- Agent-initiated symbol discovery beyond manual/agent watchlist edits (e.g.
  a screener tool).
