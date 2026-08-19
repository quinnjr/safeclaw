# SafeClaw

Sandboxed autonomous AI agent with tool execution, knowledge graph, skill system, and multi-interface control.

## Architecture

SafeClaw is an autonomous agent system with a pluggable LLM backend. It can use Claude Code CLI, OpenAI Codex CLI, Google Gemini CLI, Aider, OpenRouter (any model via API), or a local GGUF model (via llama-gguf) for reasoning. The operator controls the agent via a Svelte web dashboard (with JWT authentication) or Telegram bot.

```
Telegram Bot ──┐
               ├──▶ Agent ──▶ LLM Engine ──▶ Tool execution
Web Dashboard ─┘       │       ├─ Claude CLI   (Anthropic)
(Svelte + JWT)         │       ├─ Codex CLI    (OpenAI)
                       │       ├─ Gemini CLI   (Google)
                       │       ├─ Aider        (multi-provider)
                       │       ├─ OpenRouter   (API, any model)
                       │       └─ llama-gguf   (local GGUF, optional)
                       │                                │
                       ▼                         Approval Queue
                  Memory Manager                       │
                  ├─ Core                        Tool Executor
                  ├─ Conversation                      │
                  ├─ Archival (FTS5)             Tool Registry
                  └─ Knowledge Graph             ├─ exec
                                                 ├─ read_file / write_file / edit_file
                  Skill Manager                  ├─ web_search / web_fetch
                  ├─ Discovery (skill.toml)      ├─ browser (CDP)
                  ├─ Process groups              ├─ message
                  ├─ Credential injection        ├─ sessions_*
                  ├─ Extension engine (Rhai)     ├─ cron
                  └─ Auto-reconciliation         ├─ memory_search / memory_get
                                                 ├─ knowledge_graph
                  OAuth Manager                  └─ image
                  ├─ 10 providers
                  ├─ Multi-account
                  └─ Token refresh
```

## Key Concepts

### Tool Trait

All tools implement a common trait:

```rust
#[async_trait]
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn parameters_schema(&self) -> serde_json::Value;
    async fn execute(&self, params: serde_json::Value, ctx: &ToolContext) -> Result<ToolOutput>;
}
```

### ToolCall

The LLM proposes generic tool calls:

```rust
pub struct ToolCall {
    pub tool: String,        // "exec", "web_search", etc.
    pub params: serde_json::Value,
    pub reasoning: String,
}
```

These flow through the approval queue — the dashboard and Telegram bot show the tool name, params, and reasoning for the operator to approve/reject.

### Security Layers

- **SandboxedFs**: All file I/O confined to the data directory. Path traversal prevented.
- **Approval Queue**: All tool calls require human approval before execution.
- **exec tool**: Shell commands gated by approval; optional allowlist in config.
- **AllowlistedHttpClient**: Available for restricted HTTP access patterns.
- **Dashboard JWT Auth**: `DASHBOARD_PASSWORD` and `JWT_SECRET` are **required** — the server will not start without them. Login issues HS256-signed HttpOnly cookies with 7-day expiry.
- **Telegram auth**: Only configured chat IDs can control the bot.
- **OAuth**: Multi-provider OAuth 2.0 with per-provider client credentials. OAuth start/callback paths are exempt from JWT auth; all other OAuth API routes require authentication. Tokens stored in SQLite `oauth_tokens` table with `PRIMARY KEY (provider, account)`.
- **ACME TLS**: Automatic Let's Encrypt HTTPS via `rustls-acme` (TLS-ALPN-01). When enabled, the process **aborts** if the certificate cannot be obtained within 120 seconds, ensuring the container restarts cleanly rather than running without TLS.
- **Ngrok tunnel**: Optional public exposure via ngrok. Spawned as a managed subprocess; public URL broadcast to skills via `TUNNEL_URL` / `PUBLIC_URL` environment variables and available at `/api/tunnel/status`.

### Knowledge Graph

SQLite-based autonomous knowledge graph the agent grows as it learns. Supports:
- Typed nodes with labels, content, and confidence scores
- Typed edges with relations and weights
- Full-text search (FTS5) over nodes
- Recursive traversal via SQL CTEs
- Exposed to the LLM as the `knowledge_graph` tool

