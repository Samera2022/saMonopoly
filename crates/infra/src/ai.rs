use sa_monopoly_application::game_session::GameSession;

pub trait PlayerAgent {
    fn choose_command(&self, session: &GameSession) -> String; // returns command type string
    fn command_payload(&self, command_type: &str, session: &GameSession) -> serde_json::Value;
}

/// Simple heuristic AI agent
pub struct HeuristicAgent;

impl PlayerAgent for HeuristicAgent {
    fn choose_command(&self, session: &GameSession) -> String {
        if let Some(player) = session.active_player() {
            if player.cash > 200 {
                if let Some(tile) = session.state.board.property(&player.position) {
                    if tile.owner.is_none() {
                        return "core:command:buy_property".to_string();
                    }
                }
                return "core:command:end_turn".to_string();
            }
            return "core:command:roll".to_string();
        }
        "core:command:end_turn".to_string()
    }

    fn command_payload(&self, command_type: &str, session: &GameSession) -> serde_json::Value {
        match command_type {
            "core:command:buy_property" => {
                if let Some(player) = session.active_player() {
                    serde_json::json!({ "tile_id": player.position })
                } else {
                    serde_json::json!({})
                }
            }
            _ => serde_json::json!({})
        }
    }
}

/// AI agent that evaluates candidate commands using heuristic scoring
/// to choose the best action.
pub struct MonteCarloAgent;

impl PlayerAgent for MonteCarloAgent {
    fn choose_command(&self, session: &GameSession) -> String {
        let player_id = session
            .active_player()
            .map(|p| p.id.clone())
            .unwrap_or_default();

        if player_id.is_empty() {
            return "core:command:end_turn".to_string();
        }

        // Build the list of candidate command type strings
        let mut candidates: Vec<&str> = vec!["core:command:roll", "core:command:end_turn"];

        // If the player is standing on an unowned property they can afford, add BuyProperty
        if let Some(player) = session.active_player() {
            if let Some(property) = session.state.board.property(&player.position) {
                if property.owner.is_none() && player.cash >= property.base_price {
                    candidates.push("core:command:buy_property");
                }
            }
        }

        // Score each candidate based on current state (no simulation needed)
        let mut best_score = f64::NEG_INFINITY;
        let mut best_command = "core:command:roll";

        for cmd in &candidates {
            let score = match *cmd {
                "core:command:buy_property" => {
                    if let Some(player) = session.active_player() {
                        if let Some(property) = session.state.board.property(&player.position) {
                            // Value of property relative to cash
                            let value_ratio = property.base_price as f64 / player.cash.max(1) as f64;
                            if value_ratio <= 0.5 {
                                200.0 // Good deal
                            } else {
                                100.0 // Still worth it
                            }
                        } else {
                            0.0
                        }
                    } else {
                        0.0
                    }
                }
                "core:command:roll" => 50.0, // Rolling is usually beneficial
                "core:command:end_turn" => 10.0, // Ending turn is the default fallback
                _ => 0.0,
            };

            if score > best_score {
                best_score = score;
                best_command = cmd;
            }
        }

        best_command.to_string()
    }

    fn command_payload(&self, command_type: &str, session: &GameSession) -> serde_json::Value {
        match command_type {
            "core:command:buy_property" => {
                if let Some(player) = session.active_player() {
                    serde_json::json!({ "tile_id": player.position })
                } else {
                    serde_json::json!({})
                }
            }
            "core:command:roll" => {
                if let Some(player) = session.active_player() {
                    serde_json::json!({ "player_id": player.id })
                } else {
                    serde_json::json!({})
                }
            }
            "core:command:end_turn" => {
                if let Some(player) = session.active_player() {
                    serde_json::json!({ "player_id": player.id })
                } else {
                    serde_json::json!({})
                }
            }
            _ => serde_json::json!({}),
        }
    }
}
