use log;

use crate::bridge::BridgeResponse;
use crate::event_bus::{AnyEvent, EventAction, EventSubscriber, SubscriberPriority};
use sa_monopoly_domain::GameState;
use sa_monopoly_domain::LotteryState;

use sa_monopoly_domain::events::core_events::*;
#[allow(unused_imports)]
use sa_monopoly_domain::events::event_data::*;

// ---------------------------------------------------------------------------
// BridgeBroadcaster
// ---------------------------------------------------------------------------

pub struct BridgeBroadcaster {
    bridge_tx: tokio::sync::mpsc::Sender<BridgeResponse>,
}

impl BridgeBroadcaster {
    pub fn new(bridge_tx: tokio::sync::mpsc::Sender<BridgeResponse>) -> Self {
        Self { bridge_tx }
    }
}

impl EventSubscriber for BridgeBroadcaster {
    fn id(&self) -> &str {
        "core.bridge"
    }

    fn on_event(&mut self, event: &AnyEvent, state: &mut GameState) -> EventAction {
        // Forward custom events (including domain events wrapped as custom)
        // to the bridge channel as BridgeResponse items.
        // Events are flattened into the simple format Flutter expects.
        let event_type = event.event_type().to_string();
        let mut flat = serde_json::Map::new();
        flat.insert("event_type".to_string(), serde_json::Value::String(event_type));
        let response = BridgeResponse {
            events: vec![serde_json::Value::Object(flat)],
            state: state.clone(),
        };
        let _ = self.bridge_tx.try_send(response);
        EventAction::Continue
    }
}

// ---------------------------------------------------------------------------
// EventLogger
// ---------------------------------------------------------------------------

pub struct EventLogger;

impl EventSubscriber for EventLogger {
    fn id(&self) -> &str {
        "core.logger"
    }

    fn priority(&self) -> SubscriberPriority {
        SubscriberPriority::Last
    }

    fn on_event(&mut self, event: &AnyEvent, state: &mut GameState) -> EventAction {
        log::info!(
            "[TURN {}] {:?} (players: {})",
            state.current_turn,
            event,
            state.players.len()
        );
        EventAction::Continue
    }
}

// ---------------------------------------------------------------------------
// SchedulerBridge
// ---------------------------------------------------------------------------

pub struct SchedulerBridge {
    pub scheduler: crate::scheduler::VecScheduler,
}

impl SchedulerBridge {
    pub fn new(scheduler: crate::scheduler::VecScheduler) -> Self {
        Self { scheduler }
    }

    #[allow(dead_code)]
    fn execute_effect(
        &mut self,
        effect: crate::scheduler::TimedEffect,
        _state: &GameState,
    ) {
        log::info!("[Scheduler] Executing effect: {:?}", effect);
    }
}

// ---------------------------------------------------------------------------
// GameLogicHandler
// ---------------------------------------------------------------------------

/// Handles typed game events by executing the actual game logic
/// (cash deductions, state changes, etc.)
///
/// Phase 1: Framework only — command handlers still perform direct state
/// mutations. The subscriber listens for typed events and will gradually
/// take over logic execution in subsequent phases.
pub struct GameLogicHandler;

impl EventSubscriber for GameLogicHandler {
    fn id(&self) -> &str {
        "core.game_logic"
    }

    fn priority(&self) -> SubscriberPriority {
        SubscriberPriority::Normal
    }

