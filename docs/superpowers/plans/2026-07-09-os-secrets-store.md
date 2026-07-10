# OS Secrets Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move safeclaw's ~18 credential-shaped env var reads (bot tokens, API keys, passwords, JWT secret) onto the OS secrets store (Secret Service/Keychain/Credential Manager via the `keyring` crate), with no env-var fallback for those specific vars.

**Architecture:** A single new module `src/secrets.rs` exposes `secrets::var(name: &str) -> Result<String, std::env::VarError>` — same signature as `std::env::var`, so every existing call site's surrounding `.ok()` / `match` / `.unwrap_or_else` / `?` logic is untouched; only the function name changes at each of the ~18 sites. Non-secret env vars (bin paths, model names, URLs, ports, flags) are unaffected.

**Tech Stack:** Rust, `keyring` crate v3 (per-OS backend selected via Cargo `[target...]` sections, matching the existing `cfg(unix)` / `cfg(target_os = "linux")` pattern in `Cargo.toml`).

## Global Constraints

- `secrets::var` signature MUST be `fn var(name: &str) -> Result<String, std::env::VarError>` — exact match to `std::env::var` so call sites don't need restructuring.
- Keyring service name is always the literal string `"safeclaw"`; entry username is the env var name (e.g. `"DISCORD_BOT_TOKEN"`).
- No fallback to `std::env::var`/`.env` inside `secrets::var` for the moved vars — a missing/unreachable keyring entry maps to `Err(VarError::NotPresent)`, same as "unset" today.
- Exactly these 18 vars move to `secrets::var`; every other env var in the codebase keeps using `std::env::var` directly: `DASHBOARD_PASSWORD`, `JWT_SECRET`, `DISCORD_BOT_TOKEN`, `SLACK_BOT_TOKEN`, `MATRIX_ACCESS_TOKEN`, `MATRIX_PASSWORD`, `TELEGRAM_BOT_TOKEN`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `NGROK_AUTHTOKEN`, `CODEX_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `TTS_API_KEY`, `WHISPER_API_KEY`, `ROBINHOOD_MCP_TOKEN`.
- No new safeclaw CLI subcommand. Document `secret-tool` (Linux) / `security` (macOS) usage instead.

---

## Task 1: `secrets` module + `keyring` dependency

**Files:**
- Create: `src/secrets.rs`
- Modify: `src/main.rs` (add `mod secrets;` near the other `mod` declarations)
- Modify: `Cargo.toml` (add `keyring` per-OS)
- Test: inline `#[cfg(test)]` module in `src/secrets.rs`

**Interfaces:**
- Produces: `pub fn secrets::var(name: &str) -> Result<String, std::env::VarError>` — used by every later task.

- [ ] **Step 1: Add the `keyring` dependency**

Edit `Cargo.toml`. Find the existing per-target dependency sections:

```toml
# Unix process group management & sandboxing
[target.'cfg(unix)'.dependencies]
libc = "0.2"
rlimit = "0.10"

# Linux-only kernel sandboxing
[target.'cfg(target_os = "linux")'.dependencies]
landlock = "0.4"
seccompiler = "0.5"
```

Add three new sections after them (before `[dev-dependencies]`):

```toml
# OS secrets store (safeclaw::secrets) — per-OS keyring backend
[target.'cfg(target_os = "linux")'.dependencies]
keyring = { version = "3", features = ["sync-secret-service", "vendored"] }

[target.'cfg(target_os = "macos")'.dependencies]
keyring = { version = "3", features = ["apple-native"] }

[target.'cfg(target_os = "windows")'.dependencies]
keyring = { version = "3", features = ["windows-native"] }
```

Note: this means the existing `[target.'cfg(target_os = "linux")'.dependencies]` table now appears twice in the file (once for `landlock`/`seccompiler`, once for `keyring`) — Cargo merges duplicate target tables, this is valid. Do not merge them manually; keep the new block separate and clearly commented so it's easy to find.

- [ ] **Step 2: Write the module with a failing test**

Create `src/secrets.rs`:

