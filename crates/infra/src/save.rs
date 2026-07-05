use serde::{Deserialize, Serialize};

use sa_monopoly_domain::GameState;

/// The current save format version used by the application.
/// Increment this when making breaking changes to the save format.
pub const CURRENT_SAVE_VERSION: u32 = 2;
/// The initial save format version.
pub const INITIAL_SAVE_VERSION: u32 = 1;

// ── Core Save Types ──────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SaveGame {
    /// Human-readable version tag (e.g. "0.2.0").
    pub version: String,
    pub state: GameState,
}

impl SaveGame {
    pub fn new(version: impl Into<String>, state: GameState) -> Self {
        Self {
            version: version.into(),
            state,
        }
    }
}

/// A versioned wrapper around save data, used to track numeric format
/// versions for migration purposes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VersionedSave {
    /// Numeric format version for migration chaining.
    pub version: u32,
    /// The raw JSON string of the actual save data at this version.
    pub data: String,
}

impl VersionedSave {
    pub fn new(version: u32, data: impl Into<String>) -> Self {
        Self {
            version,
            data: data.into(),
        }
    }
}

// ── Save Codec ───────────────────────────────────────────────────────────

pub trait SaveCodec {
    fn encode(&self, save: &SaveGame) -> Result<Vec<u8>, String>;
    fn decode(&self, bytes: &[u8]) -> Result<SaveGame, String>;
}

pub struct JsonSaveCodec;

impl SaveCodec for JsonSaveCodec {
    fn encode(&self, save: &SaveGame) -> Result<Vec<u8>, String> {
        serde_json::to_vec_pretty(save).map_err(|err| err.to_string())
    }

    fn decode(&self, bytes: &[u8]) -> Result<SaveGame, String> {
        serde_json::from_slice(bytes).map_err(|err| err.to_string())
    }
}

// ── VersionedSave Codec ──────────────────────────────────────────────────

pub trait VersionedSaveCodec {
    fn encode_versioned(&self, save: &VersionedSave) -> Result<Vec<u8>, String>;
    fn decode_versioned(&self, bytes: &[u8]) -> Result<VersionedSave, String>;
}

pub struct JsonVersionedSaveCodec;

impl VersionedSaveCodec for JsonVersionedSaveCodec {
    fn encode_versioned(&self, save: &VersionedSave) -> Result<Vec<u8>, String> {
        serde_json::to_vec_pretty(save).map_err(|err| err.to_string())
    }

    fn decode_versioned(&self, bytes: &[u8]) -> Result<VersionedSave, String> {
        serde_json::from_slice(bytes).map_err(|err| err.to_string())
    }
}

// ── Save Migration ───────────────────────────────────────────────────────

/// A single migration step that transforms save data from one version to the
/// next.
#[allow(clippy::wrong_self_convention)]
pub trait SaveMigration {
    /// The source version this migration applies to.
    fn from_version(&self) -> u32;
    /// The target version this migration produces.
    fn to_version(&self) -> u32;
    /// Transform the raw JSON data from `from_version` to `to_version`.
    fn migrate(&self, data: &str) -> Result<String, String>;
}

/// A chain of migrations that can be applied sequentially to bring save data
/// from an old version up to the current version.
pub struct MigrationChain {
    migrations: Vec<Box<dyn SaveMigration>>,
}

impl MigrationChain {
    pub fn new() -> Self {
        Self {
            migrations: Vec::new(),
        }
    }

    /// Register a migration step. Migrations should be added in ascending
    /// version order (e.g. v1→v2, v2→v3, ...).
    pub fn add(&mut self, migration: Box<dyn SaveMigration>) {
        self.migrations.push(migration);
    }

    /// Run all migrations whose `from_version` falls within
    /// `[from_version, to_version)`, chaining the output of each migration
    /// as input to the next.
    ///
    /// Returns the final transformed JSON string.
    pub fn migrate(&self, data: &str, from_version: u32, to_version: u32) -> Result<String, String> {
        let mut current = data.to_string();
        for m in &self.migrations {
            let fv = m.from_version();
            if fv >= from_version && fv < to_version {
                current = m.migrate(&current)?;
            }
        }
        Ok(current)
    }

    /// Convenience method: migrates from the given `from_version` all the way
    /// to [`CURRENT_SAVE_VERSION`].
    pub fn migrate_to_current(&self, data: &str, from_version: u32) -> Result<String, String> {
        self.migrate(data, from_version, CURRENT_SAVE_VERSION)
    }

    /// Returns the number of registered migrations.
    pub fn len(&self) -> usize {
        self.migrations.len()
    }

    pub fn is_empty(&self) -> bool {
        self.migrations.is_empty()
    }
}

impl Default for MigrationChain {
    fn default() -> Self {
        Self::new()
    }
}

// ── Concrete Migrations ──────────────────────────────────────────────────

/// Migration from v1 → v2.
///
/// In v1 the save format used a `version: String` field on `SaveGame`.
/// v2 introduced `VersionedSave` with a numeric version and stores the
/// inner state as a JSON string.
///
/// This migration wraps an existing v1 JSON save into a `VersionedSave`
/// envelope.
pub struct V1ToV2Migration;

