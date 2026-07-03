use sa_monopoly_domain::GameState;

use crate::effects::EffectResolver;
use crate::events::GameEvent;

pub struct SpecialRulesService;

impl SpecialRulesService {
    pub fn resolve_tile(
        state: &mut GameState,
        tile_id: &str,
        rng: &mut dyn crate::ports::RngService,
    ) -> Option<GameEvent> {
        EffectResolver::resolve_special_tile(state, tile_id, rng)
    }
}
