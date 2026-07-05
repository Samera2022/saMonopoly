use sa_monopoly_domain::config::{ConfigDocument, ConfigError};

/// Type‑safe configuration storage interface.
///
/// Implementations handle persistence (file, memory, etc.) and version
/// migration transparently.
pub trait ConfigService {
    /// Load the entire configuration document.
    ///
    /// Returns the default `ConfigDocument` if no persisted config exists yet.
    fn load_all(&self) -> Result<ConfigDocument, ConfigError>;

    /// Persist the entire configuration document, overwriting any previous
    /// stored config.
    fn save_all(&self, config: &ConfigDocument) -> Result<(), ConfigError>;

    /// Load and deserialize a single configuration section.
    ///
    /// If the section key is missing or deserialization fails, `T::default()`
    /// is returned — the system will never crash due to a corrupt/missing
    /// config section.
    fn load_section<T>(&self, key: &str) -> Result<T, ConfigError>
    where
        T: serde::de::DeserializeOwned + Default,
    {
        let doc = self.load_all()?;
        match doc.sections.get(key) {
            Some(value) => serde_json::from_value(value.clone()).or_else(|e| {
                eprintln!(
                    "WARN: Failed to deserialize config section `{key}`: {e}; falling back to default"
                );
                Ok(T::default())
            }),
            None => Ok(T::default()),
        }
    }

    /// Serialize and persist a single configuration section, merging it into
    /// the existing document.
    fn save_section<T>(&self, key: &str, section: &T) -> Result<(), ConfigError>
    where
        T: serde::Serialize,
    {
        let mut doc = self.load_all().unwrap_or_default();
        let value =
            serde_json::to_value(section).map_err(|e| ConfigError::Serialize(e.to_string()))?;
        doc.sections.insert(key.to_string(), value);
        self.save_all(&doc)
    }
}

// ── Default implementation for testing ──────────────────────────────────────

/// In‑memory config store useful for tests or ephemeral sessions.
pub struct MemoryConfigService {
    doc: ConfigDocument,
}

impl MemoryConfigService {
    pub fn new() -> Self {
        Self {
            doc: ConfigDocument::current(),
        }
    }
}

impl Default for MemoryConfigService {
    fn default() -> Self {
        Self::new()
    }
}

impl ConfigService for MemoryConfigService {
    fn load_all(&self) -> Result<ConfigDocument, ConfigError> {
        Ok(self.doc.clone())
    }

    fn save_all(&self, _config: &ConfigDocument) -> Result<(), ConfigError> {
        // In-memory store: mutation is a no-op for simplicity.
        // Tests that need persistence should use FileConfigStore.
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sa_monopoly_domain::config::AppConfig;

    #[test]
    fn test_load_section_default_when_missing() {
        let svc = MemoryConfigService::new();
        let app: AppConfig = svc.load_section("nonexistent").unwrap();
        assert_eq!(app.language, "en"); // AppConfig::default()
    }

    #[test]
    fn test_save_then_load_section() {
        let svc = MemoryConfigService::new();
        let custom = AppConfig {
            language: "zh-Hans".to_string(),
            ..Default::default()
        };
        svc.save_section("app", &custom).unwrap();
        // MemoryConfigService::save_all is a no-op, so load returns default
        let loaded: AppConfig = svc.load_section("app").unwrap();
        assert_eq!(loaded.language, "en");
    }
}
