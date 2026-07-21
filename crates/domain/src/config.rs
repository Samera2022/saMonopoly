use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// Current configuration document format version.
pub const CURRENT_CONFIG_VERSION: u32 = 1;

// ── Config Document ─────────────────────────────────────────────────────────

/// The top-level persisted configuration document.
///
/// Uses an extensible sections map so new configuration categories can be added
/// without breaking backwards compatibility.  Each section is stored as a raw
/// JSON value and deserialized on demand.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigDocument {
    /// Numeric format version (for migration chaining).
    pub version: u32,
    /// Named configuration sections (e.g. "app", "game", "network", "ai", "content").
    pub sections: HashMap<String, serde_json::Value>,
}

impl Default for ConfigDocument {
    fn default() -> Self {
        Self::current()
    }
}

impl ConfigDocument {
    /// Create a new `ConfigDocument` at the current version with the given sections.
    pub fn new(sections: HashMap<String, serde_json::Value>) -> Self {
        Self {
            version: CURRENT_CONFIG_VERSION,
            sections,
        }
    }

    /// Create an empty `ConfigDocument` at the current version.
    pub fn current() -> Self {
        Self {
            version: CURRENT_CONFIG_VERSION,
            sections: HashMap::new(),
        }
    }
}

// ── App Configuration ───────────────────────────────────────────────────────

/// Application-level configuration (UI preferences, language, etc.).
///
/// Persisted across game sessions.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    /// UI language code (e.g. "en", "zh-Hans", "ru").
    pub language: String,
    /// Colour theme ("light", "dark", "system").
    pub theme: String,
    /// Whether sound effects are enabled.
    pub sound_enabled: bool,
    /// Board animation speed multiplier (0.5 = half speed, 2.0 = double speed).
    pub animation_speed: f64,
    /// Camera zoom factor for the isometric board.
    pub board_camera_zoom: f64,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            language: "en".to_string(),
            theme: "system".to_string(),
            sound_enabled: true,
            animation_speed: 1.0,
            board_camera_zoom: 1.0,
        }
    }
}

// ── Game Configuration ──────────────────────────────────────────────────────

/// Game-rule configuration that controls a single session's parameters.
///
/// These values are typically set before a game starts and may be overridden
/// by the host player's preferences.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameConfig {
    /// Which built‑in rule set to use (e.g. "classic").
    pub ruleset_id: String,
    /// Starting cash for each player.
    pub starting_cash: i64,
    /// Maximum number of players (2–6).
    pub max_players: u32,
    /// Whether the stock market sub‑system is enabled.
    pub stock_market_enabled: bool,
    /// Whether the lottery sub‑system is enabled.
    pub lottery_enabled: bool,
    /// Cash awarded when passing the Start tile.
    pub pass_start_bonus: i64,
    /// Number of turns a player must wait in jail before being released.
    pub jail_escape_turns: u32,
    /// Number of turns a player must wait in hospital before recovering.
    pub hospital_recovery_turns: u32,
    /// Whether property auctions are allowed.
    pub auction_enabled: bool,
    /// Whether property mortgaging is allowed.
    pub mortgage_enabled: bool,
    /// Whether player‑to‑player trading is allowed.
    pub trade_enabled: bool,
    /// Maximum property upgrade level (0 = upgrades disabled).
    /// Rent and upgrade cost are calculated by formula based on this level.
    pub max_upgrade_level: u64,
    /// Whether Extension properties (utilities: Electric Co, Water Works)
    /// can also be upgraded.  When true, they follow the same formula-based
    /// upgrade cost and rent calculation as Ordinary properties.
    pub extension_upgrade_enabled: bool,
    /// Whether group rent is enabled.  When enabled, if all properties in a
    /// linked group are owned by the same player, rent is the sum of all
    /// group members' individual rent.
    pub group_rent_enabled: bool,
}

