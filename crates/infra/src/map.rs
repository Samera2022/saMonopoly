use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MapDefinition {
    pub id: String,
    pub version: String,
    pub name_key: String,
    pub tiles: Vec<MapTile>,
    pub rules: MapRules,
    #[serde(default)]
    pub plugins: Vec<MapPluginRef>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MapTile {
    pub id: String,
    pub name_key: String,
    pub tile_type: TileType,
    pub attributes: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum TileType {
    Start,
    OrdinaryProperty,
    SpecialProperty,
    ExtensionProperty,
    Chance,
    CardShop,
    Lottery,
    Bank,
    Jail,
    Hospital,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MapRules {
    pub allow_custom_topology: bool,
    pub allow_stock_market: bool,
    pub allow_lottery: bool,
    pub allow_card_system: bool,
    /// When `true`, the engine will automatically compute linked-target
    /// groups for properties on the same board edge.
    /// Properties with manual `linked_targets` are skipped.
    #[serde(default)]
    pub auto_link_rent: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MapPluginRef {
    pub id: String,
    pub name: String,
    pub min_version: String,
    pub mandatory: bool,
    pub source: MapPluginSource,
    #[serde(skip)]
    pub bundled_data: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum MapPluginSource {
    Bundled,
    External,
}

pub trait MapValidator {
    fn validate(&self, map: &MapDefinition) -> Result<(), Vec<String>>;
}

pub struct BasicMapValidator;

impl MapValidator for BasicMapValidator {
    fn validate(&self, map: &MapDefinition) -> Result<(), Vec<String>> {
        let mut errors = Vec::new();
        if map.id.trim().is_empty() {
            errors.push("map.id must not be empty".to_string());
        }
        if map.version.trim().is_empty() {
            errors.push("map.version must not be empty".to_string());
        }
        if map.tiles.is_empty() {
            errors.push("map must contain at least one tile".to_string());
        }
        if map.tiles.iter().any(|tile| tile.id.trim().is_empty()) {
            errors.push("all tile ids must be set".to_string());
        }
        if map.tiles.iter().any(|tile| tile.name_key.trim().is_empty()) {
            errors.push("all tile name keys must be set".to_string());
        }
        if errors.is_empty() { Ok(()) } else { Err(errors) }
    }
}
