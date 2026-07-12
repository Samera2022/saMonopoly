use serde::{Deserialize, Serialize};
use crate::card::Card;
use crate::property::{Property, PropertyKind};

/// 地产数据快照 — 事件中携带的地产全量信息
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PropertyData {
    pub tile_id: String,
    pub kind: PropertyKind,
    pub base_price: i64,
    pub owner: Option<String>,
    pub upgrade_level: u32,
    pub linked_targets: Vec<String>,
}

impl From<&Property> for PropertyData {
    fn from(p: &Property) -> Self {
        PropertyData {
            tile_id: p.tile_id.clone(),
            kind: p.kind.clone(),
            base_price: p.base_price,
            owner: p.owner.clone(),
            upgrade_level: p.upgrade_level,
            linked_targets: p.linked_targets.clone(),
        }
    }
}

/// 卡牌数据快照
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CardData {
    pub id: String,
    pub name_key: String,
    pub effect_key: String,
}

impl From<&Card> for CardData {
    fn from(c: &Card) -> Self {
        CardData {
            id: c.id.clone(),
            name_key: c.name_key.clone(),
            effect_key: c.effect_key.clone(),
        }
    }
}

/// 玩家简略信息
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlayerInfo {
    pub id: String,
    pub name: String,
    pub cash: i64,
}

/// 骰子结果
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiceResult {
    pub dice1: u64,
    pub dice2: u64,
    pub is_seven: bool,
    pub consecutive: u32,
}
