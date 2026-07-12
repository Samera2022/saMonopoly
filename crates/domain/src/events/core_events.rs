use crate::event::GameEvent;
use crate::events::event_data::{CardData, PropertyData};
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

// ---------------------------------------------------------------------------
// 22 new typed event structs (PropertyData / CardData variants)
// ---------------------------------------------------------------------------

/// 1. 地产购买
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PropertyBoughtEvent {
    pub player_id: String,
    pub property: PropertyData,
}

impl GameEvent for PropertyBoughtEvent {
    fn event_type(&self) -> &'static str {
        "core:property_bought_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 2. 地产升级
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PropertyUpgradedEvent {
    pub player_id: String,
    pub property: PropertyData,
}

impl GameEvent for PropertyUpgradedEvent {
    fn event_type(&self) -> &'static str {
        "core:property_upgraded_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 3. 走到他人地产
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LandedOnOwnedProperty {
    pub from_player_id: String,
    pub to_player_id: String,
    pub property: PropertyData,
    pub amount: i64,
}

impl GameEvent for LandedOnOwnedProperty {
    fn event_type(&self) -> &'static str {
        "core:landed_on_owned_property"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 4. 走到特殊地产
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LandedOnSpecialProperty {
    pub player_id: String,
    pub property: PropertyData,
}

impl GameEvent for LandedOnSpecialProperty {
    fn event_type(&self) -> &'static str {
        "core:landed_on_special_property"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 5. 投骰子开始
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiceRollStarted {
    pub player_id: String,
}

impl GameEvent for DiceRollStarted {
    fn event_type(&self) -> &'static str {
        "core:dice_roll_started"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 6. 棋子移动开始
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MovementStarted {
    pub player_id: String,
    pub steps: u64,
}

impl GameEvent for MovementStarted {
    fn event_type(&self) -> &'static str {
        "core:movement_started"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 7. 投骰子结束
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiceRollEnded {
    pub player_id: String,
    pub dice1: u64,
    pub dice2: u64,
    pub is_seven: bool,
    pub consecutive: u32,
}

impl GameEvent for DiceRollEnded {
    fn event_type(&self) -> &'static str {
        "core:dice_roll_ended"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 8. 棋子移动结束
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MovementEnded {
    pub player_id: String,
    pub steps: u64,
}

impl GameEvent for MovementEnded {
    fn event_type(&self) -> &'static str {
        "core:movement_ended"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 9. 玩家回合开始
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerTurnStarted {
    pub player_id: String,
}

impl GameEvent for PlayerTurnStarted {
    fn event_type(&self) -> &'static str {
        "core:player_turn_started"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 10. 玩家回合结束
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerTurnEnded {
    pub player_id: String,
}

impl GameEvent for PlayerTurnEnded {
    fn event_type(&self) -> &'static str {
        "core:player_turn_ended"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 11. 彩票开奖
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LotteryDrawEvent {
    pub prize_amount: i64,
    pub winner_id: Option<String>,
}

impl GameEvent for LotteryDrawEvent {
    fn event_type(&self) -> &'static str {
        "core:lottery_draw"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 12. 彩票被购买
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LotteryTicketBoughtEvent {
    pub player_id: String,
    pub number: u64,
}

impl GameEvent for LotteryTicketBoughtEvent {
    fn event_type(&self) -> &'static str {
        "core:lottery_ticket_bought_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 13. 玩家进监狱
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerSentToJailEvent {
    pub player_id: String,
    pub turns: u32,
}

impl GameEvent for PlayerSentToJailEvent {
    fn event_type(&self) -> &'static str {
        "core:player_sent_to_jail_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 14. 玩家使用保释金
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerPaidBailEvent {
    pub player_id: String,
    pub amount: i64,
}

impl GameEvent for PlayerPaidBailEvent {
    fn event_type(&self) -> &'static str {
        "core:player_paid_bail"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 15. 玩家离开监狱
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerLeftJailEvent {
    pub player_id: String,
}

impl GameEvent for PlayerLeftJailEvent {
    fn event_type(&self) -> &'static str {
        "core:player_left_jail"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 16. 玩家进医院
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerSentToHospitalEvent {
    pub player_id: String,
    pub turns: u32,
}

impl GameEvent for PlayerSentToHospitalEvent {
    fn event_type(&self) -> &'static str {
        "core:player_sent_to_hospital"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 17. 玩家出医院
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerLeftHospitalEvent {
    pub player_id: String,
}

impl GameEvent for PlayerLeftHospitalEvent {
    fn event_type(&self) -> &'static str {
        "core:player_left_hospital"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 18. 玩家破产
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerBankruptEvent {
    pub player_id: String,
}

impl GameEvent for PlayerBankruptEvent {
    fn event_type(&self) -> &'static str {
        "core:player_bankrupt_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 19. 玩家胜利
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerWonEvent {
    pub player_id: String,
}

impl GameEvent for PlayerWonEvent {
    fn event_type(&self) -> &'static str {
        "core:player_won"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 20. 玩家使用卡牌
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CardUsedEvent {
    pub player_id: String,
    pub card: CardData,
    pub target: Option<String>,
}

impl GameEvent for CardUsedEvent {
    fn event_type(&self) -> &'static str {
        "core:card_used_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 21. 玩家发起交易
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TradeProposedEvent {
    pub from_player_id: String,
    pub to_player_id: String,
}

impl GameEvent for TradeProposedEvent {
    fn event_type(&self) -> &'static str {
        "core:trade_proposed_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// 22. 玩家发起拍卖
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuctionStartedEvent {
    pub initiator_id: String,
    pub tile_id: String,
}

impl GameEvent for AuctionStartedEvent {
    fn event_type(&self) -> &'static str {
        "core:auction_started_event"
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

// ---------------------------------------------------------------------------
// Mortage / Redeem typed events
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PropertyMortgaged {
    pub player_id: String,
    pub tile_id: String,
    pub amount: i64,
}

impl GameEvent for PropertyMortgaged {
    fn event_type(&self) -> &'static str {
        "core:property_mortgaged"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PropertyRedeemed {
    pub player_id: String,
    pub tile_id: String,
    pub amount: i64,
}

impl GameEvent for PropertyRedeemed {
    fn event_type(&self) -> &'static str {
        "core:property_redeemed"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

// ---------------------------------------------------------------------------
// Shares sold typed event
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SellSharesExecuted {
    pub player_id: String,
    pub shares: u32,
    pub total_price: i64,
}

impl GameEvent for SellSharesExecuted {
    fn event_type(&self) -> &'static str {
        "core:shares_sold_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

// ---------------------------------------------------------------------------
// Card bought typed event
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CardBoughtEvent {
    pub player_id: String,
    pub card_id: String,
    pub price: i64,
}

impl GameEvent for CardBoughtEvent {
    fn event_type(&self) -> &'static str {
        "core:card_bought_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

// ---------------------------------------------------------------------------
// EndTurnEvent — published by handle_end_turn after validation,
// handled by GameLogicHandler to execute turn-advance logic.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EndTurnEvent {
    pub player_id: String,
}

impl GameEvent for EndTurnEvent {
    fn event_type(&self) -> &'static str {
        "core:end_turn_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

// ---------------------------------------------------------------------------
// Income/luxury tax, free parking, bank bonus, chance card drawn, jail/hospital visit events
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IncomeTaxPaid {
    pub player_id: String,
    pub amount: i64,
}

impl GameEvent for IncomeTaxPaid {
    fn event_type(&self) -> &'static str {
        "core:income_tax_paid_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LuxuryTaxPaid {
    pub player_id: String,
    pub amount: i64,
}

impl GameEvent for LuxuryTaxPaid {
    fn event_type(&self) -> &'static str {
        "core:luxury_tax_paid_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FreeParkingBonus {
    pub player_id: String,
    pub amount: i64,
}

impl GameEvent for FreeParkingBonus {
    fn event_type(&self) -> &'static str {
        "core:free_parking_bonus_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BankBonus {
    pub player_id: String,
    pub amount: i64,
}

impl GameEvent for BankBonus {
    fn event_type(&self) -> &'static str {
        "core:bank_bonus_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChanceCardDrawn {
    pub player_id: String,
    pub card_id: String,
    pub effect_key: String,
}

impl GameEvent for ChanceCardDrawn {
    fn event_type(&self) -> &'static str {
        "core:chance_card_drawn_event"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerVisitedJail {
    pub player_id: String,
}

impl GameEvent for PlayerVisitedJail {
    fn event_type(&self) -> &'static str {
        "core:player_visited_jail"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerVisitedHospital {
    pub player_id: String,
}

impl GameEvent for PlayerVisitedHospital {
    fn event_type(&self) -> &'static str {
        "core:player_visited_hospital"
    }

    fn source(&self) -> &str {
        "core"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}
