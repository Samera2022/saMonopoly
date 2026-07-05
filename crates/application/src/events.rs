use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "event_type")]
pub enum GameEvent {
    GameStarted,
    CommandAccepted { name: String },
    CommandRejected { reason: String },
    TurnAdvanced {
        turn: u64,
        eliminated_players: Vec<String>,
    },
    PlayerMoved { player_id: String, to_tile: String },
    PropertyBought { player_id: String, tile_id: String },
    RentPaid { from_player_id: String, to_player_id: String, amount: i64 },
    StateSaved { key: String },
    StateLoaded { key: String },
    PlayerSentToJail { player_id: String, turns: u32 },
    PlayerSentToHospital { player_id: String, turns: u32 },
    PlayerReleasedFromJail { player_id: String },
    PlayerReleasedFromHospital { player_id: String },
    CardDrawn { player_id: String, card_id: String, deck_id: String, effect_key: String },
    CardEffectExecuted { player_id: String, effect_key: String, result: String },
    LotteryResult { player_id: String, ticket_price: i64, prize: i64 },
    StockMarketTick { new_index: i64, price: i64 },
    TradeCompleted { from_player_id: String, to_player_id: String },
    AuctionStarted { tile_id: String, starting_bid: i64 },
    AuctionBid { player_id: String, amount: i64 },
    AuctionWon { player_id: String, tile_id: String, amount: i64 },
    AuctionEnded { tile_id: String, final_price: i64 },
    PropertyMortgaged { player_id: String, tile_id: String, amount: i64 },
    PropertyRedeemed { player_id: String, tile_id: String, amount: i64 },
    // Sprint 4: Bankruptcy
    PlayerBankrupt { player_id: String },
    PlayerEliminated { player_id: String },
    // Sprint 4: Dice roll result
    DiceRolled { dice1: u64, dice2: u64, is_seven: bool, consecutive: u32 },
    ExtraTurn { player_id: String },
    ThreeDoublesToJail { player_id: String },
    // Sprint 6: Card Shop
    CardShopList { cards: Vec<String> },
    CardBought { player_id: String, card_id: String, price: i64 },
    CardConsumed { player_id: String, card_id: String },
    // Sprint 6: Stock Market
    SharesBought { player_id: String, shares: u32, total_cost: i64, price_per_share: i64 },
    SharesSold { player_id: String, shares: u32, total_payout: i64, price_per_share: i64 },
    // Sprint 7: Game End
    GameWon { winner_id: String, remaining_players: u32 },
    // Config
    ConfigLoaded { config: serde_json::Value },
    ConfigUpdated { section: String },
    // Lottery
    LotteryAvailable { ticket_price: i64, jackpot: i64, next_draw_turn: u64 },
    LotteryTicketBought { player_id: String, number: u32, ticket_price: i64 },
    LotteryDrawResult { winning_number: u32, winner: Option<String>, prize: i64 },
    // Card usage
    CardUsed { player_id: String, card_id: String },
    // Bail
    BailPaid { player_id: String, amount: i64 },
}

pub trait EventBus<E> {
    fn publish(&mut self, event: E);
}

#[derive(Default)]
pub struct VecEventBus<E> {
    pub events: Vec<E>,
}

impl<E> EventBus<E> for VecEventBus<E> {
    fn publish(&mut self, event: E) {
        self.events.push(event);
    }
}
