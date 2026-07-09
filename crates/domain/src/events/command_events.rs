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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PayBailCommand {
    pub player_id: String,
}

impl GameEvent for PayBailCommand {
    fn event_type(&self) -> &'static str {
        "core:command:pay_bail"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BuyCardCommand {
    pub player_id: String,
    pub card_id: String,
    pub price: i64,
}

impl GameEvent for BuyCardCommand {
    fn event_type(&self) -> &'static str {
        "core:command:buy_card"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UseCardCommand {
    pub player_id: String,
    pub card_id: String,
}

impl GameEvent for UseCardCommand {
    fn event_type(&self) -> &'static str {
        "core:command:use_card"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BuyLotteryTicketCommand {
    pub player_id: String,
    pub number: u32,
}

impl GameEvent for BuyLotteryTicketCommand {
    fn event_type(&self) -> &'static str {
        "core:command:buy_lottery_ticket"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MortgageCommand {
    pub player_id: String,
    pub tile_id: String,
}

impl GameEvent for MortgageCommand {
    fn event_type(&self) -> &'static str {
        "core:command:mortgage"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RedeemCommand {
    pub player_id: String,
    pub tile_id: String,
}

impl GameEvent for RedeemCommand {
    fn event_type(&self) -> &'static str {
        "core:command:redeem"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuctionCommand {
    pub player_id: String,
    pub tile_id: String,
    pub starting_bid: i64,
}

impl GameEvent for AuctionCommand {
    fn event_type(&self) -> &'static str {
        "core:command:auction"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BidCommand {
    pub player_id: String,
    pub amount: i64,
}

impl GameEvent for BidCommand {
    fn event_type(&self) -> &'static str {
        "core:command:bid"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TradeCommand {
    pub from_player_id: String,
    pub to_player_id: String,
}

impl GameEvent for TradeCommand {
    fn event_type(&self) -> &'static str {
        "core:command:trade"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SellSharesCommand {
    pub player_id: String,
    pub shares: u32,
}

impl GameEvent for SellSharesCommand {
    fn event_type(&self) -> &'static str {
        "core:command:sell_shares"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigGetCommand {
    pub key: String,
}

impl GameEvent for ConfigGetCommand {
    fn event_type(&self) -> &'static str {
        "core:command:config_get"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigSetCommand {
    pub key: String,
    pub value: serde_json::Value,
}

impl GameEvent for ConfigSetCommand {
    fn event_type(&self) -> &'static str {
        "core:command:config_set"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}
