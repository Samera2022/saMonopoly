use serde::{Deserialize, Serialize};

use crate::property::PropertyKind;
use crate::types::TileId;

pub type TileTypeId = String;

pub mod tile_types {
    pub const START: &str = "core:start";
    pub const ORDINARY_PROPERTY: &str = "core:ordinary_property";
    pub const SPECIAL_PROPERTY: &str = "core:special_property";
    pub const EXTENSION_PROPERTY: &str = "core:extension_property";
    pub const CHANCE: &str = "core:chance";
    pub const CARD_SHOP: &str = "core:card_shop";
    pub const LOTTERY: &str = "core:lottery";
    pub const BANK: &str = "core:bank";
    pub const JAIL: &str = "core:jail";
    pub const HOSPITAL: &str = "core:hospital";
    pub const GO_TO_JAIL: &str = "core:go_to_jail";
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tile {
    pub id: TileId,
    pub name_key: String,
    pub kind: TileTypeId,
    pub linked_property_kind: Option<PropertyKind>,
}