### Memory System

- **Core Memory**: Single-row personality that persists across restarts
- **Conversation Memory**: Rolling window of recent messages
- **Archival Memory**: Long-term storage with FTS5 search
- **Knowledge Graph**: Structured graph of facts and relationships

### Skill System

Skills are self-contained programs (typically Python) that the agent can create and manage on the fly. Each skill lives in its own directory under `$DATA_DIR/skills/<name>/` and includes a `skill.toml` manifest.

**Lifecycle:**
- Skills are discovered by scanning the skills directory for `skill.toml` files
- Daemon skills are started automatically and restarted if they crash
- Oneshot skills run once and exit
- Each skill runs in its own **Unix process group** for clean shutdown
- Reconciliation runs on every agent tick and after every message — deleted skill directories are detected immediately and their processes killed (SIGTERM → 2s grace → SIGKILL on the entire process group)

**Manifest (`skill.toml`):**
```toml
name = "my-skill"
description = "What this skill does"
skill_type = "daemon"   # or "oneshot"
enabled = true
entrypoint = "main.py"

[env]
CUSTOM_VAR = "value"

[ui]
panel = "panel.html"       # HTML panel in skill card (iframe)
page = "page.html"         # Full-page HTML at /skills/{name}/page
style = "style.css"        # Custom CSS (injected)
script = "script.js"       # Custom JS (injected)
widget = "status"           # Widget type for skill card header

[[credentials]]
name = "API_KEY"
label = "API Key"
description = "Third-party API key"
required = true
```

**Credentials:**
- Declared in `skill.toml` under `[[credentials]]`
- Configured via the dashboard UI or REST API
- Stored in `$SKILLS_DIR/credentials.json`
- Injected as environment variables when the skill process starts

**Environment variables passed to skills:**
- `SKILL_NAME`, `SKILL_DIR`, `SKILL_DATA_DIR`, `SKILLS_DIR`
- `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (if configured)
- `TUNNEL_URL`, `PUBLIC_URL` (if ngrok tunnel is active)
- Any extra `[env]` vars from the manifest
- All stored credentials for that skill

### Skill Extension System (Rhai)

Skills can extend the dashboard by registering custom API endpoints via Rhai scripts and providing custom HTML/JS/CSS for the web UI. This is similar to the Mattermost plugin architecture where plugins add server-side binaries and client-side React components.

**How it works:**
1. The extension manager scans each skill directory on startup
2. If a `routes.rhai` file exists, it is compiled and evaluated to collect route registrations
3. If a `[ui]` section exists in `skill.toml`, the UI files are served statically
4. Routes are dispatched dynamically when requests hit `/api/skills/{name}/ext/{path}`

**Creating a skill extension:**

Add a `routes.rhai` file to the skill directory:

```rhai
// Register routes by pushing to __routes
__routes.push(register_route("GET", "/status", "handle_status"));
__routes.push(register_route("POST", "/action", "handle_action"));

// Handler functions receive a request object
fn handle_status(req) {
    let rows = db_query("SELECT * FROM oauth_tokens WHERE provider = 'google'");
    json_response(#{
        count: rows.len(),
        data: rows,
        checked_at: now_utc()
    })
}

