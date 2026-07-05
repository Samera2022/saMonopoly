use std::cell::RefCell;
use std::path::PathBuf;

use sa_monopoly_application::config::ConfigService;
use sa_monopoly_domain::config::{ConfigDocument, ConfigError};

use crate::persistence::{FileSaveStore, SaveStore};
use crate::save::{JsonVersionedSaveCodec, MigrationChain, VersionedSave, VersionedSaveCodec};

/// The key used to store the configuration document inside the `SaveStore`.
const CONFIG_STORE_KEY: &str = "config";

// ── FileConfigStore ─────────────────────────────────────────────────────────

/// A [`ConfigService`] implementation that persists configuration to a JSON
/// file, with versioned migration support.
pub struct FileConfigStore {
    store: FileSaveStore,
    codec: JsonVersionedSaveCodec,
    chain: MigrationChain,
}

impl FileConfigStore {
    /// Create a new `FileConfigStore` rooted at `config_dir`.
    ///
    /// The configuration will be stored as `{config_dir}/config.sav`.
    pub fn new(config_dir: PathBuf) -> Self {
        Self {
            store: FileSaveStore::new(config_dir),
            codec: JsonVersionedSaveCodec,
            chain: default_config_migration_chain(),
        }
    }
}

impl ConfigService for FileConfigStore {
    fn load_all(&self) -> Result<ConfigDocument, ConfigError> {
        let bytes = match self.store.load(CONFIG_STORE_KEY) {
            Ok(b) => b,
            Err(_) => {
                // No persisted config yet — return defaults.
                return Ok(ConfigDocument::current());
            }
        };

        // Decode the versioned envelope.
        let versioned: VersionedSave = self
            .codec
            .decode_versioned(&bytes)
            .map_err(|e| ConfigError::Deserialize(e))?;

        // If the stored version is older than current, run migrations.
        let data = if versioned.version < sa_monopoly_domain::config::CURRENT_CONFIG_VERSION {
            self.chain
                .migrate_to_current(&versioned.data, versioned.version)
                .map_err(|e| ConfigError::Migration(e))?
        } else {
            versioned.data
        };

        // Deserialize the config document.
        serde_json::from_str(&data).map_err(|e| ConfigError::Deserialize(e.to_string()))
    }

    fn save_all(&self, config: &ConfigDocument) -> Result<(), ConfigError> {
        let json = serde_json::to_string_pretty(config)
            .map_err(|e| ConfigError::Serialize(e.to_string()))?;

        let versioned = VersionedSave::new(
            sa_monopoly_domain::config::CURRENT_CONFIG_VERSION,
            json,
        );

        let bytes = self
            .codec
            .encode_versioned(&versioned)
            .map_err(|e| ConfigError::Serialize(e.to_string()))?;

        self.store
            .save(CONFIG_STORE_KEY, &bytes)
            .map_err(|e| ConfigError::Io(e))
    }
}

// ── Migration Chain ─────────────────────────────────────────────────────────

/// Build the default config migration chain.
///
/// Register new migrations here as the config format evolves.
pub fn default_config_migration_chain() -> MigrationChain {
    let chain = MigrationChain::new();
    // Future migrations: chain.add(Box::new(V1ToV2ConfigMigration));
    chain
}

// ── InMemoryConfigStore (for testing) ───────────────────────────────────────

/// A [`ConfigService`] implementation that stores configuration in memory.
///
/// Useful for tests and ephemeral sessions where no file I/O is desired.
pub struct InMemoryConfigStore {
    doc: RefCell<ConfigDocument>,
}

impl InMemoryConfigStore {
    pub fn new() -> Self {
        Self {
            doc: RefCell::new(ConfigDocument::current()),
        }
    }

    pub fn with_defaults() -> Self {
        Self::new()
    }
}

impl Default for InMemoryConfigStore {
    fn default() -> Self {
        Self::new()
    }
}

impl ConfigService for InMemoryConfigStore {
    fn load_all(&self) -> Result<ConfigDocument, ConfigError> {
        Ok(self.doc.borrow().clone())
    }

    fn save_all(&self, config: &ConfigDocument) -> Result<(), ConfigError> {
        *self.doc.borrow_mut() = config.clone();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sa_monopoly_domain::config::AppConfig;
    use std::fs;

    #[test]
    fn test_file_config_store_no_file_returns_defaults() {
        let dir = temp_dir();
        let store = FileConfigStore::new(dir.clone());
        let doc = store.load_all().unwrap();
        assert_eq!(doc.version, sa_monopoly_domain::config::CURRENT_CONFIG_VERSION);
        assert!(doc.sections.is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_file_config_store_roundtrip() {
        let dir = temp_dir();
        let store = FileConfigStore::new(dir.clone());

        // Save a config with an "app" section.
        let mut doc = ConfigDocument::current();
        doc.sections.insert(
            "app".to_string(),
            serde_json::to_value(AppConfig {
                language: "zh-Hans".to_string(),
                ..Default::default()
            })
            .unwrap(),
        );
        store.save_all(&doc).unwrap();

        // Load it back from a fresh store.
        let store2 = FileConfigStore::new(dir.clone());
        let loaded: AppConfig = store2.load_section("app").unwrap();
        assert_eq!(loaded.language, "zh-Hans");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_in_memory_config_store() {
        let store = InMemoryConfigStore::new();
        let doc = store.load_all().unwrap();
        assert_eq!(doc.version, sa_monopoly_domain::config::CURRENT_CONFIG_VERSION);
    }

    #[test]
    fn test_in_memory_save_and_reload() {
        let store = InMemoryConfigStore::new();
        let app = AppConfig {
            language: "ru".to_string(),
            ..Default::default()
        };
        store.save_section("app", &app).unwrap();
        let loaded: AppConfig = store.load_section("app").unwrap();
        assert_eq!(loaded.language, "ru");
    }

    /// Helper: create a unique temporary directory.
    fn temp_dir() -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("samonopoly_config_test_{}", std::process::id()));
        let _ = fs::create_dir_all(&p);
        p
    }
}
