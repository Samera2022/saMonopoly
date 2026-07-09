use sa_monopoly_domain::{CardDeck, CardDeckId, GameState};

use crate::event_bus::AnyEvent;

fn make_event(event_type: &str, payload: serde_json::Value) -> AnyEvent {
    AnyEvent::new(event_type, "core", payload)
}

pub struct CardService;

impl CardService {
    /// Draw a card from the specified deck, shuffling on first access.
    ///
    /// Returns an event if a card was drawn, or `None` if the deck is empty or not found.
    pub fn draw_card(
        state: &mut GameState,
        deck_id: &CardDeckId,
        rng: &mut dyn crate::ports::RngService,
    ) -> Option<AnyEvent> {
        let player_id = state
            .active_player()
            .map(|p| p.id.clone())
            .unwrap_or_default();

        let deck = state.decks.iter_mut().find(|d: &&mut CardDeck| d.id == deck_id.0)?;

        // Shuffle before first draw to randomize card order
        let mut rng_fn = || rng.next_u64();
        deck.shuffle(&mut rng_fn);

        let card = deck.draw()?;

        Some(make_event(
            "core:card_drawn",
            serde_json::json!({
                "player_id": player_id,
                "card_id": card.id,
                "deck_id": deck_id.0,
                "effect_key": card.effect_key,
            }),
        ))
    }
}

pub struct LotteryService;

impl LotteryService {
    /// Initialize the lottery if not yet active.
    /// Called on first landing on a Lottery tile or at game start.
    pub fn ensure_initialized(state: &mut GameState) {
        if state.lottery_state.is_none() {
            state.lottery_state = Some(sa_monopoly_domain::LotteryState::new(state.current_turn));
        }
    }

    /// Player buys a lottery ticket: chooses a number (1-50) and pays the
    /// ticket price.  The money goes to the "house" (removed from circulation).
    pub fn buy_ticket(
        state: &mut GameState,
        number: u32,
    ) -> Result<AnyEvent, String> {
        Self::ensure_initialized(state);

        if number < 1 || number > 50 {
            return Err("lottery number must be between 1 and 50".to_string());
        }

        let player_id = state
            .active_player()
            .map(|p| p.id.clone())
            .ok_or("no_active_player".to_string())?;

        let lottery = state.lottery_state.as_mut().unwrap();
        let ticket_price = sa_monopoly_domain::LotteryState::ticket_price_for_turn(state.current_turn);

        // Check if player already picked a number this cycle
        if lottery.player_numbers.contains_key(&player_id) {
            return Err("player already picked a number this cycle".to_string());
        }

        // Check affordability
        let can_afford = state
            .players
            .iter()
            .any(|p| p.id == player_id && p.cash >= ticket_price);
        if !can_afford {
            return Err("insufficient_funds".to_string());
        }

        // Deduct ticket price (goes to house)
        if let Some(player) = state.players.iter_mut().find(|p| p.id == player_id) {
            player.cash -= ticket_price;
        }

        // Record the player's number choice
        lottery.player_numbers.insert(player_id.clone(), number);

        Ok(make_event(
            "core:lottery_ticket_bought",
            serde_json::json!({
                "player_id": player_id,
                "number": number,
                "ticket_price": ticket_price,
            }),
        ))
    }

    /// Execute a lottery draw: pick a random winning number, check all
    /// players, and award the jackpot if there's a winner.
    pub fn execute_draw(
        state: &mut GameState,
        rng: &mut dyn crate::ports::RngService,
    ) -> AnyEvent {
        Self::ensure_initialized(state);

        let lottery = state.lottery_state.as_mut().unwrap();
        let current_turn = state.current_turn;

        // Calculate current jackpot
        let jackpot = lottery.effective_jackpot(current_turn);
        lottery.jackpot = jackpot;

        // Generate winning number (1-50)
        let winning_number = ((rng.next_u64() % 50) + 1) as u32;

        // Check if any player chose the winning number
        let winner_id = lottery
            .player_numbers
            .iter()
            .find(|(_, &num)| num == winning_number)
            .map(|(pid, _)| pid.clone());

        if let Some(ref winner) = winner_id {
            // Someone won! Award the jackpot
            if let Some(player) = state.players.iter_mut().find(|p| p.id == *winner) {
                player.cash += jackpot;
            }
            // Reset everything for the next cycle
            lottery.player_numbers.clear();
            lottery.consecutive_no_winner = 0;
            lottery.last_winning_number = Some(winning_number);
            lottery.last_winner = winner_id.clone();
            lottery.draw_pending = false;
            // Schedule next draw
            lottery.next_draw_turn = current_turn + 15;

            make_event(
                "core:lottery_draw_result",
                serde_json::json!({
                    "winning_number": winning_number,
                    "winner": winner_id.clone().unwrap(),
                    "prize": jackpot,
                }),
            )
        } else {
            // No winner: rollover with exponential growth
            lottery.consecutive_no_winner += 1;
            lottery.last_winning_number = Some(winning_number);
            lottery.last_winner = None;
            lottery.draw_pending = false;
            // Schedule next draw
            lottery.next_draw_turn = current_turn + 15;

            make_event(
                "core:lottery_draw_result",
                serde_json::json!({
                    "winning_number": winning_number,
                    "winner": null,
                    "prize": 0,
                }),
            )
        }
    }
}

