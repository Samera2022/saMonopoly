use serde::{Deserialize, Serialize};

use sa_monopoly_domain::GameState;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSyncSnapshot {
    pub state: GameState,
    pub revision: u64,
}

pub struct SessionSyncService;

impl SessionSyncService {
    pub fn snapshot(state: GameState, revision: u64) -> SessionSyncSnapshot {
        SessionSyncSnapshot { state, revision }
    }

    pub fn restore(snapshot: SessionSyncSnapshot) -> GameState {
        snapshot.state
    }
}
