use sa_monopoly_domain::GameState;
use sa_monopoly_domain::event::AnyEvent;
use crate::event_bus::EventBus;
use crate::ports::RngService;

/// Represents the decision a player makes during their turn.
#[derive(Debug, Clone)]
pub enum PlayerDecision {
    /// Player chooses to buy the property they landed on.
    BuyProperty(String), // tile_id
    /// Player chooses to upgrade the property they landed on.
    UpgradeProperty(String), // tile_id
    /// Player chooses to do nothing (skip buying/upgrading, pass).
    Pass,
}

/// A trait for making player decisions during a turn.
pub trait DecisionMaker {
    fn decide_buy_property(
        &mut self,
        state: &GameState,
        tile_id: &str,
        price: i64,
    ) -> PlayerDecision;

    /// Called when the active player lands on their own property.
    /// Return `UpgradeProperty(tile_id)` to upgrade, or `Pass` to skip.
    fn decide_upgrade_property(
        &mut self,
        state: &GameState,
        tile_id: &str,
        current_level: u32,
    ) -> PlayerDecision;
}

/// Rule-based AI decision maker for automated players.
pub struct AiDecisionMaker;

impl DecisionMaker for AiDecisionMaker {
    fn decide_buy_property(
        &mut self,
        _state: &GameState,
        tile_id: &str,
        price: i64,
    ) -> PlayerDecision {
        // In a real implementation we'd inspect state for more nuance.
        // For now: buy if cash > 200 and can afford.
        // We always try to buy (TurnProcessor only calls this if property is unowned).
        if price > 0 {
            PlayerDecision::BuyProperty(tile_id.to_string())
        } else {
            PlayerDecision::Pass
        }
    }

    fn decide_upgrade_property(
        &mut self,
        _state: &GameState,
        _tile_id: &str,
        _current_level: u32,
    ) -> PlayerDecision {
        // AI does not upgrade properties for now.
        PlayerDecision::Pass
    }
}

/// Processes a complete turn for the active player.
pub struct TurnProcessor;

impl TurnProcessor {
    /// Execute a full turn for the active player, publishing events through
    /// the `EventBus` instead of returning them as a `Vec<GameEvent>`.
    pub fn process_turn_with_bus(
        state: &mut GameState,
        rng: &mut dyn RngService,
        decision_maker: &mut dyn DecisionMaker,
        bus: &mut EventBus,
    ) {
        // Phase 1: Roll
        let player_id = state.active_player()
            .map(|p| p.id.clone())
            .unwrap_or_default();
        let roll_cmd = AnyEvent::Custom {
            event_type: "core:command:roll".to_string(),
            source: "core".to_string(),
            payload: serde_json::json!({ "player_id": player_id }),
            timestamp: 0,
        };
        bus.execute_command(roll_cmd, state, rng);

        // Phase 2: Check if player can buy property
        if let Some(player) = state.active_player() {
            let tile_id = player.position.clone();
            if let Some(property) = state.board.property(&tile_id) {
                if property.owner.is_none() {
                    let decision = decision_maker.decide_buy_property(state, &tile_id, property.base_price);
                    if matches!(decision, PlayerDecision::BuyProperty(_)) {
                        let buy_cmd = AnyEvent::Custom {
                            event_type: "core:command:buy_property".to_string(),
                            source: "core".to_string(),
                            payload: serde_json::json!({ "tile_id": tile_id }),
                            timestamp: 0,
                        };
                        bus.execute_command(buy_cmd, state, rng);
                    }
                }
            }
        }

        // Phase 3: End turn
        let end_cmd = AnyEvent::Custom {
            event_type: "core:command:end_turn".to_string(),
            source: "core".to_string(),
            payload: serde_json::json!({ "player_id": player_id }),
            timestamp: 0,
        };
        bus.execute_command(end_cmd, state, rng);
    }
}