pub struct StockMarketService;

impl StockMarketService {
    /// Simulate a market tick (price movement)
    pub fn tick(
        state: &mut GameState,
        rng: &mut dyn crate::ports::RngService,
    ) -> AnyEvent {
        if let Some(market) = &mut state.stock_market {
            let mut rng_fn = || rng.next_u64();
            market.tick(&mut rng_fn);
            make_event(
                "core:stock_market_tick",
                serde_json::json!({
                    "new_index": market.current_index,
                    "price": market.current_price(),
                }),
            )
        } else {
            make_event(
                "core:command_rejected",
                serde_json::json!({ "reason": "stock_market_disabled" }),
            )
        }
    }

    /// Buy shares at current market price
    pub fn buy_shares(
        state: &mut GameState,
        player_id: &str,
        shares: u32,
    ) -> AnyEvent {
        let market = match &state.stock_market {
            Some(m) => m,
            None => return make_event(
                "core:command_rejected",
                serde_json::json!({ "reason": "stock_market_disabled" }),
            ),
        };
        let price_per_share = market.current_price();
        let total_cost = price_per_share * shares as i64;

        let player = match state.players.iter_mut().find(|p| p.id == player_id) {
            Some(p) => p,
            None => return make_event(
                "core:command_rejected",
                serde_json::json!({ "reason": "player_not_found" }),
            ),
        };

        if player.cash < total_cost {
            return make_event(
                "core:command_rejected",
                serde_json::json!({ "reason": "insufficient_funds" }),
            );
        }

        player.cash -= total_cost;
        player.stock_shares += shares;

        make_event(
            "core:shares_bought",
            serde_json::json!({
                "player_id": player_id,
                "shares": shares,
                "total_cost": total_cost,
                "price_per_share": price_per_share,
            }),
        )
    }

    /// Sell shares at current market price
    pub fn sell_shares(
        state: &mut GameState,
        player_id: &str,
        shares: u32,
    ) -> AnyEvent {
        let market = match &state.stock_market {
            Some(m) => m,
            None => return make_event(
                "core:command_rejected",
                serde_json::json!({ "reason": "stock_market_disabled" }),
            ),
        };
        let price_per_share = market.current_price();
        let total_payout = price_per_share * shares as i64;

        let player = match state.players.iter_mut().find(|p| p.id == player_id) {
            Some(p) => p,
            None => return make_event(
                "core:command_rejected",
                serde_json::json!({ "reason": "player_not_found" }),
            ),
        };

        if player.stock_shares < shares {
            return make_event(
                "core:command_rejected",
                serde_json::json!({ "reason": "insufficient_shares" }),
            );
        }

        player.stock_shares -= shares;
        player.cash += total_payout;

        make_event(
            "core:shares_sold",
            serde_json::json!({
                "player_id": player_id,
                "shares": shares,
                "total_payout": total_payout,
                "price_per_share": price_per_share,
            }),
        )
    }

    /// Get the total value of a player's stock portfolio at the current price
    pub fn get_portfolio_value(state: &GameState, player_id: &str) -> i64 {
        let shares = state
            .players
            .iter()
            .find(|p| p.id == player_id)
            .map(|p| p.stock_shares)
            .unwrap_or(0);

        let current_price = state
            .stock_market
            .as_ref()
            .map(|m| m.current_price())
            .unwrap_or(0);

        shares as i64 * current_price
    }
}
