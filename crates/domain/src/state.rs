use serde::{Deserialize, Serialize};

use crate::board::Board;
use crate::card::CardDeck;
use crate::lottery::LotteryState;
use crate::market::StockMarketRule;
use crate::player::Player;
use crate::rules::RuleSetRef;
use crate::types::Money;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActiveAuction {
    pub tile_id: String,
    pub highest_bidder: Option<String>,
    pub highest_bid: Money,
    pub starting_bid: Money,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GameState {
    pub board: Board,
    pub players: Vec<Player>,
    pub ruleset: RuleSetRef,
    pub current_turn: u64,
    pub active_player_index: usize,
    pub seed: u64,
    pub decks: Vec<CardDeck>,
    pub stock_market: Option<StockMarketRule>,
    pub active_auction: Option<ActiveAuction>,
    pub consecutive_doubles: u32,
    /// Maximum property upgrade level (0 = upgrades disabled).
    /// Rent and upgrade cost are calculated by formula from the current level.
    pub max_upgrade_level: u64,
    /// Whether Extension properties (utilities) can be upgraded.
    pub extension_upgrade_enabled: bool,
    /// Whether group rent is enabled (sum of all linked group members' rent).
    pub group_rent_enabled: bool,
    /// State of the lottery sub-system (None = lottery not yet initialized).
    pub lottery_state: Option<LotteryState>,
    /// How many times the active player has used bail to get out of jail.
    /// Each use adds +1 to the next jail term.
    pub bail_abuse_count: u32,
}

impl GameState {
    pub fn active_player(&self) -> Option<&Player> {
        self.players.get(self.active_player_index)
    }

    pub fn active_player_mut(&mut self) -> Option<&mut Player> {
        self.players.get_mut(self.active_player_index)
    }
}