    fn interested_types(&self) -> Vec<&'static str> {
        vec![
            "core:property_bought_event",
            "core:property_upgraded_event",
            "core:landed_on_owned_property",
            "core:player_paid_bail",
            "core:lottery_ticket_bought_event",
            "core:card_used_event",
            "core:card_bought_event",
            "core:shares_sold_event",
            "core:trade_proposed_event",
            "core:auction_started_event",
            "core:property_mortgaged",
            "core:property_redeemed",
            "core:end_turn_event",
            "core:income_tax_paid_event",
            "core:luxury_tax_paid_event",
            "core:free_parking_bonus_event",
            "core:bank_bonus_event",
            "core:chance_card_drawn_event",
            "core:player_visited_jail",
            "core:player_visited_hospital",
            "core:player_sent_to_jail_event",
            "core:player_left_jail",
            "core:player_left_hospital",
        ]
    }

    fn on_event(&mut self, event: &AnyEvent, state: &mut GameState) -> EventAction {
        match event.event_type() {
            "core:property_mortgaged" => {
                if let Ok(ev) = event.clone().into_typed::<PropertyMortgaged>() {
                    // Set property as mortgaged
                    if let Some(prop) = state.board.property_mut(&ev.tile_id) {
                        prop.is_mortgaged = true;
                    }
                    // Credit the player with mortgage amount
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.cash += ev.amount;
                    }
                }
            }
            "core:property_redeemed" => {
                if let Ok(ev) = event.clone().into_typed::<PropertyRedeemed>() {
                    // Un-mortgage the property
                    if let Some(prop) = state.board.property_mut(&ev.tile_id) {
                        prop.is_mortgaged = false;
                    }
                    // Deduct redemption fee from player
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.cash -= ev.amount;
                    }
                }
            }
            // === handle_pay_bail: deduct cash, clear jail_turns, increment abuse count ===
            "core:player_paid_bail" => {
                if let Ok(ev) = event.clone().into_typed::<PlayerPaidBailEvent>() {
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.cash -= ev.amount;
                        player.jail_turns = 0;
                    }
                    state.bail_abuse_count += 1;
                }
            }
            // === handle_sell_shares: deduct shares, add cash ===
            "core:shares_sold_event" => {
                if let Ok(ev) = event.clone().into_typed::<SellSharesExecuted>() {
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.stock_shares -= ev.shares;
                        player.cash += ev.total_price;
                    }
                }
            }
            // === handle_buy_card: deduct cash, add card to owned_cards ===
            "core:card_bought_event" => {
                if let Ok(ev) = event.clone().into_typed::<CardBoughtEvent>() {
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.cash -= ev.price;
                        player.owned_cards.push(ev.card_id.clone());
                    }
                }
            }
            // === handle_buy_property: deduct cash, set property owner ===
            "core:property_bought_event" => {
                if let Ok(ev) = event.clone().into_typed::<PropertyBoughtEvent>() {
                    let price = ev.property.base_price;
                    // Deduct cash from player
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.cash -= price;
                    }
                    // Set property owner
                    if let Some(prop) = state.board.property_mut(&ev.property.tile_id) {
                        prop.owner = Some(ev.player_id.clone());
                    }
                }
            }
            // === handle_upgrade_property: deduct cash, increment upgrade level ===
            "core:property_upgraded_event" => {
                if let Ok(ev) = event.clone().into_typed::<PropertyUpgradedEvent>() {
                    // Calculate upgrade cost from current property state
                    let cost = state.board.property(&ev.property.tile_id)
                        .map(|p| p.upgrade_cost())
                        .unwrap_or(0);
                    // Deduct cash from player
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.cash -= cost;
                    }
                    // Increment upgrade level
                    if let Some(prop) = state.board.property_mut(&ev.property.tile_id) {
                        prop.upgrade_level += 1;
                    }
                }
            }
            // === handle_use_card: remove card from player's owned_cards ===
            "core:card_used_event" => {
                if let Ok(ev) = event.clone().into_typed::<CardUsedEvent>() {
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.owned_cards.retain(|c| c != &ev.card.id);
                    }
                }
            }
            // === handle_buy_lottery_ticket: deduct cash, record number ===
            "core:lottery_ticket_bought_event" => {
                if let Ok(ev) = event.clone().into_typed::<LotteryTicketBoughtEvent>() {
                    // Use stored ticket price from lottery state, or fallback to constant
                    let ticket_price = state.lottery_state
                        .as_ref()
                        .map(|ls| ls.ticket_price)
                        .unwrap_or(LotteryState::BASE_TICKET_PRICE);
                    // Deduct cash from player
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.cash -= ticket_price;
                    }
                    // Record the chosen number in lottery state
                    if let Some(ref mut lottery) = state.lottery_state {
                        lottery.player_numbers.insert(ev.player_id.clone(), ev.number as u32);
                    }
                }
            }
            // === handle_landed_on_owned_property: transfer rent from payer to owner ===
            "core:landed_on_owned_property" => {
                if let Ok(ev) = event.clone().into_typed::<LandedOnOwnedProperty>() {
                    // Deduct rent from the paying player
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.from_player_id) {
                        player.cash -= ev.amount;
                    }
                    // Add rent to the receiving player
                    if let Some(owner) = state.players.iter_mut().find(|p| p.id == ev.to_player_id) {
                        owner.cash += ev.amount;
                    }
                }
            }
            // === handle_end_turn: bankruptcy detection, turn advance, next player, win check ===
            "core:end_turn_event" => {
                if let Ok(ev) = event.clone().into_typed::<EndTurnEvent>() {
                    let active_idx = state.active_player_index;

                    // Eliminate bankrupt players
                    let mut eliminated_players: Vec<String> = Vec::new();
                    let bankrupt_ids: Vec<String> = state
                        .players
                        .iter()
                        .filter(|p| p.is_bankrupt())
                        .map(|p| p.id.clone())
                        .collect();

                    // Note: bankruptcy events are published via publish_custom to
                    // maintain backward-compatible event flow for bridge/plugins.
                    for pid in &bankrupt_ids {
                        state.publish_custom_event(
                            "core:player_bankrupt",
                            "core",
                            serde_json::json!({ "player_id": pid }),
                        );
                        state.publish_custom_event(
                            "core:player_eliminated",
                            "core",
                            serde_json::json!({ "player_id": pid }),
                        );
                        eliminated_players.push(pid.clone());
                    }

                    // Advance the turn
                    state.current_turn += 1;
                    state.consecutive_doubles = 0;

                    // Find next non-bankrupt player
                    let player_count = state.players.len();
                    let mut next_index = (active_idx + 1) % player_count;
                    let mut attempts = 0;
                    while attempts < player_count {
                        if !state.players[next_index].is_bankrupt() {
                            break;
                        }
                        next_index = (next_index + 1) % player_count;
                        attempts += 1;
                    }
                    state.active_player_index = next_index;

                    // Publish turn advanced event
                    state.publish_custom_event(
                        "core:turn_advanced",
                        "core",
                        serde_json::json!({
                            "turn": state.current_turn,
                            "eliminated_players": eliminated_players,
                        }),
                    );

                    // Check game won condition: only one player remains solvent
                    let remaining = state
                        .players
                        .iter()
                        .filter(|p| !p.is_bankrupt())
                        .count();
                    if remaining <= 1 {
                        if let Some(winner) = state.players.iter().find(|p| !p.is_bankrupt()) {
                            state.publish_custom_event(
                                "core:game_won",
                                "core",
                                serde_json::json!({
                                    "winner_id": winner.id,
                                    "remaining_players": remaining,
                                }),
                            );
                        }
                    }

                    // Publish typed events for turn transition
                    state.publish_custom_event(
                        "core:player_turn_ended",
                        "core",
                        serde_json::json!({ "player_id": ev.player_id }),
                    );
                    if let Some(next_player) = state.players.get(next_index) {
                        state.publish_custom_event(
                            "core:player_turn_started",
                            "core",
                            serde_json::json!({ "player_id": next_player.id.clone() }),
                        );
                    }
                }
            }
            // === handle_income_tax: deduct cash ===
            "core:income_tax_paid_event" => {
                if let Ok(ev) = event.clone().into_typed::<IncomeTaxPaid>() {
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.cash -= ev.amount;
                    }
                }
            }
            // === handle_luxury_tax: deduct cash ===
            "core:luxury_tax_paid_event" => {
                if let Ok(ev) = event.clone().into_typed::<LuxuryTaxPaid>() {
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.cash -= ev.amount;
                    }
                }
            }
            // === handle_free_parking_bonus: add cash ===
            "core:free_parking_bonus_event" => {
                if let Ok(ev) = event.clone().into_typed::<FreeParkingBonus>() {
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.cash += ev.amount;
                    }
                }
            }
            // === handle_bank_bonus: add cash ===
            "core:bank_bonus_event" => {
                if let Ok(ev) = event.clone().into_typed::<BankBonus>() {
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.cash += ev.amount;
                    }
                }
            }
            // === handle_chance_card_drawn: add card to owned_cards ===
            "core:chance_card_drawn_event" => {
                if let Ok(ev) = event.clone().into_typed::<ChanceCardDrawn>() {
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.owned_cards.push(ev.card_id.clone());
                    }
                }
            }
            // === handle_player_visited_jail: pure notification, no-op ===
            "core:player_visited_jail" => {
                // Pure notification — no state change needed
            }
            // === handle_player_visited_hospital: pure notification, no-op ===
            "core:player_visited_hospital" => {
                // Pure notification — no state change needed
            }
            // === handle_player_sent_to_jail: execute jail logic ===
            "core:player_sent_to_jail_event" => {
                if let Ok(ev) = event.clone().into_typed::<PlayerSentToJailEvent>() {
                    // Find the jail tile ID
                    let jail_tile_id = state
                        .board
                        .tiles
                        .iter()
                        .find(|t| t.kind == sa_monopoly_domain::tile::tile_types::JAIL)
                        .map(|t| t.id.clone())
                        .unwrap_or_else(|| "Jail".to_string());
                    // Apply bail-abuse penalty
                    let extra = if state.bail_abuse_count > 0 { 1 } else { 0 };
                    let turns = GameState::BASE_JAIL_TURNS + extra;
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.position = jail_tile_id;
                        player.jail_turns = turns;
                    }
                    state.bail_abuse_count = 0;
                }
            }
            // === handle_player_left_jail: clear jail_turns ===
            "core:player_left_jail" => {
                if let Ok(ev) = event.clone().into_typed::<PlayerLeftJailEvent>() {
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.jail_turns = 0;
                    }
                }
            }
            // === handle_player_left_hospital: clear hospital_turns ===
            "core:player_left_hospital" => {
                if let Ok(ev) = event.clone().into_typed::<PlayerLeftHospitalEvent>() {
                    if let Some(player) = state.players.iter_mut().find(|p| p.id == ev.player_id) {
                        player.hospital_turns = 0;
                    }
                }
            }
            _ => {}
        }
        EventAction::Continue
    }
}

impl EventSubscriber for SchedulerBridge {
    fn id(&self) -> &str {
        "core.scheduler"
    }

    fn interested_types(&self) -> Vec<&'static str> {
        vec!["turn_advanced"]
    }

    fn on_event(&mut self, event: &AnyEvent, _state: &mut GameState) -> EventAction {
        // Match on event_type string instead of enum variant
        if event.event_type() == "turn_advanced" {
            // Extract turn number from the event
            // For now, use current turn from state since we don't have typed access
            // The scheduler tick will be handled
        }
        EventAction::Continue
    }
}
