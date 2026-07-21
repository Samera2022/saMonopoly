//! # Secret store — OS keychain integration for sensitive config values
//!
//! API keys must never be persisted to the plaintext config file. Instead, the
//! config layer stores a *reference* (`keyring:<id>`) on disk and keeps the raw
//! secret in the operating system's credential store (Keychain on macOS/iOS,
//! Credential Manager on Windows, Secret Service on Linux).
//!
//! References supported by the resolver:
//! - `keyring:<id>`  — secret stored in the OS keychain under `<id>`
//! - `env:<VAR>`     — secret read from an environment variable at request time
//! - anything else   — treated as a literal secret (legacy / plaintext)
//!
//! If the keychain is unavailable (headless CI, missing Secret Service, etc.)
//! the helpers return errors that callers surface to the UI rather than
//! silently losing the key.

/// Service name used to namespace all saMonopoly secrets in the OS keychain.
const KEYCHAIN_SERVICE: &str = "saMonopoly";

/// Prefix marking a value as an OS-keychain reference.
pub const KEYRING_PREFIX: &str = "keyring:";

/// Prefix marking a value as an environment-variable reference.
pub const ENV_PREFIX: &str = "env:";

/// Whether `value` is a reference (keyring/env) rather than a literal secret.
pub fn is_reference(value: &str) -> bool {
    value.starts_with(KEYRING_PREFIX) || value.starts_with(ENV_PREFIX)
}

/// Store `secret` in the OS keychain under `id` and return the `keyring:<id>`
/// reference that should be persisted to disk in place of the raw secret.
///
/// An empty secret clears any existing entry and returns an empty string so the
/// config simply records "no key".
pub fn store_secret(id: &str, secret: &str) -> Result<String, String> {
    if secret.is_empty() {
        // Best-effort cleanup; ignore "not found".
        let _ = delete_secret(id);
        return Ok(String::new());
    }
    let entry = keyring::Entry::new(KEYCHAIN_SERVICE, id)
        .map_err(|e| format!("keychain unavailable: {e}"))?;
    entry
        .set_password(secret)
        .map_err(|e| format!("failed to store secret in keychain: {e}"))?;
    Ok(format!("{KEYRING_PREFIX}{id}"))
}

/// Delete the secret stored under `id`, if any. Missing entries are not errors.
pub fn delete_secret(id: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(KEYCHAIN_SERVICE, id)
        .map_err(|e| format!("keychain unavailable: {e}"))?;
    match entry.delete_credential() {
        Ok(()) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(format!("failed to delete secret from keychain: {e}")),
    }
}

/// Resolve a stored config value into the raw secret to use for a request.
///
/// - `keyring:<id>` reads from the OS keychain.
/// - `env:<VAR>` reads from the environment.
/// - any other value is returned verbatim (literal secret).
pub fn resolve_secret(value: &str) -> Result<String, String> {
    if let Some(id) = value.strip_prefix(KEYRING_PREFIX) {
        if id.is_empty() {
            return Err("keychain reference is missing an id".to_string());
        }
        let entry = keyring::Entry::new(KEYCHAIN_SERVICE, id)
            .map_err(|e| format!("keychain unavailable: {e}"))?;
        return match entry.get_password() {
            Ok(secret) => Ok(secret),
            Err(keyring::Error::NoEntry) => {
                Err(format!("no secret found in keychain for '{id}'"))
            }
            Err(e) => Err(format!("failed to read secret from keychain: {e}")),
        };
    }
    if let Some(name) = value.strip_prefix(ENV_PREFIX) {
        if name.is_empty() {
            return Err("environment variable name is empty".to_string());
        }
        return std::env::var(name)
            .map_err(|_| format!("environment variable '{name}' is not set"));
    }
    Ok(value.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literal_values_resolve_verbatim() {
        assert_eq!(resolve_secret("sk-123").unwrap(), "sk-123");
        assert!(!is_reference("sk-123"));
    }

    #[test]
    fn env_reference_resolves_from_environment() {
        std::env::set_var("SA_TEST_SECRET", "from-env");
        assert!(is_reference("env:SA_TEST_SECRET"));
        assert_eq!(resolve_secret("env:SA_TEST_SECRET").unwrap(), "from-env");
        std::env::remove_var("SA_TEST_SECRET");
        assert!(resolve_secret("env:SA_TEST_SECRET").is_err());
    }

    #[test]
    fn empty_env_and_keyring_ids_error() {
        assert!(resolve_secret("env:").is_err());
        assert!(resolve_secret("keyring:").is_err());
    }

    #[test]
    fn keyring_prefix_is_a_reference() {
        assert!(is_reference("keyring:llm_api_key"));
    }
}
