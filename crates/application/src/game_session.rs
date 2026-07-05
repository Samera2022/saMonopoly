use sa_monopoly_domain::{Board, GameState, Player, RuleSetRef};

#[derive(Debug, Clone)]
pub struct GameSession {
    pub state: GameState,
}

impl GameSession {
    pub fn new(board: Board, players: Vec<Player>, ruleset: RuleSetRef, seed: u64) -> Self {
        Self {
            state: GameState {
                board,
                players,
                ruleset,
                current_turn: 0,
                active_player_index: 0,
                seed,
                decks: vec![],
                stock_market: None,
                active_auction: None,
                consecutive_doubles: 0,
                max_upgrade_level: 3,
                extension_upgrade_enabled: false,
                lottery_state: None,
            },
        }
    }

    pub fn active_player(&self) -> Option<&Player> {
        self.state.active_player()
    }
}
