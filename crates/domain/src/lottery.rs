use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// Represents the state of the lottery sub-system.
///
/// The lottery runs on a fixed 15-round cycle.  Players pick a number (1-50)
/// when they land on the Lottery tile.  At each draw, a random winning number
/// is generated.  If any player picked that number, they win the entire jackpot.
///
/// **Jackpot formula**:
///   `jackpot = (BASE_JACKPOT + current_turn * 10) * (1.5 ^ consecutive_no_winner)`
///
/// - `(BASE_JACKPOT + turn * 10)` — natural round-based growth across cycles.
/// - `(1.5 ^ consecutive_no_winner)` — exponential rollover within one cycle.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LotteryState {
    /// Current jackpot (recalculated on each draw).
    pub jackpot: i64,
    /// Ticket price paid by a player when they pick a number.
    pub ticket_price: i64,
    /// Each active player's chosen number (1-50).  Key = player_id.
    pub player_numbers: HashMap<String, u32>,
    /// Turn number of the next draw (every 15 turns).
    pub next_draw_turn: u64,
    /// Consecutive draws with no winner in the current cycle.
    pub consecutive_no_winner: u32,
    /// If `true`, a draw event has fired and is pending resolution.
    pub draw_pending: bool,
    /// The winning number from the most recent draw.
    pub last_winning_number: Option<u32>,
    /// The player who won the most recent draw, if any.
    pub last_winner: Option<String>,
}

impl LotteryState {
    /// Base jackpot before any multipliers.
    pub const BASE_JACKPOT: i64 = 500;
    /// Jackpot increment per turn.
    pub const JACKPOT_PER_TURN: i64 = 10;
    /// Base ticket price.
    pub const BASE_TICKET_PRICE: i64 = 50;

    /// Create a new `LotteryState` for the given turn.
    pub fn new(current_turn: u64) -> Self {
        let next_draw = ((current_turn / 15) + 1) * 15;
        Self {
            jackpot: Self::base_jackpot(current_turn),
            ticket_price: Self::BASE_TICKET_PRICE,
            player_numbers: HashMap::new(),
            next_draw_turn: next_draw.max(15),
            consecutive_no_winner: 0,
            draw_pending: false,
            last_winning_number: None,
            last_winner: None,
        }
    }

    /// Calculate the base jackpot for a given turn (before rollover multiplier).
    pub fn base_jackpot(turn: u64) -> i64 {
        Self::BASE_JACKPOT + (turn as i64) * Self::JACKPOT_PER_TURN
    }

    /// Calculate the current effective jackpot using the rollover multiplier.
    pub fn effective_jackpot(&self, current_turn: u64) -> i64 {
        let base = Self::base_jackpot(current_turn);
        let multiplier = 1.5_f64.powi(self.consecutive_no_winner as i32);
        (base as f64 * multiplier) as i64
    }

    /// Calculate the ticket price for a given turn.
    pub fn ticket_price_for_turn(turn: u64) -> i64 {
        Self::BASE_TICKET_PRICE + ((turn / 5) * 5) as i64
    }
}