```rust
//! OS secrets store access. Wraps the `keyring` crate behind an
//! `std::env::var`-shaped API so call sites don't need to change their
//! surrounding `.ok()` / `match` / `?` logic when switching from env vars.

const SERVICE: &str = "safeclaw";

/// Look up `name` in the OS secrets store (Secret Service on Linux,
/// Keychain on macOS, Credential Manager on Windows). Returns
/// `Err(VarError::NotPresent)` if the entry doesn't exist OR if the
/// backend itself is unreachable (e.g. no D-Bus session) — in the latter
/// case a warning is logged with the underlying error so operators can
/// diagnose it, but callers see the same "not present" shape they already
/// handle for env vars today.
pub fn var(name: &str) -> Result<String, std::env::VarError> {
    let entry = match keyring::Entry::new(SERVICE, name) {
        Ok(e) => e,
        Err(e) => {
            tracing::warn!("secrets: failed to build keyring entry for {name}: {e}");
            return Err(std::env::VarError::NotPresent);
        }
    };

    match entry.get_password() {
        Ok(v) => Ok(v),
        Err(keyring::Error::NoEntry) => Err(std::env::VarError::NotPresent),
        Err(e) => {
            tracing::warn!("secrets: keyring backend error reading {name}: {e}");
            Err(std::env::VarError::NotPresent)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use keyring::{mock, set_default_credential_builder};

    fn use_mock_backend() {
        set_default_credential_builder(mock::default_credential_builder());
    }

    #[test]
    fn returns_not_present_for_missing_entry() {
        use_mock_backend();
        let result = var("SAFECLAW_TEST_MISSING_VAR");
        assert_eq!(result, Err(std::env::VarError::NotPresent));
    }

    #[test]
    fn returns_value_for_existing_entry() {
        use_mock_backend();
        let entry = keyring::Entry::new(SERVICE, "SAFECLAW_TEST_VAR").unwrap();
        entry.set_password("test-value").unwrap();

        let result = var("SAFECLAW_TEST_VAR");
        assert_eq!(result, Ok("test-value".to_string()));

        entry.delete_credential().ok();
    }
}
```

Register the module in `src/main.rs`. Find the block of `mod` declarations near the top of the file (alongside the existing ones like `mod config;`) and add:

```rust
mod secrets;
```

- [ ] **Step 3: Run the tests to verify they compile and pass**

Run: `cargo test --lib secrets:: -- --nocapture`
Expected: both `secrets::tests::returns_not_present_for_missing_entry` and `secrets::tests::returns_value_for_existing_entry` PASS. If `keyring`'s `mock` module isn't public at this path, run `cargo doc --open -p keyring` or check `~/.cargo/registry/src/*/keyring-3*/src/lib.rs` for the correct mock re-export path and adjust the `use` line — the mock backend has shipped as `keyring::mock` since keyring 2.x but confirm against the resolved 3.x version in `Cargo.lock`.

- [ ] **Step 4: Commit**

```bash
git add Cargo.toml Cargo.lock src/secrets.rs src/main.rs
git commit -m "feat(secrets): add OS secrets store module backed by keyring crate"
```

---

## Task 2: Migrate dashboard auth secrets (`DASHBOARD_PASSWORD`, `JWT_SECRET`)

**Files:**
- Modify: `src/dashboard/routes.rs:61-83`

**Interfaces:**
- Consumes: `secrets::var(name: &str) -> Result<String, std::env::VarError>` from Task 1.

- [ ] **Step 1: Replace the two call sites**

In `src/dashboard/routes.rs`, replace:

```rust
    let dashboard_password = std::env::var("DASHBOARD_PASSWORD")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| {
            if password_required {
                None
            } else {
                // Password not required — use empty string as placeholder
                Some(String::new())
            }
        })
        .ok_or_else(|| {
            SafeAgentError::Config(
                "DASHBOARD_PASSWORD environment variable is required but not set".to_string(),
            )
        })?;

    let jwt_secret_str = std::env::var("JWT_SECRET")
        .ok()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            SafeAgentError::Config(
                "JWT_SECRET environment variable is required but not set".to_string(),
            )
        })?;
```

with:

```rust
    let dashboard_password = crate::secrets::var("DASHBOARD_PASSWORD")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| {
            if password_required {
                None
            } else {
                // Password not required — use empty string as placeholder
                Some(String::new())
            }
        })
        .ok_or_else(|| {
            SafeAgentError::Config(
                "DASHBOARD_PASSWORD not set. Set it in the OS secrets store: \
                 `secret-tool store --label='safeclaw: DASHBOARD_PASSWORD' service safeclaw username DASHBOARD_PASSWORD` \
                 (Linux) or `security add-generic-password -s safeclaw -a DASHBOARD_PASSWORD -w` (macOS)"
                    .to_string(),
            )
        })?;

    let jwt_secret_str = crate::secrets::var("JWT_SECRET")
        .ok()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            SafeAgentError::Config(
                "JWT_SECRET not set. Set it in the OS secrets store: \
                 `secret-tool store --label='safeclaw: JWT_SECRET' service safeclaw username JWT_SECRET` \
                 (Linux) or `security add-generic-password -s safeclaw -a JWT_SECRET -w` (macOS)"
                    .to_string(),
            )
        })?;
```

