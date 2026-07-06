use std::sync::OnceLock;

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

static BROADCASTER: OnceLock<Box<dyn Fn(&BridgeResponse) + Send + Sync>> = OnceLock::new();

impl EngineBridge {
    pub fn execute(request: BridgeRequest) -> BridgeResponse {
        let mut state = request.state;
        let mut rng = BridgeRng::new(state.seed);
        let event = GameEngine::execute(request.command, &mut state, &mut rng);
        // Persist the RNG state back to the game state seed so the next
        // command call continues the sequence rather than restarting from
        // the same seed (which would produce identical dice rolls etc.).
        state.seed = rng.current_state();
        BridgeResponse { event, state }
    }

    pub fn set_broadcaster(f: Box<dyn Fn(&BridgeResponse) + Send + Sync>) {
        let _ = BROADCASTER.set(f);
    }

    pub fn execute_with_broadcast(request: BridgeRequest) -> BridgeResponse {
        let response = Self::execute(request);
        if let Some(broadcaster) = BROADCASTER.get() {
            broadcaster(&response);
        }
        response
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
                    auto_link_rent: false,
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
                group_rent_enabled: false,
                lottery_state: None,
                bail_abuse_count: 0,
            },
        }
    }
}
