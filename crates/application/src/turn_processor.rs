use sa_monopoly_domain::GameState;

use crate::commands::GameCommand;
use crate::engine::GameEngine;
use crate::events::GameEvent;
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

/// Processes a complete turn for the active player.
pub struct TurnProcessor;

impl TurnProcessor {
    /// Execute a full turn for the active player.
    /// Returns the list of all events generated during this turn.
    pub fn process_turn(
        state: &mut GameState,
        rng: &mut dyn RngService,
        decision_maker: &mut dyn DecisionMaker,
    ) -> Vec<GameEvent> {
        let mut events = Vec::new();

        // Phase 1: Roll dice → move → resolve tile
        let roll_event = GameEngine::execute(GameCommand::Roll, state, rng);
        events.push(roll_event.clone());

        // Sprint 7: Extra turn from sum-7 — skip EndTurn
        if matches!(&roll_event, GameEvent::ExtraTurn { .. } | GameEvent::DiceRolled { is_seven: true, .. }) {
            return events;
        }

        // If the player was in jail/hospital, the roll was rejected and turn ends
        match &roll_event {
            GameEvent::CommandRejected { reason }
                if reason == "player_in_jail" || reason == "player_in_hospital" =>
            {
                // Turn ends automatically (jail/hospital skip)
                let end_event = GameEngine::execute(GameCommand::EndTurn, state, rng);
                events.push(end_event);
                return events;
            }
            GameEvent::PlayerReleasedFromJail { .. }
            | GameEvent::PlayerReleasedFromHospital { .. } => {
                // Player was released from jail/hospital this turn.
                // The roll event indicates the release; no movement occurred,
                // so the turn ends here.
                let end_event = GameEngine::execute(GameCommand::EndTurn, state, rng);
                events.push(end_event);
                return events;
            }
            _ => {}
        }

        // Phase 2: After landing, check if the player can buy or upgrade the property
        // Get the player's current position
        if let Some(player) = state.active_player() {
            let tile_id = &player.position;

            // Check if this tile has a property
            if let Some(property) = state.board.property(tile_id) {
                let pid = &player.id;

                if property.owner.is_none() && !property.base_price.is_negative() {
                    // Unowned property → offer to buy
                    let decision =
                        decision_maker.decide_buy_property(state, tile_id, property.base_price);
                    match decision {
                        PlayerDecision::BuyProperty(_) => {
                            let buy_event = GameEngine::execute(
                                GameCommand::BuyProperty {
                                    tile_id: tile_id.clone(),
                                },
                                state,
                                rng,
                            );
                            events.push(buy_event);
                        }
                        _ => {}
                    }
                } else if property.owner.as_deref() == Some(pid.as_str()) {
                    // Own property → offer to upgrade
                    let decision = decision_maker.decide_upgrade_property(
                        state,
                        tile_id,
                        property.upgrade_level,
                    );
                    match decision {
                        PlayerDecision::UpgradeProperty(_) => {
                            let upgrade_event = GameEngine::execute(
                                GameCommand::UpgradeProperty {
                                    tile_id: tile_id.clone(),
                                },
                                state,
                                rng,
                            );
                            events.push(upgrade_event);
                        }
                        _ => {}
                    }
                }
            }
        }

        // Phase 3: End turn
        let end_event = GameEngine::execute(GameCommand::EndTurn, state, rng);

        // Sprint 7: If game ended, emit GameWon and skip TurnAdvanced
        if let GameEvent::GameWon { .. } = &end_event {
            events.push(end_event);
            return events;
        }

        // Emit individual PlayerEliminated events for each eliminated player
        if let GameEvent::TurnAdvanced {
            ref eliminated_players,
            ..
        } = end_event
        {
            for pid in eliminated_players {
                events.push(GameEvent::PlayerEliminated {
                    player_id: pid.clone(),
                });
            }
        }
        events.push(end_event);

        events
    }
}