- [ ] **Step 2: Verify it compiles**

Run: `cargo check --lib`
Expected: no errors related to `dashboard/routes.rs`.

- [ ] **Step 3: Commit**

```bash
git add src/dashboard/routes.rs
git commit -m "feat(secrets): migrate dashboard auth to OS secrets store"
```

---

## Task 3: Migrate messaging bot tokens (`DISCORD_BOT_TOKEN`, `SLACK_BOT_TOKEN`, `MATRIX_ACCESS_TOKEN`, `MATRIX_PASSWORD`, `TELEGRAM_BOT_TOKEN`)

**Files:**
- Modify: `src/main.rs:305, 636, 798(no—see Task4), 874` — specifically the Discord/Slack/Matrix blocks (~line 305-390) and the `maybe_start_discord` check (~line 636)
- Modify: `src/messaging/discord.rs:244-246`
- Modify: `src/agent/mod.rs:116`
- Modify: `src/dashboard/messaging_webhook.rs:360`
- Modify: `src/config.rs:1410-1414` (`Config::telegram_bot_token`)

**Interfaces:**
- Consumes: `secrets::var` from Task 1.

- [ ] **Step 1: `src/main.rs` — Discord registration (~line 305)**

Replace:
```rust
        match std::env::var("DISCORD_BOT_TOKEN") {
```
with:
```rust
        match crate::secrets::var("DISCORD_BOT_TOKEN") {
```

- [ ] **Step 2: `src/main.rs` — Discord gateway gate (~line 636)**

Replace:
```rust
    if config.discord.enabled && std::env::var("DISCORD_BOT_TOKEN").is_ok() {
```
with:
```rust
    if config.discord.enabled && crate::secrets::var("DISCORD_BOT_TOKEN").is_ok() {
```

- [ ] **Step 3: `src/main.rs` — Slack registration (~line 341)**

Replace:
```rust
        match std::env::var("SLACK_BOT_TOKEN") {
```
with:
```rust
        match crate::secrets::var("SLACK_BOT_TOKEN") {
```

- [ ] **Step 4: `src/main.rs` — Matrix registration (~line 361-382)**

Replace:
```rust
        match std::env::var("MATRIX_ACCESS_TOKEN") {
```
with:
```rust
        match crate::secrets::var("MATRIX_ACCESS_TOKEN") {
```

And replace:
```rust
                if let (Ok(user), Ok(pass)) = (
                    std::env::var("MATRIX_USER"),
                    std::env::var("MATRIX_PASSWORD"),
                ) {
```
with (note: `MATRIX_USER` is a username, not a secret — stays on `std::env::var`):
```rust
                if let (Ok(user), Ok(pass)) = (
                    std::env::var("MATRIX_USER"),
                    crate::secrets::var("MATRIX_PASSWORD"),
                ) {
```

- [ ] **Step 5: `src/messaging/discord.rs` (~line 244)**

Replace:
```rust
    let token = std::env::var("DISCORD_BOT_TOKEN").map_err(|_| {
        crate::error::SafeAgentError::Config("DISCORD_BOT_TOKEN not set".into())
    })?;
```
with:
```rust
    let token = crate::secrets::var("DISCORD_BOT_TOKEN").map_err(|_| {
        crate::error::SafeAgentError::Config("DISCORD_BOT_TOKEN not set".into())
    })?;
```

- [ ] **Step 6: `src/agent/mod.rs` (~line 116)**

Replace:
```rust
        let bot_token = std::env::var("TELEGRAM_BOT_TOKEN").ok();
```
with:
```rust
        let bot_token = crate::secrets::var("TELEGRAM_BOT_TOKEN").ok();
```

- [ ] **Step 7: `src/dashboard/messaging_webhook.rs` (~line 360)**

Replace:
```rust
    let has_token = std::env::var("TELEGRAM_BOT_TOKEN").is_ok();
```
with:
```rust
    let has_token = crate::secrets::var("TELEGRAM_BOT_TOKEN").is_ok();
```