impl Default for GameConfig {
    fn default() -> Self {
        Self {
            ruleset_id: "classic".to_string(),
            starting_cash: 1500,
            max_players: 4,
            stock_market_enabled: false,
            lottery_enabled: false,
            pass_start_bonus: 200,
            jail_escape_turns: 3,
            hospital_recovery_turns: 2,
            auction_enabled: true,
            mortgage_enabled: true,
            trade_enabled: true,
            max_upgrade_level: 3,
            extension_upgrade_enabled: false,
            group_rent_enabled: false,
        }
    }
}

// ── AI Configuration ────────────────────────────────────────────────────────

/// The kind of AI agent used to control a non‑human player.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AiAgentKind {
    /// Simple heuristic agent.
    Heuristic,
    /// Monte‑Carlo simulation agent.
    MonteCarlo {
        /// Number of random playouts per decision.
        simulations: u32,
    },
    /// LLM‑powered agent.
    Llm {
        /// Model identifier (e.g. "gpt-4", "claude-3").
        model: String,
        /// Placeholder for the API key — the real key is injected via
        /// environment variable `SA_MONOPOLY_LLM_API_KEY`.
        api_key_placeholder: String,
        /// Sampling temperature (0.0 – 2.0).
        temperature: f64,
    },
}

/// AI configuration that maps player IDs to their agent type.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiConfig {
    /// Per‑player agent assignment.
    /// Keys are player IDs; missing players fall back to `default_agent`.
    pub agent_map: HashMap<String, AiAgentKind>,
    /// The agent assigned to any player not explicitly listed in `agent_map`.
    pub default_agent: AiAgentKind,
}

impl Default for AiConfig {
    fn default() -> Self {
        Self {
            agent_map: HashMap::new(),
            default_agent: AiAgentKind::Heuristic,
        }
    }
}

// ── Network Configuration ───────────────────────────────────────────────────

/// Network / WebSocket configuration for online multiplayer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkConfig {
    /// Host to bind / connect to.
    pub host: String,
    /// Port number.
    pub port: u16,
    /// WebSocket path prefix.
    pub path: String,
    /// Whether TLS is enabled.
    pub tls: bool,
    /// Maximum message size in bytes.
    pub max_message_size: usize,
    /// Keep‑alive ping interval in seconds.
    pub ping_interval_secs: u64,
}

impl Default for NetworkConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_string(),
            port: 9000,
            path: "/ws".to_string(),
            tls: false,
            max_message_size: 256 * 1024,
            ping_interval_secs: 30,
        }
    }
}

// ── Content Configuration ───────────────────────────────────────────────────

/// Content / plugin configuration — which maps, packs, and plugins are enabled.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContentConfig {
    /// IDs of maps enabled for the next game session.
    pub enabled_maps: Vec<String>,
    /// IDs of content packs enabled for discovery.
    pub enabled_packs: Vec<String>,
    /// Additional filesystem paths to scan for custom content.
    pub custom_content_paths: Vec<String>,
}

impl Default for ContentConfig {
    fn default() -> Self {
        Self {
            enabled_maps: vec!["classic".to_string()],
            enabled_packs: vec!["classic_pack".to_string()],
            custom_content_paths: vec![],
        }
    }
}

// ── LLM API Configuration ─────────────────────────────────────────────────

/// LLM API connection settings for AI players.
///
/// Persisted as the "llm_api" section in the config document.
///
/// SECURITY: `api_key` is written to the on-disk config file in plaintext by
/// default. Prefer an `env:VAR_NAME` reference (resolved at request time by the
/// LLM backend) so the raw secret never touches disk. A future improvement is
/// to store secrets in a platform credential store.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmApiConfig {
    /// Backend type: "direct" or "a2cm".
    #[serde(default = "default_llm_backend")]
    pub backend: String,
    /// API endpoint URL (e.g. "https://api.openai.com/v1/chat/completions").
    pub api_endpoint: String,
    /// A2CM companion endpoint.
    #[serde(default = "default_a2cm_endpoint")]
    pub a2cm_endpoint: String,
    /// API key for authentication.
    pub api_key: String,
    /// Model identifier (e.g. "gpt-4", "gpt-4-turbo", "claude-3-opus").
    pub model: String,
    /// Sampling temperature (0.0 – 2.0). Lower = more deterministic.
    pub temperature: f64,
    /// Maximum tokens in the response.
    pub max_tokens: u32,
    /// Custom HTTP headers as JSON object (e.g. {"X-Custom-Header": "value"}).
    #[serde(default)]
    pub custom_headers: String,
}

