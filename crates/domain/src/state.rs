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
    /// Default number of jail turns when sent to jail.
    pub const BASE_JAIL_TURNS: u32 = 3;

    pub fn active_player(&self) -> Option<&Player> {
        self.players.get(self.active_player_index)
    }

    pub fn active_player_mut(&mut self) -> Option<&mut Player> {
        self.players.get_mut(self.active_player_index)
    }

    /// Send the active player to jail.
    /// Applies the bail-abuse penalty (+1 turn) if `bail_abuse_count > 0`,
    /// then resets the abuse counter (one-time penalty, not cumulative).
    /// Returns the actual number of jail turns set.
    pub fn send_active_player_to_jail(&mut self, jail_tile_id: &str) -> u32 {
        let extra = if self.bail_abuse_count > 0 { 1 } else { 0 };
        let turns = Self::BASE_JAIL_TURNS + extra;
        if let Some(player) = self.players.get_mut(self.active_player_index) {
            player.position = jail_tile_id.to_string();
            player.jail_turns = turns;
        }
        self.bail_abuse_count = 0;
        turns
    }

    /// Returns the `team_id` of the currently active player, if any.
    pub fn active_team(&self) -> Option<String> {
        self.players
            .get(self.active_player_index)
            .and_then(|p| p.team_id.clone())
    }

    /// Returns a vector of references to all players belonging to the given team.
    pub fn team_members(&self, team_id: &str) -> Vec<&Player> {
        self.players
            .iter()
            .filter(|p| p.team_id.as_deref() == Some(team_id))
            .collect()
    }

    /// Returns `true` if all members of the given team are bankrupt (`cash < 0`).
    /// If the team has no members, returns `false`.
    pub fn team_bankrupt(&self, team_id: &str) -> bool {
        let members: Vec<&Player> = self.team_members(team_id);
        if members.is_empty() {
            return false;
        }
        members.iter().all(|p| p.is_bankrupt())
    }

    /// Returns the IDs of all teams that have at least one non-bankrupt member.
    pub fn remaining_teams(&self) -> Vec<String> {
        let mut team_ids: Vec<String> = self
            .players
            .iter()
            .filter_map(|p| p.team_id.clone())
            .collect::<std::collections::HashSet<_>>()
            .into_iter()
            .collect();
        team_ids.retain(|tid| !self.team_bankrupt(tid));
        team_ids
    }
}
