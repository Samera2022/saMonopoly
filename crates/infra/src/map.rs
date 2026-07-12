// Re-export map data types from domain crate to break circular dependency.
// The types originally lived here, but they are pure data models and belong
// in the domain crate. This module now serves as a backward-compatible shim.
pub use sa_monopoly_domain::map::*;

// ============================================================================
// Map validation – infra-specific; kept here (not in domain) because
// validation logic is an infrastructure concern.
// ============================================================================

pub trait MapValidator {
    fn validate(&self, map: &MapDefinition) -> Result<(), Vec<String>>;
}

pub struct BasicMapValidator;

impl MapValidator for BasicMapValidator {
    fn validate(&self, map: &MapDefinition) -> Result<(), Vec<String>> {
        let mut errors = Vec::new();
        if map.id.trim().is_empty() {
            errors.push("map.id must not be empty".to_string());
        }
        if map.version.trim().is_empty() {
            errors.push("map.version must not be empty".to_string());
        }
        if map.tiles.is_empty() {
            errors.push("map must contain at least one tile".to_string());
        }
        if map.tiles.iter().any(|tile| tile.id.trim().is_empty()) {
            errors.push("all tile ids must be set".to_string());
        }
        if map.tiles.iter().any(|tile| tile.name_key.trim().is_empty()) {
            errors.push("all tile name keys must be set".to_string());
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors)
        }
    }
}
