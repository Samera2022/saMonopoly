use sa_monopoly_domain::events::core_events::{
    BankBonus, ChanceCardDrawn, FreeParkingBonus, IncomeTaxPaid, LandedOnSpecialProperty,
    LuxuryTaxPaid, PlayerLeftHospitalEvent, PlayerLeftJailEvent, PlayerSentToJailEvent,
    PlayerVisitedHospital, PlayerVisitedJail,
};
use sa_monopoly_domain::events::event_data::PropertyData;
use sa_monopoly_domain::property::{PropertyKind, SpecialPropertyKind};
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
        .register(tile_types::CARD_SHOP, "core", Box::new(handle_card_shop))
        .unwrap();
    registry
        .register(tile_types::LOTTERY, "core", Box::new(handle_lottery))
        .unwrap();
    registry
        .register(tile_types::JAIL, "core", Box::new(handle_jail))
        .unwrap();
    registry
        .register(tile_types::HOSPITAL, "core", Box::new(handle_hospital))
        .unwrap();
    registry
        .register(
            tile_types::GO_TO_JAIL,
            "core",
            Box::new(handle_go_to_jail),
        )
        .unwrap();
    registry
        .register(
            tile_types::SPECIAL_PROPERTY,
            "core",
            Box::new(handle_special_property),
        )
        .unwrap();
    registry
        .register(tile_types::BANK, "core", Box::new(handle_bank))
        .unwrap();
    registry
        .register(
            tile_types::EXTENSION_PROPERTY,
            "core",
            Box::new(handle_extension_property),
        )
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
                        "_state_diff": {
                            "from_player_id": player_id.clone(),
                            "to_player_id": owner.clone(),
                            "from_cash_change": -(rent as i64),
                            "to_cash_change": rent as i64,
                        },
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
                        "_state_diff": {
                            "player_id": player_id.clone(),
                            "tile_id": tile_id,
                            "cash_change": -price,
                        },
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
    log::info!("[TRACE] handle_chance entered for tile_id='{tile_id}'");
    let active_idx = state.active_player_index;
    let player_id = match state.players.get(active_idx) {
        Some(p) => p.id.clone(),
        None => return,
    };

    // Try to draw a card from the first deck that has cards.
    let drawn = {
        let deck = state.decks.first_mut();
        deck.map(|d| {
            let deck_id = d.id.clone();
            d.draw().map(|card| (deck_id, card.id.clone(), card.effect_key.clone()))
        }).flatten()
    };
    if let Some((deck_id, card_id, effect_key)) = drawn {
        log::info!("[TRACE] handle_chance: drew card='{card_id}' from deck='{deck_id}'");
        // Publish typed event — GameLogicHandler handles adding to inventory
        bus.publish_typed(&ChanceCardDrawn {
            player_id: player_id.clone(),
            card_id: card_id.clone(),
            effect_key: effect_key.clone(),
        }, state);
        // Keep legacy custom event for backward compatibility
        bus.publish_custom(
            "core:card_drawn",
            "core",
            serde_json::json!({
                "player_id": player_id.clone(),
                "card_id": card_id,
                "deck_id": deck_id,
                "effect_key": effect_key,
            }),
            state,
        );
    } else {
        log::info!("[TRACE] handle_chance: no card drawn (empty deck or no decks)");
    }
}

/// Handle landing on a JAIL tile (visiting) or being sent to jail.
fn handle_jail(
    state: &mut GameState,
    _tile_id: &str,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    let active_idx = state.active_player_index;
    let player_id = match state.players.get(active_idx) {
        Some(p) => p.id.clone(),
        None => return,
    };

    // Publish typed event — GameLogicHandler handles turn decrement / release logic
    bus.publish_typed(&PlayerVisitedJail {
        player_id: player_id.clone(),
    }, state);

    if let Some(player) = state.players.get(active_idx) {
        if player.is_in_jail() && player.jail_turns == 1 {
            // After this visit, jail_turns would reach 0 — publish release event
            // GameLogicHandler handles the actual decrement
            bus.publish_typed(&PlayerLeftJailEvent {
                player_id: player_id.clone(),
            }, state);
        }
    }
}

