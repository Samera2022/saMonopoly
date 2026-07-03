use sa_monopoly_domain::{CardDeck, CardDeckId, GameState};

use crate::events::GameEvent;

pub struct CardService;

impl CardService {
    /// Draw a card from the specified deck, shuffling on first access.
    ///
    /// Returns `Some(GameEvent::CardDrawn)` if a card was drawn, or `None` if the deck
    /// is empty or not found.
    pub fn draw_card(
        state: &mut GameState,
        deck_id: &CardDeckId,
        rng: &mut dyn crate::ports::RngService,
    ) -> Option<GameEvent> {
        let player_id = state
            .active_player()
            .map(|p| p.id.clone())
            .unwrap_or_default();

        let deck = state.decks.iter_mut().find(|d: &&mut CardDeck| d.id == deck_id.0)?;

        // Shuffle before first draw to randomize card order
        let mut rng_fn = || rng.next_u64();
        deck.shuffle(&mut rng_fn);

        let card = deck.draw()?;

        Some(GameEvent::CardDrawn {
            player_id,
            card_id: card.id,
            deck_id: deck_id.0.clone(),
            effect_key: card.effect_key,
        })
    }
}

pub struct LotteryService;

impl LotteryService {
    /// Player buys a lottery ticket, pays the cost, and enters the draw.
    /// Returns the result event.
    pub fn buy_ticket(
        state: &mut GameState,
        rules: &sa_monopoly_domain::LotteryRuleSet,
        rng: &mut dyn crate::ports::RngService,
    ) -> GameEvent {
        if !rules.enabled {
            return GameEvent::CommandRejected { reason: "lottery_disabled".to_string() };
        }

        let player_id = match state.active_player().map(|p| p.id.clone()) {
            Some(id) => id,
            None => return GameEvent::CommandRejected { reason: "no_active_player".to_string() },
        };

        // Check if player can afford ticket
        let can_afford = state.players.iter().any(|p| p.id == player_id && p.cash >= rules.ticket_price);
        if !can_afford {
            return GameEvent::CommandRejected { reason: "insufficient_funds".to_string() };
        }

        // Deduct ticket price
        if let Some(player) = state.players.iter_mut().find(|p| p.id == player_id) {
            player.cash -= rules.ticket_price;
        }

        // Calculate prize: random 1..100, if <= 30 win something
        let roll = (rng.next_u64() % 100) + 1;
        let prize = if roll <= 30 {
            // Win: payout based on roll
            match roll {
                1..=5 => 1000,   // jackpot
                6..=15 => 500,    // big win
                _ => 100,         // small win
            }
        } else {
            0  // no win
        };

        // Pay out prize
        if prize > 0 {
            if let Some(player) = state.players.iter_mut().find(|p| p.id == player_id) {
                player.cash += prize;
            }
        }

        GameEvent::LotteryResult {
            player_id,
            ticket_price: rules.ticket_price,
            prize,
        }
    }
}

pub struct StockMarketService;

impl StockMarketService {
    /// Simulate a market tick (price movement)
    pub fn tick(
        state: &mut GameState,
        rng: &mut dyn crate::ports::RngService,
    ) -> GameEvent {
        if let Some(market) = &mut state.stock_market {
            let mut rng_fn = || rng.next_u64();
            market.tick(&mut rng_fn);
            GameEvent::StockMarketTick {
                new_index: market.current_index,
                price: market.current_price(),
            }
        } else {
            GameEvent::CommandRejected { reason: "stock_market_disabled".to_string() }
        }
    }

    /// Buy shares at current market price
    pub fn buy_shares(
        state: &mut GameState,
        player_id: &str,
        shares: u32,
    ) -> GameEvent {
        let market = match &state.stock_market {
            Some(m) => m,
            None => return GameEvent::CommandRejected { reason: "stock_market_disabled".to_string() },
        };
        let price_per_share = market.current_price();
        let total_cost = price_per_share * shares as i64;

        let player = match state.players.iter_mut().find(|p| p.id == player_id) {
            Some(p) => p,
            None => return GameEvent::CommandRejected { reason: "player_not_found".to_string() },
        };

        if player.cash < total_cost {
            return GameEvent::CommandRejected { reason: "insufficient_funds".to_string() };
        }

        player.cash -= total_cost;
        player.stock_shares += shares;

        GameEvent::SharesBought {
            player_id: player_id.to_string(),
            shares,
            total_cost,
            price_per_share,
        }
    }

    /// Sell shares at current market price
    pub fn sell_shares(
        state: &mut GameState,
        player_id: &str,
        shares: u32,
    ) -> GameEvent {
        let market = match &state.stock_market {
            Some(m) => m,
            None => return GameEvent::CommandRejected { reason: "stock_market_disabled".to_string() },
        };
        let price_per_share = market.current_price();
        let total_payout = price_per_share * shares as i64;

        let player = match state.players.iter_mut().find(|p| p.id == player_id) {
            Some(p) => p,
            None => return GameEvent::CommandRejected { reason: "player_not_found".to_string() },
        };

        if player.stock_shares < shares {
            return GameEvent::CommandRejected { reason: "insufficient_shares".to_string() };
        }

        player.stock_shares -= shares;
        player.cash += total_payout;

        GameEvent::SharesSold {
            player_id: player_id.to_string(),
            shares,
            total_payout,
            price_per_share,
        }
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
