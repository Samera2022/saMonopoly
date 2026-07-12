use sa_monopoly_domain::GameState;

/// Session synchronization state.
pub struct SessionSync {
    pub revision: u64,
}

impl SessionSync {
    pub fn new() -> Self {
        Self { revision: 0 }
    }

    /// Compare two game states and return a JSON diff.
    pub fn compute_diff(before: &GameState, after: &GameState) -> serde_json::Value {
        let mut diff = serde_json::Map::new();

        if before.current_turn != after.current_turn {
            diff.insert(
                "current_turn".to_string(),
                serde_json::json!(after.current_turn),
            );
        }
        if before.active_player_index != after.active_player_index {
            diff.insert(
                "active_player_index".to_string(),
                serde_json::json!(after.active_player_index),
            );
        }
        if before.players != after.players {
            diff.insert(
                "players".to_string(),
                serde_json::to_value(&after.players).unwrap_or_default(),
            );
        }
        if before.board.properties != after.board.properties {
            diff.insert(
                "properties".to_string(),
                serde_json::to_value(&after.board.properties).unwrap_or_default(),
            );
        }

        serde_json::Value::Object(diff)
    }

    /// Apply a diff to a GameState and return the patched state.
    pub fn apply_diff(state: &GameState, diff: &serde_json::Value) -> GameState {
        let mut patched = state.clone();
        if let Some(obj) = diff.as_object() {
            if let Some(turn) = obj.get("current_turn").and_then(|v| v.as_u64()) {
                patched.current_turn = turn;
            }
            if let Some(idx) = obj.get("active_player_index").and_then(|v| v.as_u64()) {
                patched.active_player_index = idx as usize;
            }
            if let Some(players) = obj.get("players") {
                if let Ok(p) = serde_json::from_value(players.clone()) {
                    patched.players = p;
                }
            }
            if let Some(props) = obj.get("properties") {
                if let Ok(p) = serde_json::from_value(props.clone()) {
                    patched.board.properties = p;
                }
            }
        }
        patched
    }

    /// Detect conflict between local and remote revisions.
    pub fn detect_conflict(local_rev: u64, remote_rev: u64) -> bool {
        remote_rev > local_rev + 1
    }

    /// Increment revision on each state change.
    pub fn next_revision(&mut self) -> u64 {
        self.revision += 1;
        self.revision
    }
}