/// Handle landing on a HOSPITAL tile.
fn handle_hospital(
    state: &mut GameState,
    _tile_id: &str,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    let active_idx = state.active_player_index;
    let player_id = match state.players.get(active_idx) {
        Some(p) => p.id.clone(),
        None => return,
    };

    // Publish typed event — GameLogicHandler handles turn decrement / release logic
    bus.publish_typed(&PlayerVisitedHospital {
        player_id: player_id.clone(),
    }, state);

    if let Some(player) = state.players.get(active_idx) {
        if player.is_in_hospital() && player.hospital_turns == 1 {
            bus.publish_typed(&PlayerLeftHospitalEvent {
                player_id: player_id.clone(),
            }, state);
        }
    }
}

/// Handle landing on a GO_TO_JAIL tile: send the player directly to jail.
fn handle_go_to_jail(
    state: &mut GameState,
    _tile_id: &str,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    let active_idx = state.active_player_index;
    let player_id = match state.players.get(active_idx) {
        Some(p) => p.id.clone(),
        None => return,
    };

    bus.publish_typed(&PlayerSentToJailEvent {
        player_id: player_id.clone(),
        turns: 0,
    }, state);
}

/// Handle landing on a CARD_SHOP tile: notify Flutter to show the card shop dialog.
fn handle_card_shop(
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

    bus.publish_custom(
        "core:card_shop_landed",
        "core",
        serde_json::json!({
            "player_id": player_id,
            "tile_id": tile_id,
        }),
        state,
    );

    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": format!("card_shop:{tile_id}") }),
        state,
    );
}

/// Handle landing on a LOTTERY tile: notify Flutter to show the lottery dialog.
fn handle_lottery(
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

    bus.publish_custom(
        "core:lottery_landed",
        "core",
        serde_json::json!({
            "player_id": player_id,
            "tile_id": tile_id,
        }),
        state,
    );

    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": format!("lottery:{tile_id}") }),
        state,
    );
}

/// Handle landing on a SPECIAL_PROPERTY tile (Income Tax, Luxury Tax, Free Parking).
fn handle_special_property(
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

    if tile_id.contains("tax_1") {
        bus.publish_typed(&IncomeTaxPaid {
            player_id: player_id.clone(),
            amount: 200,
        }, state);
        bus.publish_custom(
            "core:income_tax_paid",
            "core",
            serde_json::json!({
                "player_id": player_id.clone(),
                "tile_id": tile_id,
                "amount": 200,
            }),
            state,
        );
    } else if tile_id.contains("tax_2") {
        bus.publish_typed(&LuxuryTaxPaid {
            player_id: player_id.clone(),
            amount: 100,
        }, state);
        bus.publish_custom(
            "core:luxury_tax_paid",
            "core",
            serde_json::json!({
                "player_id": player_id.clone(),
                "tile_id": tile_id,
                "amount": 100,
            }),
            state,
        );
    } else if tile_id.contains("park") {
        bus.publish_typed(&FreeParkingBonus {
            player_id: player_id.clone(),
            amount: 200,
        }, state);
        bus.publish_custom(
            "core:free_parking_bonus",
            "core",
            serde_json::json!({
                "player_id": player_id.clone(),
                "tile_id": tile_id,
                "amount": 200,
            }),
            state,
        );
    }

    let prop_data = PropertyData {
        tile_id: tile_id.to_string(),
        kind: PropertyKind::Special(
            if tile_id.contains("tax") { SpecialPropertyKind::Bank }
            else { SpecialPropertyKind::Bank }
        ),
        base_price: 0,
        owner: None,
        upgrade_level: 0,
        linked_targets: vec![],
    };
    bus.publish_typed(&LandedOnSpecialProperty {
        player_id,
        property: prop_data,
    }, state);
}

/// Handle landing on a BANK tile.
fn handle_bank(
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

    bus.publish_typed(&BankBonus {
        player_id: player_id.clone(),
        amount: 200,
    }, state);

    bus.publish_custom(
        "core:bank_bonus",
        "core",
        serde_json::json!({
            "player_id": player_id,
            "tile_id": tile_id,
            "amount": 200,
        }),
        state,
    );
}

/// Handle landing on an EXTENSION_PROPERTY tile.
fn handle_extension_property(
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

    bus.publish_custom(
        "core:extension_property_landed",
        "core",
        serde_json::json!({
            "player_id": player_id,
            "tile_id": tile_id,
        }),
        state,
    );

    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": format!("extension_property:{tile_id}") }),
        state,
    );
}
