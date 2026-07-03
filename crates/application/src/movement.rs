use sa_monopoly_domain::{GameState, MovementResult};

pub struct MovementService;

impl MovementService {
    pub fn move_steps(state: &mut GameState, steps: usize) -> Option<MovementResult> {
        let player_index = state.active_player_index;
        let from = state.players.get(player_index)?.position.clone();
        let from_index = state.board.tile_index(&from)?;
        let to_index = (from_index + steps) % state.board.tiles.len();
        let to = state.board.tiles.get(to_index)?.id.clone();
        let passed_start = to_index < from_index;
        if let Some(active) = state.players.get_mut(player_index) {
            active.position = to.clone();
        }
        Some(MovementResult {
            from,
            to,
            passed_start,
        })
    }
}
