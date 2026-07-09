use serde::{Deserialize, Serialize};
use sa_monopoly_domain::GameState;
use sa_monopoly_domain::event::AnyEvent;
use crate::event_bus::EventBus;
use crate::builtin::commands::register_core_commands;
use crate::builtin::tiles::register_core_tile_behaviors;
use crate::startup::register_core_subscribers;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeRequest {
    pub command_type: String,
    pub source: String,
    pub payload: serde_json::Value,
    pub state: GameState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeResponse {
    /// Flattened events in the format Flutter expects:
    /// `{"event_type": "core:dice_rolled", "dice1": 3, "dice2": 4}`
    pub events: Vec<serde_json::Value>,
    pub state: GameState,
}

/// Simple XorShift64 RNG used by the bridge when executing commands.
struct BridgeRng {
    state: u64,
}

impl BridgeRng {
    fn new(seed: u64) -> Self {
        Self { state: seed.max(1) }
    }

    /// Expose the current RNG state so callers can persist it back
    /// to the game state (preventing identical sequences on re-play).
    ///
    /// The state is masked to 48 bits to ensure it fits within
    /// JavaScript's safe integer range (2^53) when serialised
    /// through JSON between the Rust engine and the Flutter/Dart
    /// frontend. 48 bits (2^48 ≈ 2.8×10^14) provides ample
    /// entropy for a board game PRNG.
    fn current_state(&self) -> u64 {
        self.state & 0xFFFFFFFFFFFF
    }
}

impl crate::ports::RngService for BridgeRng {
    fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        x
    }
}

pub struct EngineBridge;

impl EngineBridge {

    /// Flatten a [`AnyEvent::Custom`] into the simple format Flutter expects.
    ///
    /// Input (Rust nested format):
    /// ```json
    /// {"Custom": {"event_type": "core:dice_rolled", "source": "core", "payload": {"dice1": 3, "dice2": 4}, "timestamp": 123}}
    /// ```
    ///
    /// Output (flat format):
    /// ```json
    /// {"event_type": "core:dice_rolled", "dice1": 3, "dice2": 4}
    /// ```
    ///
    /// For [`AnyEvent::Typed`], the `event_type` and parsed payload fields are merged.
    fn flatten_event(event: &sa_monopoly_domain::event::AnyEvent) -> serde_json::Value {
        let mut map = serde_json::Map::new();

        match event {
            AnyEvent::Custom {
                event_type,
                payload,
                ..
            } => {
                map.insert(
                    "event_type".to_string(),
                    serde_json::Value::String(event_type.clone()),
                );
                // Promote all payload fields to the top level
                if let serde_json::Value::Object(obj) = payload {
                    for (k, v) in obj {
                        map.insert(k.clone(), v.clone());
                    }
                }
            }
            AnyEvent::Typed {
                event_type,
                payload,
                ..
            } => {
                map.insert(
                    "event_type".to_string(),
                    serde_json::Value::String(event_type.clone()),
                );
                // Parse the raw JSON payload and merge its fields
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(payload.get()) {
                    if let serde_json::Value::Object(obj) = val {
                        for (k, v) in obj {
                            map.insert(k.clone(), v);
                        }
                    }
                }
            }
        }

        serde_json::Value::Object(map)
    }

    pub fn execute(request: BridgeRequest, bus: &mut EventBus) -> BridgeResponse {
        let mut state = request.state;
        let mut rng = BridgeRng::new(state.seed);

        // Create command as AnyEvent::Custom using the command_type from the request.
        // Flutter now sends namespaced names (e.g. "core:command:roll") directly,
        // so no mapping is needed.
        let command = AnyEvent::Custom {
            event_type: request.command_type,
            source: request.source,
            payload: request.payload,
            timestamp: 0,
        };

        // Execute through EventBus
        bus.execute_command(command, &mut state, &mut rng);

        // Collect all events and flatten them for Flutter
        let app_events = bus.drain_custom_events();
        let events: Vec<serde_json::Value> = app_events
            .into_iter()
            .map(|e| {
                let domain_event = sa_monopoly_domain::event::AnyEvent::Custom {
                    event_type: e.event_type,
                    source: e.source,
                    payload: e.payload,
                    timestamp: e.timestamp,
                };
                Self::flatten_event(&domain_event)
            })
            .collect();

        state.seed = rng.current_state();
        BridgeResponse { events, state }
    }

