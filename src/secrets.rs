//! OS secrets store access. Wraps the `keyring` crate behind an
//! `std::env::var`-shaped API so call sites don't need to change their
//! surrounding `.ok()` / `match` / `?` logic when switching from env vars.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

const SERVICE: &str = "safeclaw";

/// Process-local cache of `keyring::Entry` objects, keyed by secret name.
///
/// Real OS backends (Secret Service, Keychain, Credential Manager) persist
/// to shared storage keyed by service/user, so any `Entry` built for the
/// same name sees the same data regardless of caching. The `keyring` crate's
/// `mock` test backend is different: each `Entry` instance gets its own
/// private, unshared credential (`CredentialPersistence::EntryOnly`) — two
/// separately-constructed `Entry`s for the same service/user do NOT see each
/// other's data. Caching entries here by name ensures repeated lookups (and
/// test setup code) reuse the same `Entry` object, which is required for the
/// mock backend to behave sensibly in tests and is a harmless (slightly
/// cheaper) optimization under real backends.
fn entry_cache() -> &'static Mutex<HashMap<String, keyring::Entry>> {
    static CACHE: OnceLock<Mutex<HashMap<String, keyring::Entry>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Run `f` against the cached `Entry` for `name`, creating and caching it
/// first if this is the first lookup for that name.
fn with_cached_entry<T>(
    name: &str,
    f: impl FnOnce(&keyring::Entry) -> T,
) -> Result<T, keyring::Error> {
    let mut cache = entry_cache().lock().expect("secrets entry cache poisoned");
    if !cache.contains_key(name) {
        let entry = keyring::Entry::new(SERVICE, name)?;
        cache.insert(name.to_string(), entry);
    }
    Ok(f(cache.get(name).expect("entry just inserted or present")))
}

/// Look up `name` in the OS secrets store (Secret Service on Linux,
/// Keychain on macOS, Credential Manager on Windows). Returns
/// `Err(VarError::NotPresent)` if the entry doesn't exist OR if the
/// backend itself is unreachable (e.g. no D-Bus session) — in the latter
/// case a warning is logged with the underlying error so operators can
/// diagnose it, but callers see the same "not present" shape they already
/// handle for env vars today.
pub fn var(name: &str) -> Result<String, std::env::VarError> {
    match with_cached_entry(name, |entry| entry.get_password()) {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(keyring::Error::NoEntry)) => Err(std::env::VarError::NotPresent),
        Ok(Err(e)) => {
            tracing::warn!("secrets: keyring backend error reading {name}: {e}");
            Err(std::env::VarError::NotPresent)
        }
        Err(e) => {
            tracing::warn!("secrets: failed to build keyring entry for {name}: {e}");
            Err(std::env::VarError::NotPresent)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use keyring::{mock, set_default_credential_builder};
    use std::sync::Once;

    // `mock::default_credential_builder()` allocates a fresh in-memory store
    // each time it's called. Tests run in parallel on separate threads, so
    // calling `set_default_credential_builder` once per test would race:
    // whichever test calls it last resets the global backend and wipes out
    // entries the other test already wrote. `Once` ensures the mock backend
    // is installed exactly one time for the whole test binary.
    static INIT: Once = Once::new();

    fn use_mock_backend() {
        INIT.call_once(|| {
            set_default_credential_builder(mock::default_credential_builder());
        });
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
        with_cached_entry("SAFECLAW_TEST_VAR", |entry| {
            entry.set_password("test-value").unwrap()
        })
        .unwrap();

        let result = var("SAFECLAW_TEST_VAR");
        assert_eq!(result, Ok("test-value".to_string()));

        let _ = with_cached_entry("SAFECLAW_TEST_VAR", |entry| entry.delete_credential().ok());
    }
}
