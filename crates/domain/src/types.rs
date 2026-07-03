use serde::{Deserialize, Serialize};

pub type Money = i64;
pub type TurnNumber = u64;
pub type TileId = String;
pub type PlayerId = String;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Seed(pub u64);