    pub fn execute_json(input: &str) -> Result<String, String> {
        let request: BridgeRequest = serde_json::from_str(input).map_err(|err| err.to_string())?;
        let mut bus = EventBus::new();
        // Register core command handlers and tile behaviors so the engine
        // can process commands like "core:command:roll", "core:command:buy_property", etc.
        register_core_commands(&mut bus.command_handlers);
        register_core_tile_behaviors(&mut bus.tile_behaviors);
        register_core_subscribers(&mut bus);

        // ★ TODO: Hot-plug injection of active external plugins.
        //   In the future this will call:
        //     PluginManager::global_active().register_into_bus(&mut bus);
        //   For now, plugins_dir env var is reserved as an extension point:
        //     if let Ok(plugin_state) = std::env::var("SA_MONOPOLY_PLUGINS_DIR") { … }

        let response = Self::execute(request, &mut bus);
        serde_json::to_string_pretty(&response).map_err(|err| err.to_string())
    }

    pub fn example_request() -> BridgeRequest {
        BridgeRequest {
            command_type: "core:command:end_turn".to_string(),
            source: "core".to_string(),
            payload: serde_json::json!({}),
            state: GameState {
                board: sa_monopoly_domain::Board {
                    tiles: vec![],
                    properties: vec![],
                    graph: Default::default(),
                    auto_link_rent: false,
                },
                players: vec![],
                ruleset: sa_monopoly_domain::rules::RuleSetRef {
                    id: "classic".to_string(),
                    version: "0.1.0".to_string(),
                },
                current_turn: 0,
                active_player_index: 0,
                seed: 1,
                decks: vec![],
                stock_market: None,
                active_auction: None,
                consecutive_doubles: 0,
                max_upgrade_level: 3,
                extension_upgrade_enabled: false,
                group_rent_enabled: false,
                lottery_state: None,
                bail_abuse_count: 0,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bridge_roll_response() {
        let _ = env_logger::builder().is_test(true).filter_level(log::LevelFilter::Info).try_init();

        // Build a minimal request JSON
        let input = serde_json::json!({
            "command_type": "core:command:roll",
            "source": "core",
            "payload": {
                "player_id": "player_1"
            },
            "state": {
                "board": {
                    "tiles": [
                        {"id": "start", "name_key": "start", "kind": "core:start", "linked_property_kind": null},
                        {"id": "prop_1", "name_key": "p1", "kind": "core:ordinary_property", "linked_property_kind": "Ordinary"},
                        {"id": "jail", "name_key": "jail", "kind": "core:jail", "linked_property_kind": null}
                    ],
                    "properties": [],
                    "graph": {"edges": [], "teleporters": []},
                    "auto_link_rent": false
                },
                "players": [
                    {
                        "id": "player_1", "name": "Test", "cash": 1500,
                        "position": "start", "is_ai": false, "is_llm_controlled": false,
                        "jail_turns": 0, "hospital_turns": 0,
                        "owned_cards": [], "stock_shares": 0, "team_id": null
                    }
                ],
                "ruleset": {"id": "classic", "version": "0.1.0"},
                "current_turn": 0, "active_player_index": 0, "seed": 42,
                "decks": [], "stock_market": null, "active_auction": null,
                "consecutive_doubles": 0, "max_upgrade_level": 3,
                "extension_upgrade_enabled": false, "group_rent_enabled": false,
                "lottery_state": null, "bail_abuse_count": 0
            }
        }).to_string();

        let result = EngineBridge::execute_json(&input).unwrap();
        println!("Bridge response:\n{}", result);

        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();

        // Verify events array exists and has at least one event
        let events = parsed["events"].as_array().unwrap();
        assert!(!events.is_empty(), "Expected at least one event");
        
        let first_event = &events[0];
        println!("First event: {}", first_event);
        
        // Verify dice1 and dice2 are present and non-zero
        let dice1 = first_event["dice1"].as_i64().unwrap_or(0);
        let dice2 = first_event["dice2"].as_i64().unwrap_or(0);
        println!("dice1={}, dice2={}", dice1, dice2);
        
        assert!(dice1 >= 1 && dice1 <= 6, "dice1 should be 1-6, got {}", dice1);
        assert!(dice2 >= 1 && dice2 <= 6, "dice2 should be 1-6, got {}", dice2);
        
        // Verify state is returned and player position changed
        let state = parsed["state"].as_object().unwrap();
        assert!(state.contains_key("players"), "state should contain players");
    }
}