- [ ] **Step 8: `src/config.rs` — `telegram_bot_token()` (~line 1410-1414)**

Replace:
```rust
    /// Get the Telegram bot token from the environment.
    pub fn telegram_bot_token() -> Result<String> {
        std::env::var("TELEGRAM_BOT_TOKEN")
            .map_err(|_| SafeAgentError::Config("TELEGRAM_BOT_TOKEN environment variable not set".into()))
    }
```
with:
```rust
    /// Get the Telegram bot token from the OS secrets store.
    pub fn telegram_bot_token() -> Result<String> {
        crate::secrets::var("TELEGRAM_BOT_TOKEN")
            .map_err(|_| SafeAgentError::Config("TELEGRAM_BOT_TOKEN not set in OS secrets store".into()))
    }
```

- [ ] **Step 9: Verify it compiles**

Run: `cargo check --lib --features discord`
Expected: no errors.

- [ ] **Step 10: Commit**

```bash
git add src/main.rs src/messaging/discord.rs src/agent/mod.rs src/dashboard/messaging_webhook.rs src/config.rs
git commit -m "feat(secrets): migrate messaging bot tokens to OS secrets store"
```

---

## Task 4: Migrate LLM/tunnel/voice/trading API keys (`TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `NGROK_AUTHTOKEN`, `CODEX_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `TTS_API_KEY`, `WHISPER_API_KEY`, `ROBINHOOD_MCP_TOKEN`)

**Files:**
- Modify: `src/config.rs:1416-1422` (`Config::twilio_credentials`)
- Modify: `src/main.rs:514, 798, 824, 880, 907` (NGROK_AUTHTOKEN x3, CODEX_API_KEY, GEMINI_API_KEY/GOOGLE_API_KEY)
- Modify: `src/tunnel/ngrok.rs:27-33`
- Modify: `src/llm/openrouter.rs:118`
- Modify: `src/tools/voice.rs:71-73, 192-193`
- Modify: `src/tools/trading.rs:67`

**Interfaces:**
- Consumes: `secrets::var` from Task 1.

- [ ] **Step 1: `src/config.rs` — `twilio_credentials()` (~line 1416-1422)**

Replace:
```rust
    /// Read Twilio credentials from environment variables.
    pub fn twilio_credentials() -> Result<(String, String)> {
        let sid = std::env::var("TWILIO_ACCOUNT_SID")
            .map_err(|_| SafeAgentError::Config("TWILIO_ACCOUNT_SID not set".into()))?;
        let token = std::env::var("TWILIO_AUTH_TOKEN")
            .map_err(|_| SafeAgentError::Config("TWILIO_AUTH_TOKEN not set".into()))?;
        Ok((sid, token))
    }
```
with:
```rust
    /// Read Twilio credentials from the OS secrets store.
    pub fn twilio_credentials() -> Result<(String, String)> {
        let sid = crate::secrets::var("TWILIO_ACCOUNT_SID")
            .map_err(|_| SafeAgentError::Config("TWILIO_ACCOUNT_SID not set in OS secrets store".into()))?;
        let token = crate::secrets::var("TWILIO_AUTH_TOKEN")
            .map_err(|_| SafeAgentError::Config("TWILIO_AUTH_TOKEN not set in OS secrets store".into()))?;
        Ok((sid, token))
    }
```

- [ ] **Step 2: `src/main.rs` — NGROK_AUTHTOKEN, 3 sites**

At ~line 514:
```rust
    let tunnel_url = if config.tunnel.enabled
        || std::env::var("NGROK_AUTHTOKEN").is_ok()
    {
```
becomes:
```rust
    let tunnel_url = if config.tunnel.enabled
        || crate::secrets::var("NGROK_AUTHTOKEN").is_ok()
    {
```

At ~line 880:
```rust
    let tunnel_enabled = config.tunnel.enabled || std::env::var("NGROK_AUTHTOKEN").is_ok();
```
becomes:
```rust
    let tunnel_enabled = config.tunnel.enabled || crate::secrets::var("NGROK_AUTHTOKEN").is_ok();
```

At ~line 907:
```rust
                match std::env::var("NGROK_AUTHTOKEN") {
                    Ok(_) => info!("NGROK_AUTHTOKEN: set"),
                    Err(_) => info!("NGROK_AUTHTOKEN: not set (ngrok will use saved auth)"),
                }
```
becomes:
```rust
                match crate::secrets::var("NGROK_AUTHTOKEN") {
                    Ok(_) => info!("NGROK_AUTHTOKEN: set"),
                    Err(_) => info!("NGROK_AUTHTOKEN: not set (ngrok will use saved auth)"),
                }
```

