use serde::{Deserialize, Serialize};

use sa_monopoly_domain::GameState;

use crate::commands::GameCommand;
use crate::engine::GameEngine;
use crate::events::GameEvent;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeRequest {
    pub command: GameCommand,
    pub state: GameState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeResponse {
    pub event: GameEvent,
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
    pub fn execute(request: BridgeRequest) -> BridgeResponse {
        let mut state = request.state;
        let mut rng = BridgeRng::new(state.seed);
        let event = GameEngine::execute(request.command, &mut state, &mut rng);
        BridgeResponse { event, state }
    }

    pub fn execute_json(input: &str) -> Result<String, String> {
        let request: BridgeRequest = serde_json::from_str(input).map_err(|err| err.to_string())?;
        let response = Self::execute(request);
        serde_json::to_string_pretty(&response).map_err(|err| err.to_string())
    }

    pub fn example_request() -> BridgeRequest {
        BridgeRequest {
            command: GameCommand::EndTurn,
            state: GameState {
                board: sa_monopoly_domain::Board {
                    tiles: vec![],
                    properties: vec![],
                    graph: Default::default(),
                },
                players: vec![],
                ruleset: sa_monopoly_domain::RuleSetRef {
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
            },
        }
    }
}
