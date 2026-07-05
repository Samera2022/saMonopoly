use sa_monopoly_domain::{Board, GameState, Player, RuleSetRef};

use crate::bridge::{BridgeRequest, EngineBridge};
use crate::commands::GameCommand;
use crate::events::GameEvent;

pub struct GameBootstrap;

impl GameBootstrap {
    pub fn create_empty_state() -> GameState {
        GameState {
            board: Board {
                tiles: vec![],
                properties: vec![],
                graph: Default::default(),
            },
            players: vec![Player {
                id: "player_1".to_string(),
                name: "Player 1".to_string(),
                cash: 1500,
                position: "start".to_string(),
                is_ai: false,
                is_llm_controlled: false,
                jail_turns: 0,
                hospital_turns: 0,
                owned_cards: vec![],
                stock_shares: 0,
            }],
            ruleset: RuleSetRef {
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
        }
    }

    pub fn run_initial_turn() -> GameEvent {
        let request = BridgeRequest {
            command: GameCommand::EndTurn,
            state: Self::create_empty_state(),
        };
        EngineBridge::execute(request).event
    }
}