- [ ] **Step 3: `src/main.rs` — CODEX_API_KEY (~line 798)**

Replace:
```rust
            match std::env::var("CODEX_API_KEY") {
                Ok(_) => info!("CODEX_API_KEY: set"),
                Err(_) => info!("CODEX_API_KEY: not set (will use saved auth)"),
            }
```
with:
```rust
            match crate::secrets::var("CODEX_API_KEY") {
                Ok(_) => info!("CODEX_API_KEY: set"),
                Err(_) => info!("CODEX_API_KEY: not set (will use saved auth)"),
            }
```

- [ ] **Step 4: `src/main.rs` — GEMINI_API_KEY / GOOGLE_API_KEY (~line 824)**

Replace:
```rust
            match std::env::var("GEMINI_API_KEY").or(std::env::var("GOOGLE_API_KEY")) {
                Ok(_) => info!("GEMINI_API_KEY / GOOGLE_API_KEY: set"),
                Err(_) => info!("GEMINI_API_KEY: not set (will use saved auth)"),
            }
```
with:
```rust
            match crate::secrets::var("GEMINI_API_KEY").or(crate::secrets::var("GOOGLE_API_KEY")) {
                Ok(_) => info!("GEMINI_API_KEY / GOOGLE_API_KEY: set"),
                Err(_) => info!("GEMINI_API_KEY: not set (will use saved auth)"),
            }
```

- [ ] **Step 5: `src/tunnel/ngrok.rs` (~line 27-33)**

Replace:
```rust
    let authtoken = std::env::var("NGROK_AUTHTOKEN").ok().or_else(|| {
        if config.authtoken.is_empty() {
            None
        } else {
            Some(config.authtoken.clone())
        }
    });
```
with:
```rust
    let authtoken = crate::secrets::var("NGROK_AUTHTOKEN").ok().or_else(|| {
        if config.authtoken.is_empty() {
            None
        } else {
            Some(config.authtoken.clone())
        }
    });
```

- [ ] **Step 6: `src/llm/openrouter.rs` (~line 118)**

Replace:
```rust
        let api_key = std::env::var("OPENROUTER_API_KEY")
            .ok()
```
with:
```rust
        let api_key = crate::secrets::var("OPENROUTER_API_KEY")
            .ok()
```

- [ ] **Step 7: `src/tools/voice.rs` — transcription key chain (~line 71-73)**

Replace:
```rust
        let api_key = std::env::var("OPENAI_API_KEY")
            .or_else(|_| std::env::var("WHISPER_API_KEY"))
            .or_else(|_| std::env::var("OPENROUTER_API_KEY"))
            .unwrap_or_default();
```
with:
```rust
        let api_key = crate::secrets::var("OPENAI_API_KEY")
            .or_else(|_| crate::secrets::var("WHISPER_API_KEY"))
            .or_else(|_| crate::secrets::var("OPENROUTER_API_KEY"))
            .unwrap_or_default();
```

- [ ] **Step 8: `src/tools/voice.rs` — TTS key chain (~line 192-193)**

Replace:
```rust
        let api_key = std::env::var("OPENAI_API_KEY")
            .or_else(|_| std::env::var("TTS_API_KEY"))
            .unwrap_or_default();
```
with:
```rust
        let api_key = crate::secrets::var("OPENAI_API_KEY")
            .or_else(|_| crate::secrets::var("TTS_API_KEY"))
            .unwrap_or_default();
```

- [ ] **Step 9: `src/tools/trading.rs` (~line 67)**

Replace:
```rust
            if let Ok(token) = std::env::var(ROBINHOOD_TOKEN_ENV) {
```
with:
```rust
            if let Ok(token) = crate::secrets::var(ROBINHOOD_TOKEN_ENV) {
```

(`ROBINHOOD_TOKEN_ENV` is the existing `const ROBINHOOD_TOKEN_ENV: &str = "ROBINHOOD_MCP_TOKEN";` at the top of the file — unchanged.)

- [ ] **Step 10: Verify it compiles with the relevant features**

Run: `cargo check --lib --features discord,daimon`
Expected: no errors.

- [ ] **Step 11: Commit**