fn handle_action(req) {
    let body = json_parse(req.body);
    let account = req.query.account;
    db_execute("INSERT INTO my_table (key, value) VALUES (?, ?)", [body.key, body.value]);
    json_response(#{ ok: true })
}
```

Add a `ui/panel.html` for a custom dashboard panel and reference it in `skill.toml`:

```toml
[ui]
panel = "panel.html"
```

The panel HTML can call the skill's extension routes using `fetch("/api/skills/{name}/ext/status")` with `credentials: "same-origin"` to inherit the dashboard auth cookie.

**Rhai API reference:**

| Category | Function | Description |
|---|---|---|
| Routes | `register_route(method, path, handler_fn)` | Register a route (push result to `__routes`) |
| Response | `json_response(data)` | 200 JSON response |
| Response | `json_response(status, data)` | JSON response with status code |
| Response | `html_response(html)` | 200 HTML response |
| Response | `text_response(text)` | 200 plain text response |
| Response | `error_response(status, message)` | JSON error response |
| HTTP | `http_get(url)` | HTTP GET, returns parsed JSON or string |
| HTTP | `http_post(url, body)` | HTTP POST with string or map body |
| Files | `data_read(path)` | Read file contents |
| Files | `data_write(path, content)` | Write file (creates parent dirs) |
| Files | `data_list(dir)` | List directory entries |
| Files | `data_exists(path)` | Check if path exists |
| JSON | `json_parse(text)` | Parse JSON string to Rhai value |
| JSON | `json_stringify(val)` | Serialize to JSON string |
| JSON | `json_stringify_pretty(val)` | Serialize to pretty JSON |
| Database | `db_query(sql)` | SQL query, returns array of maps |
| Database | `db_query(sql, params)` | Parameterized SQL query |
| Database | `db_execute(sql)` | SQL execute, returns rows affected |
| Database | `db_execute(sql, params)` | Parameterized SQL execute |
| Env | `env_get(key)` | Read environment variable |
| Time | `now_utc()` | Current UTC time as ISO 8601 string |
| Time | `now_epoch()` | Current Unix timestamp |

**Scope variables available in handlers:**
- `__skill_name` — the skill's name
- `__skill_dir` — absolute path to the skill directory
- `__data_dir` — absolute path to the skill's `data/` directory

**Request object passed to handlers:**
- `req.method` — HTTP method
- `req.path` — matched path
- `req.body` — request body as string
- `req.query` — map of query parameters
- `req.headers` — map of request headers

**Extension routes:**
- `GET /api/skills/extensions` — list all skill extensions
- `ANY /api/skills/{name}/ext/{path}` — dispatch to Rhai handler
- `GET /skills/{name}/ui/{path}` — serve static files from skill `ui/` directory
- `GET /skills/{name}/page` — serve the skill's full-page UI

### OAuth System

Built-in multi-provider OAuth 2.0 with multi-account support. The dashboard provides a unified interface for connecting, refreshing, and disconnecting OAuth accounts across 10 providers.

**Supported providers:**

| Provider | ID | Scopes (default) |
|---|---|---|
| Google | `google` | Calendar, Gmail (read), Drive (read), userinfo |
| Microsoft | `microsoft` | User.Read, Mail.Read, Calendars.Read, offline_access |
| GitHub | `github` | user:email, read:user, repo |
| Slack | `slack` | users:read, channels:read, chat:write |
| Discord | `discord` | identify, email, guilds |
| Spotify | `spotify` | user-read-email, user-read-private, user-library-read |
| Dropbox | `dropbox` | account_info.read, files.metadata.read |
| Twitter/X | `twitter` | users.read, tweet.read, offline.access (PKCE) |
| LinkedIn | `linkedin` | openid, profile, email |
| Notion | `notion` | (default Notion scopes, Basic Auth token exchange) |

**Configuration:** Set `{PROVIDER}_CLIENT_ID` and `{PROVIDER}_CLIENT_SECRET` environment variables (e.g. `GOOGLE_CLIENT_ID`, `GITHUB_CLIENT_SECRET`). Credentials can also come from the skill credential store (looked up as `{provider}-oauth` skill credentials).

**OAuth callback URL:** `{TUNNEL_URL}/oauth/{provider}/callback` — requires ngrok or a public URL.

**Token storage:** OAuth tokens are stored in the `oauth_tokens` SQLite table with `PRIMARY KEY (provider, account)`. Each account stores `access_token`, `refresh_token`, `expires_at`, `scopes`, `email`, and timestamps.

**Google credential files:** For Google accounts, the OAuth module writes JSON credential files to `$SKILLS_DIR/google-oauth/data/accounts/{email}.json` for consumption by skills like `calendar-reminder`.

## Tech Stack

- **Language**: Rust (2024 edition)
- **LLM**: Pluggable backend — Claude Code CLI, OpenAI Codex CLI, Google Gemini CLI, Aider (multi-provider), OpenRouter (API), or llama-gguf (local GGUF, optional `local` feature)
- **Database**: SQLite via `rusqlite` (WAL mode, FTS5, recursive CTEs)
- **Web**: `axum` + Svelte 5 dashboard (compiled by Vite, embedded in binary)
- **Scripting**: `rhai` for skill extension endpoints (sandboxed, sync)
- **Auth**: `jsonwebtoken` (HS256 JWT cookies)
- **HTTP**: `reqwest` for outbound requests (async + blocking for Rhai)
- **Telegram**: `teloxide` for bot interface
- **OAuth**: Built-in multi-provider OAuth 2.0 (10 providers, multi-account)
- **Browser**: `chromiumoxide` for CDP automation (scaffold)
- **Scheduling**: `tokio-cron-scheduler` for cron jobs
- **HTML to Markdown**: `htmd` for web_fetch
- **Process management**: `libc` for Unix process group signals
- **TLS**: `rustls-acme` + `axum-server` for automatic Let's Encrypt certificates
- **Tunnel**: ngrok for exposing the dashboard and OAuth callbacks publicly

## Module Layout

```
src/
├── main.rs              # Entry point, CLI, tool registry setup
├── config.rs            # Configuration (TOML)
├── error.rs             # Error types
├── db.rs                # SQLite schema migrations
├── security.rs          # SandboxedFs, AllowlistedHttpClient
├── agent/
│   ├── mod.rs           # Agent struct, run loop, skill reconciliation
│   ├── tick.rs          # Tick cycle: observe → think → propose
│   ├── actions.rs       # ToolCall parsing and execution
│   └── reasoning.rs     # LLM context assembly
├── llm/
│   ├── mod.rs           # LlmEngine enum (dispatches to active backend)
│   ├── claude.rs        # Claude Code CLI backend
│   ├── codex.rs         # OpenAI Codex CLI backend
│   ├── gemini.rs        # Google Gemini CLI backend
│   ├── aider.rs         # Aider multi-provider backend
│   ├── openrouter.rs    # OpenRouter API backend (any model via HTTP)
│   ├── local.rs         # Local GGUF backend via llama-gguf (feature = "local")
│   └── prompts.rs       # System prompt, JSON schema, user message builder
├── memory/
│   ├── mod.rs           # MemoryManager, stats, activity log
│   ├── core.rs          # CoreMemory (personality)
│   ├── conversation.rs  # ConversationMemory (rolling window)
│   ├── archival.rs      # ArchivalMemory (FTS5)
│   └── knowledge.rs     # KnowledgeGraph (nodes, edges, traversal)
├── acme.rs              # Let's Encrypt ACME certificate provisioning (TLS-ALPN-01)
├── tunnel.rs            # Ngrok tunnel manager (spawn, poll API, broadcast URL)
├── skills/
│   ├── mod.rs           # Re-exports
│   ├── manager.rs       # SkillManager: discovery, start, stop, credentials, reconciliation
│   └── extensions.rs    # Rhai extension engine: route registration, UI config, API surface
├── tools/
│   ├── mod.rs           # Tool trait, ToolRegistry, ToolCall, ToolOutput
│   ├── exec.rs          # Shell command execution
│   ├── process.rs       # Background process management
│   ├── file.rs          # Read, write, edit, apply_patch (sandboxed)
│   ├── web.rs           # DuckDuckGo search, URL fetch
│   ├── browser.rs       # Headless browser (CDP scaffold)
│   ├── message.rs       # Messaging platforms (scaffold)
│   ├── sessions.rs      # Multi-agent session coordination
│   ├── cron.rs          # Scheduled task management
│   ├── image.rs         # Image analysis (scaffold)
│   ├── memory.rs        # Archival memory search/get
│   └── knowledge.rs     # Knowledge graph tool
├── telegram/
│   ├── mod.rs           # Bot setup and dispatcher
│   ├── commands.rs      # Command handlers
│   └── notifications.rs # Push notifications to operator
├── approval/
│   ├── mod.rs           # ApprovalQueue
│   └── types.rs         # PendingAction, ApprovalStatus
└── dashboard/
    ├── mod.rs           # HTTP server setup
    ├── routes.rs        # Route definitions, DashState, ExtensionManager init
    ├── auth.rs          # JWT middleware, login/logout/check endpoints
    ├── handlers.rs      # API endpoint handlers
    ├── oauth.rs         # Multi-provider OAuth 2.0 (10 providers, multi-account)
    ├── skill_ext.rs     # Skill extension route dispatcher and static file server
    ├── sse.rs           # Server-sent events
    ├── ui/              # Build output (embedded in binary via include_str!)
    │   ├── index.html   # Dashboard HTML (Tailwind CSS 4 + Font Awesome CDN)
    │   ├── style.css    # Compiled CSS (from Vite)
    │   └── app.js       # Compiled JS (from Vite)
    └── frontend/        # Svelte 5 source (compiled by Vite → ui/)
        ├── index.html
        ├── vite.config.ts
        ├── svelte.config.js
        ├── vite-env.d.ts
        └── src/
            ├── main.ts          # Svelte mount point
            ├── app.css          # Custom CSS (scrollbars, badges, tabs)
            ├── App.svelte       # Root component (auth gate, tabs, layout)
            ├── lib/
            │   ├── types.ts     # TypeScript interfaces for API data
            │   ├── api.ts       # HTTP helper with 401 → auth redirect
            │   └── state.svelte.ts  # Shared reactive state ($state runes)
            └── components/
                ├── LoginOverlay.svelte   # Full-screen login form
                ├── Header.svelte         # Status bar, controls, logout
                ├── ChatTab.svelte        # Chat interface with the agent
                ├── PendingActions.svelte  # Approval queue panel
                ├── ActivityLog.svelte     # Recent activity feed
                ├── MemoryPanel.svelte     # Core/conversation/archival tabs
                ├── StatsPanel.svelte      # Agent statistics
                ├── SkillsTab.svelte       # Skill list, OAuth accounts, extensions
                ├── SkillCard.svelte       # Individual skill card with extension tab
                ├── CredentialRow.svelte   # Credential input row
                ├── KnowledgeTab.svelte    # Knowledge graph explorer
                └── ToolsTab.svelte        # Registered tools list
```

## Feature Flags

| Flag         | Effect                                                        |
|--------------|---------------------------------------------------------------|
| *(default)*  | Claude Code CLI backend only — no extra native deps           |
| `local`      | Adds llama-gguf (CPU) for local GGUF model inference          |
| `local-cuda` | Same as `local` plus NVIDIA CUDA GPU acceleration             |

## Building & Running

```bash
# Install frontend dependencies
pnpm install

# Build the Svelte dashboard (outputs to src/dashboard/ui/)
pnpm run build:ui

# Build the Rust binary (Claude-only, default)
cargo build --release

# Build with local GGUF inference support
cargo build --release --features local

# Build with local GGUF + CUDA GPU support
cargo build --release --features local-cuda

# Run with Claude backend (requires DASHBOARD_PASSWORD and JWT_SECRET)
DASHBOARD_PASSWORD=mypass JWT_SECRET=mysecret ./target/release/SafeClaw

# Run with OpenRouter (any model via API)
LLM_BACKEND=openrouter OPENROUTER_API_KEY=sk-or-... \
  DASHBOARD_PASSWORD=mypass JWT_SECRET=mysecret \
  ./target/release/SafeClaw

# Run with OpenAI Codex backend
LLM_BACKEND=codex \
  DASHBOARD_PASSWORD=mypass JWT_SECRET=mysecret \
  ./target/release/SafeClaw

# Run with Google Gemini CLI backend
LLM_BACKEND=gemini \
  DASHBOARD_PASSWORD=mypass JWT_SECRET=mysecret \
  ./target/release/SafeClaw

# Run with Aider (uses any provider via API keys)
LLM_BACKEND=aider AIDER_MODEL=gpt-4o \
  OPENAI_API_KEY=sk-... \
  DASHBOARD_PASSWORD=mypass JWT_SECRET=mysecret \
  ./target/release/SafeClaw

# Run with a local GGUF model
LLM_BACKEND=local MODEL_PATH=/path/to/model.gguf \
  DASHBOARD_PASSWORD=mypass JWT_SECRET=mysecret \
  ./target/release/SafeClaw

# Run with custom config
./target/release/SafeClaw --config /path/to/config.toml

# Pre-flight check
./target/release/SafeClaw --check
```

### Docker

```bash
# Copy and fill in environment variables
cp .env.example .env

# Build and run
docker compose up -d --build

# View logs
docker compose logs -f SafeClaw
```

## Configuration

Config file: `~/.config/SafeClaw/config.toml`

See `config.example.toml` for all options with defaults.

### Environment Variables

| Variable               | Required | Description                                           |
|------------------------|----------|-------------------------------------------------------|
| `DASHBOARD_PASSWORD`   | **Yes**  | Password for the web dashboard (server won't start without it) |
| `JWT_SECRET`           | **Yes**  | Secret key for signing JWT cookies (server won't start without it) |
| `LLM_BACKEND`         | No       | `claude` (default), `codex`, `gemini`, `aider`, `openrouter`, or `local` |
| `CLAUDE_BIN`           | No       | Path to the `claude` binary (default: `claude`)       |
| `CLAUDE_CONFIG_DIR`    | No       | Claude Code config directory for profile selection    |
| `CLAUDE_MODEL`         | No       | Model override: `sonnet`, `opus`, `haiku`             |
| `CODEX_BIN`            | No       | Path to the `codex` binary (default: `codex`)         |
| `CODEX_MODEL`          | No       | Model override: `gpt-5-codex`, `o3`, etc.             |
| `CODEX_PROFILE`        | No       | Codex config profile from `~/.codex/config.toml`      |
| `CODEX_API_KEY`        | No       | OpenAI API key (codex backend; uses saved auth if unset) |
| `GEMINI_BIN`           | No       | Path to the `gemini` binary (default: `gemini`)       |
| `GEMINI_MODEL`         | No       | Model override: `gemini-2.5-pro`, `gemini-2.5-flash`  |
| `GEMINI_API_KEY`       | No       | Google AI Studio API key (gemini backend; uses saved auth if unset) |
| `AIDER_BIN`            | No       | Path to the `aider` binary (default: `aider`)         |
| `AIDER_MODEL`          | No       | Model string: `gpt-4o`, `claude-3.5-sonnet`, etc.     |
| `OPENROUTER_API_KEY`   | If `openrouter` backend | OpenRouter API key                     |
| `OPENROUTER_MODEL`     | No       | Model ID (default: `anthropic/claude-sonnet-4`)       |
| `MODEL_PATH`           | If `local` backend | Path to a `.gguf` model file              |
| `TELEGRAM_BOT_TOKEN`   | If telegram enabled | Telegram Bot API token from @BotFather     |
| `ACME_ENABLED`         | No       | Set to `true` to enable Let's Encrypt HTTPS               |
| `ACME_DOMAIN`          | If ACME enabled | Comma-separated domain(s) for the certificate    |
| `ACME_EMAIL`           | If ACME enabled | Contact email for Let's Encrypt                  |
| `ACME_PRODUCTION`      | No       | `true` for production CA, `false` for staging (default)   |
| `ACME_PORT`            | No       | HTTPS listen port (default: `443`)                        |
| `NGROK_AUTHTOKEN`      | No (auto-enables tunnel) | ngrok auth token; setting this enables the tunnel |
| `NGROK_BIN`            | No       | Path to ngrok binary (default: `ngrok`)               |
| `NGROK_PORT`           | No       | Local port to expose (default: dashboard port)        |
| `NGROK_DOMAIN`         | No       | Static ngrok domain (e.g. `myapp.ngrok-free.app`)     |
| `RUST_LOG`             | No       | Tracing filter (default: `info`)                      |

### OAuth Provider Credentials

Each OAuth provider requires a client ID and secret, set via environment variables or the skill credential store.

| Provider | Client ID env | Client Secret env |
|---|---|---|
| Google | `GOOGLE_CLIENT_ID` | `GOOGLE_CLIENT_SECRET` |
| Microsoft | `MICROSOFT_CLIENT_ID` | `MICROSOFT_CLIENT_SECRET` |
| GitHub | `GITHUB_CLIENT_ID` | `GITHUB_CLIENT_SECRET` |
| Slack | `SLACK_CLIENT_ID` | `SLACK_CLIENT_SECRET` |
| Discord | `DISCORD_CLIENT_ID` | `DISCORD_CLIENT_SECRET` |
| Spotify | `SPOTIFY_CLIENT_ID` | `SPOTIFY_CLIENT_SECRET` |
| Dropbox | `DROPBOX_CLIENT_ID` | `DROPBOX_CLIENT_SECRET` |
| Twitter/X | `TWITTER_CLIENT_ID` | `TWITTER_CLIENT_SECRET` |
| LinkedIn | `LINKEDIN_CLIENT_ID` | `LINKEDIN_CLIENT_SECRET` |
| Notion | `NOTION_CLIENT_ID` | `NOTION_CLIENT_SECRET` |

### CLAUDE.md (LLM Backend Project Rules)

All CLI-based LLM backends (Claude, Codex, Gemini, Aider) run with `current_dir` set to the data directory (`$XDG_DATA_HOME/SafeClaw/`). This means the CLI picks up the `CLAUDE.md` file located there as project-level instructions.

**System-managed rules** are maintained automatically at startup from an embedded template (`config/CLAUDE.md` in the repo). The file uses marker comments to separate system rules from user-added rules:

```
<!-- SAFE-AGENT SYSTEM RULES - DO NOT EDIT BELOW THIS LINE -->
... system rules (overwritten on every startup) ...
<!-- END SAFE-AGENT SYSTEM RULES -->

... user rules (preserved across restarts) ...
```

**Adding a new system rule:** Edit `config/CLAUDE.md` in the repo. The content is embedded in the binary at compile time via `include_str!` and written to `$DATA_DIR/CLAUDE.md` on every startup, replacing the system section while preserving anything the operator appended after the end marker.

**Adding a user/operator rule at runtime:** Append text after the `<!-- END SAFE-AGENT SYSTEM RULES -->` line in `$DATA_DIR/CLAUDE.md`. It will be preserved across agent restarts and binary upgrades.

**Default system rules:**
- **Trash policy:** Never use `rm`/`rmdir`/`unlink` for deletions; use the trash system at `$DATA_DIR/trash/` instead.

## Data Storage

All data is stored under `$XDG_DATA_HOME/SafeClaw/` (typically `~/.local/share/SafeClaw/`):
- `SafeClaw.db` — SQLite database (conversation, memory, knowledge graph, approvals, stats, OAuth tokens)
- `CLAUDE.md` — System + user rules for CLI LLM backends (managed at startup, see above)
- `skills/` — Skill directories (each with `skill.toml`, entrypoint, `skill.log`, `data/`, optional `routes.rhai`, optional `ui/`)
- `skills/credentials.json` — Stored skill credentials

## Git Workflow

This project uses **git-flow** branching.

### Branches

- `main` — production-only. Never commit directly to `main`. It receives merges from `develop` when cutting a release.
- `develop` — integration branch. All day-to-day work lands here.
- `feature/<name>` — branched from `develop`, merged back into `develop` via PR.
- `release/<version>` — branched from `develop` when preparing a release. Final fixes go here, then it merges into both `main` (tagged) and `develop`.
- `hotfix/<name>` — branched from `main` for critical production fixes. Merges into both `main` (tagged) and `develop`.

### Commit Messages

Write commit messages as if Linus Torvalds is reviewing them.

- **Subject line**: imperative mood, under 72 characters, no trailing period. Describe *what* the commit does, not what you did. Prefix with a type tag: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `build:`, `chore:`.
- **Body** (when needed): separated by a blank line. Explain *why* the change was made, not *how* — the diff shows how. Wrap at 72 characters. Reference issues or prior commits when relevant.
- Do not write meaningless messages like "fix stuff", "update", or "WIP". Every commit in the history should be a self-contained, reviewable unit of work.
- Never use `--no-verify` to skip pre-commit or pre-push hooks. Fix the underlying issue instead.

```
feat: add web chat interface to dashboard

The agent was only reachable via Telegram. Add POST /api/chat
endpoint that calls the same handle_message() path and a ChatTab
Svelte component so the operator can message the agent directly
from the dashboard.
```

### Release Flow

1. Branch `release/vX.Y.Z` from `develop`.
2. Bump version numbers, update changelogs, fix release-blocking issues on the release branch.
3. Merge the release branch into `main` with `--no-ff`. Tag the merge commit `vX.Y.Z`.
4. Merge the release branch back into `develop` to pick up any last-minute fixes.
5. Delete the release branch.

```bash
git checkout develop
git checkout -b release/v0.2.0
# ... version bumps, final fixes ...
git checkout main
git merge --no-ff release/v0.2.0
git tag v0.2.0
git push origin main --tags
git checkout develop
git merge --no-ff release/v0.2.0
git push origin develop
git branch -d release/v0.2.0
```

## Development Guidelines

- All file operations go through `SandboxedFs` — no raw `std::fs` outside the sandbox
- New tools implement the `Tool` trait and register in `build_tool_registry()` in `main.rs`
- Tool calls always flow through the approval queue unless the agent auto-approves
- Keep tool implementations stateless where possible; shared state lives in `ToolContext`
- Secrets (API keys, tokens) come from environment variables, never config files
- The dashboard serves embedded static files (compiled into the binary via `include_str!`)
- Frontend changes require rebuilding: `pnpm run build:ui` then `cargo build`
- Skills run in their own Unix process groups — `stop_skill()` sends SIGTERM/SIGKILL to the group
- Skill reconciliation runs every tick and after every message — no conditional keyword matching
- `DASHBOARD_PASSWORD` and `JWT_SECRET` are mandatory — the server errors out on startup if either is missing
- Skill extensions (Rhai routes) are discovered at startup — restart the agent to pick up new `routes.rhai` files
- Rhai handlers run synchronously and use blocking HTTP/DB calls; keep handlers fast
- OAuth tokens are stored in SQLite with compound key `(provider, account)` for multi-account support

### Dashboard Development

The dashboard frontend is a Svelte 5 app in `src/dashboard/frontend/`:

```bash
# Dev server (hot reload, proxied to Rust backend)
pnpm run dev:ui

# Production build (outputs to src/dashboard/ui/)
pnpm run build:ui
```

Styling uses Tailwind CSS 4 (via browser CDN) with the Tailswatch Oxide theme and Font Awesome icons (also via CDN). The `index.html` in `ui/` includes the CDN `<script>` and `<link>` tags; Vite only bundles the Svelte JS and custom CSS.

### Adding a New Skill

Skills are created by the agent itself (via Claude) in response to user requests, but can also be created manually:

1. Create `$DATA_DIR/skills/<name>/` directory
2. Add `skill.toml` manifest (see Skill System section above)
3. Add entrypoint script (e.g., `main.py`)
4. Optionally add `requirements.txt` for Python dependencies
5. Optionally add `routes.rhai` for custom API endpoints
6. Optionally add `ui/` directory with HTML/JS/CSS for dashboard panels
7. The skill will be discovered and started on the next reconciliation cycle

### Adding a Skill Extension

1. Create `routes.rhai` in the skill directory with route registrations
2. Create `ui/` directory with HTML/JS/CSS files
3. Add `[ui]` section to `skill.toml` referencing the panel/page files
4. Restart the agent (extensions are discovered at startup)
5. The skill card in the dashboard will show an "ext" badge and an "Extension" tab

### Dashboard Authentication

Authentication is **mandatory** — the server refuses to start without `DASHBOARD_PASSWORD` and `JWT_SECRET`.

- `POST /api/auth/login` — Validates password, returns HS256-signed JWT in an `HttpOnly; SameSite=Strict` cookie (7-day expiry)
- `POST /api/auth/logout` — Clears the cookie
- `GET /api/auth/check` — Reports whether the current request has a valid JWT
- Middleware enforces auth on all API routes; static assets (`/`, `/style.css`, `/app.js`), auth endpoints, OAuth start/callback, and skill static files are exempt
- The Svelte app checks auth on mount and shows a login overlay when unauthenticated
- Any 401 response from `api.ts` resets auth state and shows the login screen

## License

Copyright (c) 2026 Joseph R. Quinn
Contact: quinn.josephr@protonmail.com
