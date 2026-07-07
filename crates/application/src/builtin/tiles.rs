use sa_monopoly_domain::tile::tile_types;
use sa_monopoly_domain::GameState;

use crate::event_bus::EventBus;
use crate::ports::RngService;
use crate::tile_behavior::TileBehaviorRegistry;

/// Register all core tile behavior handlers with the given registry.
pub fn register_core_tile_behaviors(registry: &mut TileBehaviorRegistry) {
    registry
        .register(tile_types::START, "core", Box::new(handle_start))
        .unwrap();
    registry
        .register(
            tile_types::ORDINARY_PROPERTY,
            "core",
            Box::new(handle_ordinary_property),
        )
        .unwrap();
    registry
        .register(tile_types::CHANCE, "core", Box::new(handle_chance))
        .unwrap();
    registry
        .register(tile_types::JAIL, "core", Box::new(handle_jail))
        .unwrap();
}

/// Handle landing on the START tile.
fn handle_start(
    state: &mut GameState,
    tile_id: &str,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": format!("landed_on_start:{tile_id}") }),
        state,
    );
}

/// Handle landing on an ordinary property tile.
/// If unowned and the player can afford it, they may buy it.
/// If owned by another player, they must pay rent.
fn handle_ordinary_property(
    state: &mut GameState,
    tile_id: &str,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    let active_idx = state.active_player_index;
    let player_id = match state.players.get(active_idx) {
        Some(p) => p.id.clone(),
        None => return,
    };

    // Look up the property
    let property = match state.board.property(tile_id) {
        Some(p) => p.clone(),
        None => {
            log::warn!("[builtin::ordinary_property] no property for tile '{tile_id}'");
            return;
        }
    };

    // Publish landed-on-tile event
    bus.publish_custom(
        "core:player_moved",
        "core",
        serde_json::json!({
            "player_id": player_id.clone(),
            "to_tile": tile_id,
        }),
        state,
    );

    if let Some(ref owner) = property.owner {
        // Property is owned
        if owner == &player_id {
            // Landed on own property — nothing to do
            bus.publish_custom(
                "core:command_accepted",
                "core",
                serde_json::json!({ "name": format!("own_property:{tile_id}") }),
                state,
            );
        } else {
            // Pay rent to the owner
            let rent = property.current_rent();
            if rent > 0 {
                // Deduct rent from active player
                if let Some(player) = state.players.get_mut(active_idx) {
                    player.cash -= rent;
                }
                // Add rent to owner
                if let Some(owner_idx) = state.players.iter().position(|p| p.id == *owner) {
                    state.players[owner_idx].cash += rent;
                }
                bus.publish_custom(
                    "core:rent_paid",
                    "core",
                    serde_json::json!({
                        "from_player_id": player_id.clone(),
                        "to_player_id": owner.clone(),
                        "amount": rent,
                    }),
                    state,
                );
            }
        }
    } else {
        // Property is unowned — trigger buy if affordable
        let price = property.base_price;
        if let Some(player) = state.players.get(active_idx) {
            if player.can_afford(price) {
                // Auto-buy the property
                if let Some(player) = state.players.get_mut(active_idx) {
                    player.cash -= price;
                }
                if let Some(prop) = state.board.property_mut(tile_id) {
                    prop.owner = Some(player_id.clone());
                }
                bus.publish_custom(
                    "core:property_bought",
                    "core",
                    serde_json::json!({
                        "player_id": player_id.clone(),
                        "tile_id": tile_id,
                    }),
                    state,
                );
            } else {
                // Cannot afford — could trigger auction
                bus.publish_custom(
                    "core:command_rejected",
                    "core",
                    serde_json::json!({ "reason": format!("Cannot afford property '{tile_id}': need ${price}, have ${}", player.cash) }),
                    state,
                );
            }
        }
    }
}

/// Handle landing on a CHANCE tile: draw a card from the first available deck.
fn handle_chance(
    state: &mut GameState,
    tile_id: &str,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    let active_idx = state.active_player_index;
    let player_id = match state.players.get(active_idx) {
        Some(p) => p.id.clone(),
        None => return,
    };

    // Publish landed-on-tile event
    bus.publish_custom(
        "core:player_moved",
        "core",
        serde_json::json!({
            "player_id": player_id.clone(),
            "to_tile": tile_id,
        }),
        state,
    );

    // Try to draw a card from the first deck that has cards
    if let Some(deck) = state.decks.first_mut() {
        if let Some(card) = deck.draw() {
            // Add the card to the player's inventory
            if let Some(player) = state.players.get_mut(active_idx) {
                player.owned_cards.push(card.id.clone());
            }
            bus.publish_custom(
                "core:card_drawn",
                "core",
                serde_json::json!({
                    "player_id": player_id.clone(),
                    "card_id": card.id,
                    "deck_id": deck.id,
                    "effect_key": card.effect_key,
                }),
                state,
            );
        } else {
            // No cards left in deck
            bus.publish_custom(
                "core:command_accepted",
                "core",
                serde_json::json!({ "name": format!("chance_empty:{tile_id}") }),
                state,
            );
        }
    } else {
        // No decks available
        bus.publish_custom(
            "core:command_accepted",
            "core",
            serde_json::json!({ "name": format!("chance_no_decks:{tile_id}") }),
            state,
        );
    }
}

/// Handle landing on a JAIL tile (visiting) or being sent to jail.
fn handle_jail(
    state: &mut GameState,
    tile_id: &str,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    let active_idx = state.active_player_index;
    let player_id = match state.players.get(active_idx) {
        Some(p) => p.id.clone(),
        None => return,
    };

    // Publish landed-on-tile event
    bus.publish_custom(
        "core:player_moved",
        "core",
        serde_json::json!({
            "player_id": player_id.clone(),
            "to_tile": tile_id,
        }),
        state,
    );

    // If the player is currently in jail (jail_turns > 0), this is a "just visiting" situation
    // or they are serving their sentence — decrement turns
    if let Some(player) = state.players.get_mut(active_idx) {
        if player.is_in_jail() {
            player.jail_turns -= 1;
            if player.jail_turns == 0 {
                bus.publish_custom(
                    "core:player_released_from_jail",
                    "core",
                    serde_json::json!({ "player_id": player_id }),
                    state,
                );
            }
        } else {
            // Just visiting — nothing special
            bus.publish_custom(
                "core:command_accepted",
                "core",
                serde_json::json!({ "name": format!("visiting_jail:{tile_id}") }),
                state,
            );
        }
    }
}