impl SaveMigration for V1ToV2Migration {
    fn from_version(&self) -> u32 {
        1
    }

    fn to_version(&self) -> u32 {
        2
    }

    fn migrate(&self, data: &str) -> Result<String, String> {
        // Parse the old SaveGame to verify it is valid v1 data
        let legacy: SaveGame =
            serde_json::from_str(data).map_err(|e| format!("Failed to parse v1 save: {e}"))?;

        // Re-serialize the state as a JSON string for the VersionedSave
        let state_json =
            serde_json::to_string(&legacy.state)
                .map_err(|e| format!("Failed to serialize state: {e}"))?;

        let versioned = VersionedSave {
            version: 2,
            data: state_json,
        };

        serde_json::to_string_pretty(&versioned)
            .map_err(|e| format!("Failed to serialize v2 envelope: {e}"))
    }
}

/// Builds the default migration chain with all known migrations registered.
pub fn default_migration_chain() -> MigrationChain {
    let mut chain = MigrationChain::new();
    chain.add(Box::new(V1ToV2Migration));
    chain
}

#[cfg(test)]
mod tests {
    use super::*;
    use sa_monopoly_domain::board::{Board, BoardGraph};
    use sa_monopoly_domain::player::Player;
    use sa_monopoly_domain::rules::RuleSetRef;
    use sa_monopoly_domain::state::GameState;

    fn dummy_game_state() -> GameState {
        GameState {
            board: Board {
                tiles: vec![],
                properties: vec![],
                graph: BoardGraph::default(),
                auto_link_rent: false,
            },
            players: vec![Player {
                id: "p1".to_string(),
                name: "Alice".to_string(),
                cash: 1500,
                position: "GO".to_string(),
                is_ai: false,
                is_llm_controlled: false,
                jail_turns: 0,
                hospital_turns: 0,
                owned_cards: vec![],
                stock_shares: 0,
            }],
            ruleset: RuleSetRef {
                id: "classic".to_string(),
                version: "1.0".to_string(),
            },
            current_turn: 0,
            active_player_index: 0,
            seed: 42,
            decks: vec![],
            stock_market: None,
            active_auction: None,
            consecutive_doubles: 0,
            max_upgrade_level: 3,
            extension_upgrade_enabled: false,
            group_rent_enabled: false,
            lottery_state: None,
        }
    }

    // ── MigrationChain tests ──────────────────────────────────────────────

    #[test]
    fn test_empty_chain_passthrough() {
        let chain = MigrationChain::new();
        let data = r#"{"key":"value"}"#;
        let result = chain.migrate(data, 1, 2).unwrap();
        assert_eq!(result, data);
    }

    #[test]
    fn test_v1_to_v2_migration() {
        let state = dummy_game_state();
        let v1_save = SaveGame::new("0.1.0", state);
        let v1_json = serde_json::to_string_pretty(&v1_save).unwrap();

        let migration = V1ToV2Migration;
        assert_eq!(migration.from_version(), 1);
        assert_eq!(migration.to_version(), 2);

        let v2_json = migration.migrate(&v1_json).unwrap();
        let v2: VersionedSave = serde_json::from_str(&v2_json).unwrap();
        assert_eq!(v2.version, 2);

        // The inner data should deserialize back to a GameState
        let decoded_state: GameState = serde_json::from_str(&v2.data).unwrap();
        assert_eq!(decoded_state.seed, 42);
        assert_eq!(decoded_state.active_player_index, 0);
    }

    #[test]
    fn test_migration_chain_v1_to_current() {
        let state = dummy_game_state();
        let v1_save = SaveGame::new("0.1.0", state);
        let v1_json = serde_json::to_string_pretty(&v1_save).unwrap();

        let chain = default_migration_chain();
        assert_eq!(chain.len(), 1);

        let result = chain.migrate_to_current(&v1_json, 1).unwrap();
        let v2: VersionedSave = serde_json::from_str(&result).unwrap();
        assert_eq!(v2.version, CURRENT_SAVE_VERSION);
    }

    #[test]
    fn test_invalid_v1_data_returns_err() {
        let migration = V1ToV2Migration;
        let result = migration.migrate("not valid json");
        assert!(result.is_err());
    }

    // ── VersionedSaveCodec tests ──────────────────────────────────────────

    #[test]
    fn test_versioned_save_codec_roundtrip() {
        let original = VersionedSave {
            version: 2,
            data: r#"{"foo":"bar"}"#.to_string(),
        };
        let codec = JsonVersionedSaveCodec;

        let encoded = codec.encode_versioned(&original).unwrap();
        let decoded = codec.decode_versioned(&encoded).unwrap();

        assert_eq!(decoded.version, original.version);
        assert_eq!(decoded.data, original.data);
    }

    // ── Backward compat: SaveCodec still works ───────────────────────────

    #[test]
    fn test_json_save_codec_roundtrip() {
        let state = dummy_game_state();
        let original = SaveGame::new("0.2.0", state);
        let codec = JsonSaveCodec;

        let encoded = codec.encode(&original).unwrap();
        let decoded = codec.decode(&encoded).unwrap();

        assert_eq!(decoded.version, original.version);
        assert_eq!(decoded.state.seed, original.state.seed);
    }
}