impl Default for LlmApiConfig {
    fn default() -> Self {
        Self {
            backend: default_llm_backend(),
            api_endpoint: "https://api.openai.com/v1/chat/completions".to_string(),
            a2cm_endpoint: default_a2cm_endpoint(),
            api_key: String::new(),
            model: "gpt-4".to_string(),
            temperature: 0.7,
            max_tokens: 512,
            custom_headers: String::new(),
        }
    }
}

fn default_llm_backend() -> String {
    "direct".to_string()
}

fn default_a2cm_endpoint() -> String {
    "http://localhost:8000".to_string()
}

// ── Error ───────────────────────────────────────────────────────────────────

use thiserror::Error;

#[derive(Error, Debug, Clone, PartialEq)]
pub enum ConfigError {
    #[error("config deserialization failed: {0}")]
    Deserialize(String),

    #[error("config serialization failed: {0}")]
    Serialize(String),

    #[error("I/O error: {0}")]
    Io(String),

    #[error("migration failed: {0}")]
    Migration(String),

    #[error("validation error: {0}")]
    Validation(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_app_config_default() {
        let cfg = AppConfig::default();
        assert_eq!(cfg.language, "en");
        assert!(cfg.sound_enabled);
    }

    #[test]
    fn test_game_config_default() {
        let cfg = GameConfig::default();
        assert_eq!(cfg.starting_cash, 1500);
        assert_eq!(cfg.max_players, 4);
        assert_eq!(cfg.max_upgrade_level, 3);
    }

    #[test]
    fn test_config_document_current_version() {
        let doc = ConfigDocument::current();
        assert_eq!(doc.version, CURRENT_CONFIG_VERSION);
        assert!(doc.sections.is_empty());
    }

    #[test]
    fn test_config_document_roundtrip() {
        let mut sections = HashMap::new();
        sections.insert(
            "app".to_string(),
            serde_json::to_value(AppConfig::default()).unwrap(),
        );
        let doc = ConfigDocument::new(sections);

        let json = serde_json::to_string_pretty(&doc).unwrap();
        let restored: ConfigDocument = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.version, CURRENT_CONFIG_VERSION);

        let app: AppConfig =
            serde_json::from_value(restored.sections["app"].clone()).unwrap();
        assert_eq!(app.language, "en");
    }

    #[test]
    fn test_ai_agent_kind_serialize() {
        let mc = AiAgentKind::MonteCarlo { simulations: 1000 };
        let json = serde_json::to_string(&mc).unwrap();
        assert!(json.contains("MonteCarlo"));
        assert!(json.contains("1000"));

        let restored: AiAgentKind = serde_json::from_str(&json).unwrap();
        assert!(matches!(restored, AiAgentKind::MonteCarlo { simulations: 1000 }));
    }

    #[test]
    fn test_network_config_default() {
        let cfg = NetworkConfig::default();
        assert_eq!(cfg.host, "127.0.0.1");
        assert_eq!(cfg.port, 9000);
    }

    #[test]
    fn test_content_config_default() {
        let cfg = ContentConfig::default();
        assert_eq!(cfg.enabled_maps, vec!["classic"]);
    }

    #[test]
    fn test_config_error_deserialize() {
        let err = ConfigError::Deserialize("expected integer".to_string());
        assert_eq!(err.to_string(), "config deserialization failed: expected integer");
    }
}
