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
///
/// Builds a fresh `keyring::Entry` on every call: real OS backends (Secret
/// Service, Keychain, Credential Manager) persist to shared storage keyed
/// by service/user, so a fresh `Entry` for the same name always sees the
/// same data — no caching is needed here. (The `#[cfg(test)]` build below
/// takes a different path, because the `keyring` crate's `mock` test
/// backend gives each `Entry` instance its own private, unshared credential
/// store and can't see values written by a separately-constructed `Entry`
/// for the same name — see `tests::with_cached_entry`.)
#[cfg(not(test))]
pub fn var(name: &str) -> Result<String, std::env::VarError> {
    let result = keyring::Entry::new(SERVICE, name).and_then(|entry| entry.get_password());
    match result {
        Ok(v) => Ok(v),
        Err(keyring::Error::NoEntry) => Err(std::env::VarError::NotPresent),
        Err(e) => {
            tracing::warn!("secrets: keyring error reading {name}: {e}");
            Err(std::env::VarError::NotPresent)
        }
    }
}

#[cfg(test)]
pub fn var(name: &str) -> Result<String, std::env::VarError> {
    match tests::with_cached_entry(name, |entry| entry.get_password()) {
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
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex, OnceLock, Once};

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

    // Test-only cache of `keyring::Entry` objects, keyed by secret name.
    // The `mock` backend gives each `Entry` instance its own private,
    // unshared credential (`CredentialPersistence::EntryOnly`) — two
    // separately-constructed `Entry`s for the same service/user do NOT see
    // each other's data. Caching entries here by name ensures repeated
    // lookups (test setup and `var()`) reuse the same `Entry` object, which
    // is required for the mock backend to behave sensibly in tests.
    fn entry_cache() -> &'static Mutex<HashMap<String, Arc<keyring::Entry>>> {
        static CACHE: OnceLock<Mutex<HashMap<String, Arc<keyring::Entry>>>> = OnceLock::new();
        CACHE.get_or_init(|| Mutex::new(HashMap::new()))
    }

    /// Run `f` against the cached `Entry` for `name`, creating and caching
    /// it first if this is the first lookup for that name. The lock is
    /// held only long enough to look up/insert into the `HashMap`; `f` runs
    /// after the lock has been released.
    pub(super) fn with_cached_entry<T>(
        name: &str,
        f: impl FnOnce(&keyring::Entry) -> T,
    ) -> Result<T, keyring::Error> {
        let entry = {
            let mut cache = entry_cache().lock().unwrap_or_else(|e| e.into_inner());
            if !cache.contains_key(name) {
                let entry = keyring::Entry::new(SERVICE, name)?;
                cache.insert(name.to_string(), Arc::new(entry));
            }
            Arc::clone(cache.get(name).expect("entry just inserted or present"))
        };
        Ok(f(&entry))
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