```bash
git add src/config.rs src/main.rs src/tunnel/ngrok.rs src/llm/openrouter.rs src/tools/voice.rs src/tools/trading.rs
git commit -m "feat(secrets): migrate LLM/tunnel/voice/trading API keys to OS secrets store"
```

---

## Task 5: Full workspace build + test pass

**Files:** none (verification only)

- [ ] **Step 1: Build with default features**

Run: `cargo build`
Expected: builds cleanly, no leftover references to the 18 migrated vars via `std::env::var` (spot-checked in Step 3).

- [ ] **Step 2: Build with the optional feature sets that touch migrated code**

Run: `cargo build --features discord,daimon`
Expected: builds cleanly.

- [ ] **Step 3: Confirm no migrated var still uses `std::env::var`**

Run:
```bash
for v in DASHBOARD_PASSWORD JWT_SECRET DISCORD_BOT_TOKEN SLACK_BOT_TOKEN MATRIX_ACCESS_TOKEN MATRIX_PASSWORD TELEGRAM_BOT_TOKEN TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN NGROK_AUTHTOKEN CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY TTS_API_KEY WHISPER_API_KEY ROBINHOOD_MCP_TOKEN; do
  grep -rn "std::env::var(\"$v\")\|std::env::var(ROBINHOOD_TOKEN_ENV)" src/ && echo "STILL PRESENT: $v"
done
```
Expected: no output (the `ROBINHOOD_TOKEN_ENV` grep is expected to no longer match `std::env::var`, only `crate::secrets::var`).

- [ ] **Step 4: Run the full test suite**

Run: `cargo test --lib`
Expected: all tests pass, including the two `secrets::tests::*` tests from Task 1.

- [ ] **Step 5: Commit (only if Step 1-4 required fixes)**

If everything already passed with no changes, skip this step — nothing to commit. Otherwise:
```bash
git add -A
git commit -m "fix: address build/test issues from secrets store migration"
```

---

## Task 6: Docker, docs, and `.env.example` updates

**Files:**
- Modify: `docker-compose.yml`
- Modify: `.env.example`
- Modify: `src/main.rs:1117-1120` (the `ENVIRONMENT:` usage/help text block)

**Interfaces:** none (docs/config only).

- [ ] **Step 1: Update `docker-compose.yml` to mount the host D-Bus socket**

Current content:
```yaml
# Docker is optional — safeclaw self-sandboxes via Landlock, seccomp-bpf,
# and capability dropping on Linux. This compose file is provided for
# convenience; the binary runs with equivalent isolation natively.
services:
  safeclaw:
    build:
      context: .
      dockerfile: Dockerfile
    image: safeclaw:latest
    container_name: safeclaw
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${HOME}/.local/share/safeclaw:/data/safeclaw
      - ./config.toml:/config/safeclaw/config.toml:ro
      - ${CLAUDE_CONFIG_DIR:-${HOME}/.claude}:/claude-config
    env_file:
      - .env
    environment:
      - CLAUDE_CONFIG_DIR=/claude-config
      - HOME=/home/safeclaw
```

Replace with:
```yaml
# Docker is optional — safeclaw self-sandboxes via Landlock, seccomp-bpf,
# and capability dropping on Linux. This compose file is provided for
# convenience; the binary runs with equivalent isolation natively.
#
# Secrets (bot tokens, API keys, DASHBOARD_PASSWORD, JWT_SECRET, etc.) are
# read from the OS secrets store (see src/secrets.rs), not from .env. The
# container runs as an unprivileged user with no desktop session, so the
# host's Secret Service is passed in via a D-Bus socket bind mount. Set
# SAFECLAW_UID to the uid whose keyring holds the secrets (defaults to
# 1000, matching the Dockerfile's SAFE_UID build arg).
services:
  safeclaw:
    build:
      context: .
      dockerfile: Dockerfile
    image: safeclaw:latest
    container_name: safeclaw
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${HOME}/.local/share/safeclaw:/data/safeclaw
      - ./config.toml:/config/safeclaw/config.toml:ro
      - ${CLAUDE_CONFIG_DIR:-${HOME}/.claude}:/claude-config
      - /run/user/${SAFECLAW_UID:-1000}/bus:/run/user/${SAFECLAW_UID:-1000}/bus
    env_file:
      - .env
    environment:
      - CLAUDE_CONFIG_DIR=/claude-config
      - HOME=/home/safeclaw
      - DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${SAFECLAW_UID:-1000}/bus
```

