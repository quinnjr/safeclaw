# OS Secrets Store — Design

## Problem

safeclaw currently reads ~20 credential-shaped values (bot tokens, API keys,
passwords, JWT secret) via `std::env::var(...)`, sourced from `.env` /
process environment. These sit alongside ~30 non-secret env vars (binary
paths, model names, URLs, ports, feature flags). Storing real secrets in a
plaintext `.env` file is weaker than using the OS's native secrets store.

## Goals

- Move the ~20 credential-shaped vars to the OS secrets store (via the
  `keyring` crate: Secret Service on Linux, Keychain on macOS, Credential
  Manager on Windows).
- Leave the ~30 non-secret vars (bins, models, URLs, ports, flags) as plain
  `std::env::var` reads — unchanged.
- No dual-path fallback to env vars for the moved secrets — the keyring is
  the sole source of truth for them going forward.
- No new safeclaw CLI subcommand for secret management — document OS-native
  tooling (`secret-tool`, `security`) instead.
- Docker container (runs as unprivileged `safeclaw` user, no desktop
  session) must be able to reach the *host's* Secret Service.

## Non-goals

- Migrating the ~30 non-secret env vars.
- Building a `safeclaw secrets` CLI.
- Supporting hosts with no Secret Service/Keychain available (no automatic
  env-var fallback — such hosts must have a working OS secrets store, or the
  affected features simply won't start, same as "unset" today).

## Design

### `src/secrets.rs`

```rust
pub fn var(name: &str) -> Result<String, std::env::VarError>
```

Signature mirrors `std::env::var` exactly. Internally:
1. `keyring::Entry::new("safeclaw", name)`
2. `.get_password()`
3. `Ok(v) => Ok(v)`
4. `Err(keyring::Error::NoEntry) => Err(std::env::VarError::NotPresent)`
5. Any other backend error (no D-Bus session, locked keyring, etc.) is
   logged at `warn` level with the underlying error, then also mapped to
   `Err(std::env::VarError::NotPresent)` — callers see the same "unset"
   behavior they already handle today, but operators get a log line
   explaining *why*.

Because the signature matches `std::env::var`, every existing call site's
surrounding logic (`.ok()`, `match`, `.unwrap_or_else(...)`, `?`) is
untouched — only the function name/import changes at each of the ~20 call
sites for these vars:

`DASHBOARD_PASSWORD`, `JWT_SECRET`, `DISCORD_BOT_TOKEN`, `SLACK_BOT_TOKEN`,
`MATRIX_ACCESS_TOKEN`, `MATRIX_PASSWORD`, `TELEGRAM_BOT_TOKEN`,
`TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `NGROK_AUTHTOKEN`,
`CODEX_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `OPENAI_API_KEY`,
`OPENROUTER_API_KEY`, `TTS_API_KEY`, `WHISPER_API_KEY`,
`ROBINHOOD_MCP_TOKEN`.

All other env vars (`CLAUDE_BIN`, `CLAUDE_MODEL`, `MODEL_PATH`,
`OLLAMA_HOST`, `ACME_DOMAIN`, `NGROK_PORT`, etc.) keep using
`std::env::var` directly.

### Dependency

```toml
[target.'cfg(target_os = "macos")'.dependencies]
keyring = { version = "3", features = ["apple-native"] }

[target.'cfg(target_os = "linux")'.dependencies]
keyring = { version = "3", features = ["sync-secret-service", "vendored"] }

[target.'cfg(target_os = "windows")'.dependencies]
keyring = { version = "3", features = ["windows-native"] }
```

### Setting secrets (operator workflow)

No safeclaw CLI. Document OS-native tools in `.env.example` and README:

- Linux: `secret-tool store --label="safeclaw: DISCORD_BOT_TOKEN" service safeclaw username DISCORD_BOT_TOKEN`
- macOS: `security add-generic-password -s safeclaw -a DISCORD_BOT_TOKEN -w`

### Docker

The container runs as the unprivileged `safeclaw` user with no desktop
session, so it needs the host's Secret Service passed in via D-Bus socket
bind mount:

```yaml
volumes:
  - /run/user/${UID:-1000}/bus:/run/user/${UID:-1000}/bus
environment:
  - DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${UID:-1000}/bus
```

`UID` should match the host uid whose keyring holds the secrets (typically
the same as `SAFE_UID` build arg). Hosts without a running Secret Service
session (e.g. a bare CI runner) simply won't have secrets available —
same as today's "unset" behavior, now with a clearer log message.

### Error handling

- Required secrets (`DASHBOARD_PASSWORD`, `JWT_SECRET`) already abort
  startup if missing (`src/main.rs`). Their error messages are updated to
  include the exact `secret-tool`/`security` command to set them.
- Optional secrets (bot tokens, API keys) keep existing
  "feature disabled/skipped" behavior when absent — no behavior change,
  just a different source.

### Testing

`secrets::var`'s `Ok`/`NotPresent` mapping is covered by a `#[cfg(test)]`
unit test using `keyring`'s `mock` credential backend (no real OS keyring
touched in CI). No integration test against a live Secret Service/Keychain.

### Docs

- `.env.example`: replace the ~20 secret var entries with a banner
  pointing at the `secret-tool`/`security` commands; keep the ~30
  non-secret entries as-is.
- `README.md` (if it documents env vars): same treatment.
