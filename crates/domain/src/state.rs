use serde::{Deserialize, Serialize};

use crate::board::Board;
use crate::card::CardDeck;
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
}

impl GameState {
    pub fn active_player(&self) -> Option<&Player> {
        self.players.get(self.active_player_index)
    }

    pub fn active_player_mut(&mut self) -> Option<&mut Player> {
        self.players.get_mut(self.active_player_index)
    }
}