- [ ] **Step 2: Update `.env.example`**

Replace the secret-var lines (`DASHBOARD_PASSWORD`, `JWT_SECRET`, `CODEX_API_KEY`, `GEMINI_API_KEY`, `TELEGRAM_BOT_TOKEN`, `NGROK_AUTHTOKEN`) with a banner. The file's header currently reads:

```
# safe-agent environment variables
# Copy this to .env and fill in your values

RUST_LOG=info

# Dashboard authentication (REQUIRED — agent will not start without these)
DASHBOARD_PASSWORD=changeme
JWT_SECRET=replace-with-a-long-random-string
```

Replace with:

```
# safe-agent environment variables
# Copy this to .env and fill in your values
#
# Secrets (bot tokens, API keys, passwords, JWT_SECRET) are NOT set here —
# they live in the OS secrets store. Set them with:
#   Linux:  secret-tool store --label="safeclaw: NAME" service safeclaw username NAME
#   macOS:  security add-generic-password -s safeclaw -a NAME -w
#
# Required secrets: DASHBOARD_PASSWORD, JWT_SECRET
# Optional secrets (only if the corresponding feature is enabled):
#   DISCORD_BOT_TOKEN, SLACK_BOT_TOKEN, MATRIX_ACCESS_TOKEN, MATRIX_PASSWORD,
#   TELEGRAM_BOT_TOKEN, TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, NGROK_AUTHTOKEN,
#   CODEX_API_KEY, GEMINI_API_KEY, GOOGLE_API_KEY, OPENAI_API_KEY,
#   OPENROUTER_API_KEY, TTS_API_KEY, WHISPER_API_KEY, ROBINHOOD_MCP_TOKEN

RUST_LOG=info
```

Then remove the now-stale inline mentions of these same secret vars further down the file — specifically the commented-out `# CODEX_API_KEY=`, `# GEMINI_API_KEY=`, `# TELEGRAM_BOT_TOKEN=`, and `# NGROK_AUTHTOKEN=your-ngrok-authtoken` lines (keep the non-secret lines directly above/below them, like `# CODEX_BIN=codex` and `# NGROK_BIN=ngrok`, untouched).

- [ ] **Step 3: Update the `ENVIRONMENT:` help text in `src/main.rs`**

Find (~line 1117-1120):
```rust
ENVIRONMENT:
    DASHBOARD_PASSWORD    Required. Dashboard login password.
    JWT_SECRET            Required. Secret for signing dashboard JWT cookies.
    TELEGRAM_BOT_TOKEN    Required if Telegram is enabled.
    RUST_LOG              Optional. Tracing filter (default: info).
```

Replace with:
```rust
ENVIRONMENT:
    Secrets (DASHBOARD_PASSWORD, JWT_SECRET, TELEGRAM_BOT_TOKEN, etc.) are
    read from the OS secrets store, not env vars. Set them with:
      Linux:  secret-tool store --label=\"safeclaw: NAME\" service safeclaw username NAME
      macOS:  security add-generic-password -s safeclaw -a NAME -w
    DASHBOARD_PASSWORD and JWT_SECRET are required; TELEGRAM_BOT_TOKEN is
    required if Telegram is enabled.

    RUST_LOG              Optional. Tracing filter (default: info).
```

- [ ] **Step 4: Verify it compiles**

Run: `cargo check --lib`
Expected: no errors (this task only touches string literals and non-Rust files).

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml .env.example src/main.rs
git commit -m "docs: document OS secrets store setup, mount host D-Bus socket in compose"
```

---

## Self-Review Notes

- **Spec coverage:** `src/secrets.rs` module (Task 1), all 18 named vars migrated (Tasks 2-4), Docker D-Bus mount (Task 6), `.env.example`/README-equivalent docs (Task 6), mock-backend test coverage (Task 1) — all spec requirements have a task.
- **Non-goals respected:** no new CLI subcommand added; the ~30 non-secret vars (`CLAUDE_BIN`, `MODEL_PATH`, `NGROK_BIN`, `MATRIX_USER`, etc.) are explicitly left on `std::env::var` in every task and verified untouched by Task 5 Step 3's grep.
- **Type consistency:** `secrets::var` signature (`fn(&str) -> Result<String, std::env::VarError>`) is identical across every call site in Tasks 2-4 — no call site needed restructuring beyond the function name, confirming the design's core claim.
