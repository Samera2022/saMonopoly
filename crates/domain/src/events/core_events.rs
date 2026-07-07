use crate::event::GameEvent;
use serde::{Deserialize, Serialize};
use std::any::Any;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiceRolled {
    pub dice1: u64,
    pub dice2: u64,
    pub is_seven: bool,
    pub consecutive: u32,
    pub player_id: String,
}

impl GameEvent for DiceRolled {
    fn event_type(&self) -> &'static str {
        "core:dice_rolled"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TurnAdvanced {
    pub turn: u64,
    pub eliminated_players: Vec<String>,
}

impl GameEvent for TurnAdvanced {
    fn event_type(&self) -> &'static str {
        "core:turn_advanced"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerMoved {
    pub player_id: String,
    pub to_tile: String,
}

impl GameEvent for PlayerMoved {
    fn event_type(&self) -> &'static str {
        "core:player_moved"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PropertyBought {
    pub player_id: String,
    pub tile_id: String,
    pub price: i64,
}

impl GameEvent for PropertyBought {
    fn event_type(&self) -> &'static str {
        "core:property_bought"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RentPaid {
    pub from_player_id: String,
    pub to_player_id: String,
    pub amount: i64,
}

impl GameEvent for RentPaid {
    fn event_type(&self) -> &'static str {
        "core:rent_paid"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandAccepted {
    pub name: String,
}

impl GameEvent for CommandAccepted {
    fn event_type(&self) -> &'static str {
        "core:command_accepted"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandRejected {
    pub reason: String,
}

impl GameEvent for CommandRejected {
    fn event_type(&self) -> &'static str {
        "core:command_rejected"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerBankrupt {
    pub player_id: String,
}

impl GameEvent for PlayerBankrupt {
    fn event_type(&self) -> &'static str {
        "core:player_bankrupt"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerEliminated {
    pub player_id: String,
}

impl GameEvent for PlayerEliminated {
    fn event_type(&self) -> &'static str {
        "core:player_eliminated"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameWon {
    pub winner_id: String,
    pub remaining_players: u32,
}

impl GameEvent for GameWon {
    fn event_type(&self) -> &'static str {
        "core:game_won"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CardConsumed {
    pub player_id: String,
    pub card_id: String,
}

impl GameEvent for CardConsumed {
    fn event_type(&self) -> &'static str {
        "core:card_consumed"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LandedOnTile {
    pub player_id: String,
    pub tile_id: String,
    pub tile_type: String,
}

impl GameEvent for LandedOnTile {
    fn event_type(&self) -> &'static str {
        "core:landed_on_tile"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}
