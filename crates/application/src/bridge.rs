use serde::{Deserialize, Serialize};
use sa_monopoly_domain::GameState;
use sa_monopoly_domain::event::AnyEvent;
use crate::event_bus::EventBus;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeRequest {
    pub command_type: String,
    pub source: String,
    pub payload: serde_json::Value,
    pub state: GameState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeResponse {
    pub events: Vec<AnyEvent>,
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
    pub fn execute(request: BridgeRequest, bus: &mut EventBus) -> BridgeResponse {
        let mut state = request.state;
        let mut rng = BridgeRng::new(state.seed);

        // Create command as AnyEvent::Custom
        let command = AnyEvent::Custom {
            event_type: request.command_type,
            source: request.source,
            payload: request.payload,
            timestamp: 0,
        };

        // Execute through EventBus
        bus.execute_command(command, &mut state, &mut rng);

        // Collect all events (convert from application AnyEvent to domain AnyEvent)
        let app_events = bus.drain_custom_events();
        let events: Vec<sa_monopoly_domain::event::AnyEvent> = app_events
            .into_iter()
            .map(|e| sa_monopoly_domain::event::AnyEvent::Custom {
                event_type: e.event_type,
                source: e.source,
                payload: e.payload,
                timestamp: e.timestamp,
            })
            .collect();

        state.seed = rng.current_state();
        BridgeResponse { events, state }
    }

    pub fn execute_json(input: &str) -> Result<String, String> {
        let request: BridgeRequest = serde_json::from_str(input).map_err(|err| err.to_string())?;
        let mut bus = EventBus::new();
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
