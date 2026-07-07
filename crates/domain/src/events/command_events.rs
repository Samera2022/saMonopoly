use crate::event::GameEvent;
use serde::{Deserialize, Serialize};
use std::any::Any;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RollCommand {
    pub player_id: String,
}

impl GameEvent for RollCommand {
    fn event_type(&self) -> &'static str {
        "core:command:roll"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BuyPropertyCommand {
    pub player_id: String,
    pub tile_id: String,
}

impl GameEvent for BuyPropertyCommand {
    fn event_type(&self) -> &'static str {
        "core:command:buy_property"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EndTurnCommand {
    pub player_id: String,
}

impl GameEvent for EndTurnCommand {
    fn event_type(&self) -> &'static str {
        "core:command:end_turn"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpgradePropertyCommand {
    pub player_id: String,
    pub tile_id: String,
}

impl GameEvent for UpgradePropertyCommand {
    fn event_type(&self) -> &'static str {
        "core:command:upgrade_property"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PayRentCommand {
    pub player_id: String,
    pub tile_id: String,
}

impl GameEvent for PayRentCommand {
    fn event_type(&self) -> &'static str {
        "core:command:pay_rent"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}
