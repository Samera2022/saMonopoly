use sa_monopoly_application::commands::GameCommand;
use sa_monopoly_application::engine::GameEngine;
use sa_monopoly_application::game_session::GameSession;

use crate::rng::XorShift64;

pub trait PlayerAgent {
    fn choose_command(&self, session: &GameSession) -> GameCommand;
}

/// Simple heuristic AI agent
pub struct HeuristicAgent;

impl PlayerAgent for HeuristicAgent {
    fn choose_command(&self, session: &GameSession) -> GameCommand {
        if let Some(player) = session.active_player() {
            if player.cash > 200 {
                if let Some(tile) = session.state.board.property(&player.position) {
                    if tile.owner.is_none() {
                        return GameCommand::BuyProperty {
                            tile_id: tile.tile_id.clone(),
                        };
                    }
                }
                return GameCommand::EndTurn;
            }
            return GameCommand::Roll;
        }
        GameCommand::EndTurn
    }
}

/// Monte Carlo AI agent that simulates random playouts to choose the best action.
///
/// For each valid action, the agent runs `simulations` random playouts
/// (each starting from a clone of the current state) and scores the
/// resulting state.  The action with the highest average score is chosen.
pub struct MonteCarloAgent {
    pub simulations: u32,
}

impl MonteCarloAgent {
    pub fn new(simulations: u32) -> Self {
        Self { simulations }
    }

    /// Score a game state from the perspective of `player_id`.
    /// Higher values indicate a more favourable state for that player.
    fn score_state(state: &sa_monopoly_domain::GameState, player_id: &str) -> f64 {
        let mut score = 0f64;

        if let Some(player) = state.players.iter().find(|p| p.id == player_id) {
            // Cash is king
            score += player.cash as f64;

            // Each owned property contributes a flat bonus
            let owned = state
                .board
                .properties
                .iter()
                .filter(|p| p.owner.as_deref() == Some(player_id))
                .count();
            score += owned as f64 * 100.0;

            // Penalties for being in jail / hospital
            if player.jail_turns > 0 {
                score -= 50.0;
            }
            if player.hospital_turns > 0 {
                score -= 30.0;
            }
        }

        score
    }
}

impl PlayerAgent for MonteCarloAgent {
    fn choose_command(&self, session: &GameSession) -> GameCommand {
        let player_id = session
            .active_player()
            .map(|p| p.id.clone())
            .unwrap_or_default();

        if player_id.is_empty() {
            return GameCommand::EndTurn;
        }

        // Build the list of candidate commands
        let mut candidates: Vec<GameCommand> = vec![GameCommand::Roll, GameCommand::EndTurn];

        // If the player is standing on an unowned property they can afford, add BuyProperty
        if let Some(player) = session.active_player() {
            if let Some(property) = session.state.board.property(&player.position) {
                if property.owner.is_none() && player.cash >= property.base_price {
                    candidates.push(GameCommand::BuyProperty {
                        tile_id: property.tile_id.clone(),
                    });
                }
            }
        }

        // Monte Carlo: simulate each candidate and pick the best
        let mut best_score = f64::NEG_INFINITY;
        let mut best_command = GameCommand::Roll;

        for cmd in &candidates {
            let mut total_score = 0f64;

            for _ in 0..self.simulations {
                let mut sim_state = session.state.clone();
                let mut sim_rng = XorShift64::new(sim_state.seed);

                let event = GameEngine::execute(cmd.clone(), &mut sim_state, &mut sim_rng);

                // Penalise commands that would be rejected
                if matches!(
                    event,
                    sa_monopoly_application::events::GameEvent::CommandRejected { .. }
                ) {
                    total_score -= 1000.0;
                    continue;
                }

                total_score += Self::score_state(&sim_state, &player_id);
            }

            let avg_score = total_score / self.simulations as f64;
            if avg_score > best_score {
                best_score = avg_score;
                best_command = cmd.clone();
            }
        }

        best_command
    }
}
