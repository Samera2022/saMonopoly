use std::collections::HashMap;
use serde::{Deserialize, Serialize};

// ============================================================================
// Map data types – moved from crates/infra/src/map.rs to break circular dep
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MapDefinition {
    pub id: String,
    pub version: String,
    pub name_key: String,
    pub tiles: Vec<MapTile>,
    pub rules: MapRules,
    #[serde(default)]
    pub plugins: Vec<MapPluginRef>,
    /// Property definitions: prices, color groups, preset owners.
    #[serde(default)]
    pub properties: Vec<MapPropertyDef>,
    /// Special tile configurations (tax, lottery, card shop, etc.).
    #[serde(default)]
    pub special_tiles: HashMap<String, MapSpecialTileDef>,
    /// Tile IDs that trigger a chance card draw.
    #[serde(default)]
    pub chance_tiles: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MapPropertyDef {
    pub tile_id: String,
    pub base_price: i64,
    #[serde(default)]
    pub color_group: String,
    /// Preset owner (e.g. "player_0"). None = unowned.
    #[serde(default)]
    pub owner: Option<String>,
    /// Linked property IDs for group rent.
    #[serde(default)]
    pub linked_targets: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum MapSpecialTileDef {
    #[serde(rename = "income_tax")]
    IncomeTax { amount: i64 },
    #[serde(rename = "luxury_tax")]
    LuxuryTax { amount: i64 },
    #[serde(rename = "free_parking")]
    FreeParking { amount: i64 },
    #[serde(rename = "go_to_jail")]
    GoToJail,
    #[serde(rename = "just_visiting")]
    JustVisiting,
    #[serde(rename = "lottery")]
    Lottery,
    #[serde(rename = "card_shop")]
    CardShop,
    #[serde(rename = "chance")]
    Chance,
    #[serde(rename = "reserved")]
    Reserved { description: String },
    /// Catch-all for unknown/legacy special tile kinds.
    #[serde(other)]
    Other,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MapTile {
    pub id: String,
    pub name_key: String,
    pub tile_type: TileType,
    #[serde(default)]
    pub attributes: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
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
