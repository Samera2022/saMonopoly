use sa_monopoly_domain::GameState;
use crate::event_bus::{AnyEvent, EventAction, EventSubscriber, SubscriberPriority};

/// Helper: extract a `&str` field from an event's JSON payload.
fn payload_str<'a>(payload: &'a serde_json::Value, key: &str) -> Option<&'a str> {
    payload.get(key).and_then(|v| v.as_str())
}

/// AI event subscriber — handles reactive decisions for AI-controlled players.
///
/// This subscriber listens for game events and makes automated decisions
/// (buy cards, pay bail, etc.) by directly mutating the game state.
/// It is registered alongside [`GameLogicHandler`] but kept in a separate
/// file to avoid mixing AI logic with core game logic.
///
/// For full‑turn execution (roll → move → end_turn) the bridge-level
/// `core:command:process_ai_turn` command is used instead.
///
/// ## Strategy
///
/// ### Jail
/// - **Early game** (cash > $1000 or < 3 properties owned): Pay bail immediately
///   to keep acquiring properties.
/// - **Late game** (≥3 properties owned): Stay in jail to avoid paying
///   opponent rent. Use get_out_of_jail card if available.
///
/// ### Card Shop
/// - Buy get_out_of_jail card (most valuable strategically)
/// - Buy double_rent card when we own properties
/// - Only buy bonus_200 when cash is low
///
/// ### Lottery
/// - Only buy ticket when cash > $500 (disposable income)
pub struct AiSubscriber;

impl AiSubscriber {
    /// Check whether the active player is AI-controlled.
    fn active_player_is_ai(state: &GameState) -> bool {
        state
            .active_player()
            .map(|p| p.is_ai || p.is_llm_controlled)
            .unwrap_or(false)
    }

    /// Count properties owned by this player.
    fn owned_property_count(state: &GameState, player_id: &str) -> usize {
        state.board.properties.iter()
            .filter(|p| p.owner.as_deref() == Some(player_id))
            .count()
    }

    /// The AI has landed on a Card Shop — pick the best card strategically.
    fn handle_card_shop_landed(state: &mut GameState, player_id: &str) {
        const CARDS: &[(&str, i64)] = &[
            ("get_out_of_jail", 150),
            ("double_rent", 200),
            ("bonus_200", 100),
        ];

        let player = match state.players.iter().find(|p| p.id == player_id) {
            Some(p) => p,
            None => return,
        };

        let cash = player.cash;
        let owned_count = Self::owned_property_count(state, player_id);

        // Score each card for strategic value
        fn card_score(card_id: &str, cash: i64, owned_count: usize) -> i64 {
            match card_id {
                // get_out_of_jail: most valuable — saves $50/turn in jail
                "get_out_of_jail" => {
                    if cash >= 150 { 100 } else { 30 }
                }
                // double_rent: valuable when we own properties to collect from
                "double_rent" => {
                    if owned_count >= 2 { 80 + (owned_count as i64) * 5 }
                    else { 20 }
                }
                // bonus_200: instant cash, good when low on funds
                "bonus_200" => {
                    if cash < 300 { 70 }
                    else if cash < 500 { 50 }
                    else { 10 }
                }
                _ => 0,
            }
        }

        // Pick the card with the highest score that we can afford
        let mut best_card: Option<(&str, i64)> = None;
        for (card_id, price) in CARDS {
            if cash >= *price {
                let score = card_score(card_id, cash, owned_count);
                if best_card.map_or(true, |(_, best)| score > best) {
                    best_card = Some((card_id, *price));
                }
            }
        }

        if let Some((card_id, price)) = best_card {
            if let Some(player) = state.players.iter_mut().find(|p| p.id == player_id) {
                player.cash -= price;
                player.owned_cards.push(card_id.to_string());
                state.publish_custom_event(
                    "core:card_bought",
                    "ai",
                    serde_json::json!({
                        "player_id": player_id,
                        "card_id": card_id,
                        "price": price,
                    }),
                );
            }
        }
    }

