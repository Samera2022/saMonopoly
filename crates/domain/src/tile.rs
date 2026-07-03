use serde::{Deserialize, Serialize};

use crate::property::PropertyKind;
use crate::types::TileId;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TileKind {
    Start,
    OrdinaryProperty,
    SpecialProperty(SpecialTileKind),
    ExtensionProperty,
    Chance,
    CardShop,
    Lottery,
    Bank,
    Jail,
    Hospital,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SpecialTileKind {
    Opportunity,
    CardShop,
    Lottery,
    Bank,
    Jail,
    Hospital,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tile {
    pub id: TileId,
    pub name_key: String,
    pub kind: TileKind,
    pub linked_property_kind: Option<PropertyKind>,
}
