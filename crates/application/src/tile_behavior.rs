use std::collections::HashMap;
use sa_monopoly_domain::{GameState, TileTypeId};
use crate::event_bus::EventBus;
use crate::ports::RngService;

/// Tile behavior handler signature
pub type TileBehavior = Box<
    dyn Fn(&mut GameState, &str, &mut dyn RngService, &mut EventBus) + Send + Sync
>;

/// Registry of tile behaviors keyed by tile type ID
pub struct TileBehaviorRegistry {
    behaviors: HashMap<TileTypeId, (TileBehavior, String)>, // (behavior, plugin_id)
}

impl TileBehaviorRegistry {
    pub fn new() -> Self {
        Self { behaviors: HashMap::new() }
    }

    /// Register a behavior for a tile type
    pub fn register(
        &mut self,
        tile_type: &str,
        plugin_id: &str,
        behavior: TileBehavior,
    ) -> Result<(), String> {
        if self.behaviors.contains_key(tile_type) {
            return Err(format!("tile behavior for '{}' already registered", tile_type));
        }
        self.behaviors.insert(
            tile_type.to_string(),
            (behavior, plugin_id.to_string()),
        );
        Ok(())
    }

    /// Force-register a behavior (overwrites any existing).
    pub fn register_override(
        &mut self,
        tile_type: &str,
        plugin_id: &str,
        behavior: TileBehavior,
    ) {
        self.behaviors.insert(
            tile_type.to_string(),
            (behavior, plugin_id.to_string()),
        );
    }

    /// Remove all behaviors registered by a plugin
    pub fn unregister_plugin(&mut self, plugin_id: &str) {
        self.behaviors.retain(|_, (_, pid)| pid != plugin_id);
    }

    /// Execute the behavior for a tile type
    /// Returns true if a behavior was found and executed
    pub fn execute(
        &self,
        tile_type: &str,
        state: &mut GameState,
        tile_id: &str,
        rng: &mut dyn RngService,
        bus: &mut EventBus,
    ) -> bool {
        if let Some((behavior, _)) = self.behaviors.get(tile_type) {
            behavior(state, tile_id, rng, bus);
            true
        } else {
            false
        }
    }
}