    /// The AI has landed on a Lottery — buy a ticket only when cash is plentiful.
    fn handle_lottery_landed(state: &mut GameState, player_id: &str) {
        let ticket_price = state
            .lottery_state
            .as_ref()
            .map(|ls| ls.ticket_price)
            .unwrap_or(50);

        let cash = state.players.iter()
            .find(|p| p.id == player_id)
            .map(|p| p.cash)
            .unwrap_or(0);

        // Only buy lottery when we have plenty of cash (disposable income)
        if cash < ticket_price + 500 {
            return;
        }

        if let Some(player) = state.players.iter_mut().find(|p| p.id == player_id) {
            player.cash -= ticket_price;
            // Choose a random number (1..100).
            let number = (state.seed.wrapping_mul(7) % 99 + 1) as u32;
            if let Some(ref mut lottery) = state.lottery_state {
                lottery.player_numbers.insert(player_id.to_string(), number);
            }
            state.publish_custom_event(
                "core:lottery_ticket_bought",
                "ai",
                serde_json::json!({
                    "player_id": player_id,
                    "number": number,
                }),
            );
        }
    }

    /// The AI is in jail — use get_out_of_jail card or pay bail strategically.
    fn handle_sent_to_jail(state: &mut GameState, player_id: &str) {
        const BAIL_PER_TURN: i64 = 50;

        let player = match state.players.iter().find(|p| p.id == player_id) {
            Some(p) => p.clone(), // Clone to avoid borrow issues
            None => return,
        };

        let bail = player.jail_turns as i64 * BAIL_PER_TURN;
        let owned_count = Self::owned_property_count(state, player_id);
        let has_get_out_of_jail = player.owned_cards.contains(&"get_out_of_jail".to_string());

        // Strategy:
        // - If we have get_out_of_jail card AND we own ≥3 properties (late game): use it
        // - If we have get_out_of_jail card AND bail is expensive: use it
        // - If early game (few properties): pay bail to keep acquiring
        // - If late game (many properties): stay in jail to avoid opponent rent
        // - If we can't afford bail: stay in jail

        if has_get_out_of_jail && owned_count >= 3 {
            // Use card to get out of jail (better than paying)
            if let Some(player) = state.players.iter_mut().find(|p| p.id == player_id) {
                player.owned_cards.retain(|c| c != "get_out_of_jail");
                player.jail_turns = 0;
                state.publish_custom_event(
                    "core:card_used",
                    "ai",
                    serde_json::json!({
                        "player_id": player_id,
                        "card_id": "get_out_of_jail",
                    }),
                );
                return;
            }
        }

        if player.cash < bail {
            return; // Can't afford bail — stay in jail
        }

        // Early game (≤2 properties owned) or cash-rich: pay bail
        // Late game (≥3 properties): stay in jail for safety
        if owned_count <= 2 || player.cash > 1500 {
            if let Some(player) = state.players.iter_mut().find(|p| p.id == player_id) {
                player.cash -= bail;
                player.jail_turns = 0;
                state.publish_custom_event(
                    "core:bail_paid",
                    "ai",
                    serde_json::json!({
                        "player_id": player_id,
                        "amount": bail,
                    }),
                );
            }
        }
        // else: stay in jail (avoid opponent properties)
    }
}

impl EventSubscriber for AiSubscriber {
    fn id(&self) -> &str {
        "ai.subscriber"
    }

    fn priority(&self) -> SubscriberPriority {
        SubscriberPriority::Last
    }

    fn interested_types(&self) -> Vec<&'static str> {
        // Only listen to events that need AI decisions.
        vec![
            "core:card_shop_landed",
            "core:lottery_landed",
            "core:player_sent_to_jail",
        ]
    }

    fn on_event(&mut self, event: &AnyEvent, state: &mut GameState) -> EventAction {
        if !Self::active_player_is_ai(state) {
            return EventAction::Continue;
        }

        match event.event_type() {
            "core:card_shop_landed" => {
                if let Some(pid) = payload_str(&event.payload, "player_id") {
                    Self::handle_card_shop_landed(state, pid);
                }
            }
            "core:lottery_landed" => {
                if let Some(pid) = payload_str(&event.payload, "player_id") {
                    Self::handle_lottery_landed(state, pid);
                }
            }
            "core:player_sent_to_jail" => {
                if let Some(pid) = payload_str(&event.payload, "player_id") {
                    Self::handle_sent_to_jail(state, pid);
                }
            }
            _ => {}
        }

        EventAction::Continue
    }
}
