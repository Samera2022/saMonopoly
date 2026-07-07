use sa_monopoly_domain::event::AnyEvent;
use sa_monopoly_domain::events::command_events::{
    BuyPropertyCommand, EndTurnCommand, RollCommand,
};
use sa_monopoly_domain::GameState;

use crate::command_handler::CommandHandlerRegistry;
use crate::event_bus::EventBus;
use crate::ports::RngService;

/// Register all core command handlers with the given registry.
pub fn register_core_commands(registry: &mut CommandHandlerRegistry) {
    registry
        .register("core:command:roll", "core", Box::new(handle_roll))
        .unwrap();
    registry
        .register(
            "core:command:buy_property",
            "core",
            Box::new(handle_buy_property),
        )
        .unwrap();
    registry
        .register("core:command:end_turn", "core", Box::new(handle_end_turn))
        .unwrap();
}

/// Handle the `roll` command: generate dice, move the player, handle jail/hospital,
/// handle passing start, and publish result events.
fn handle_roll(
    state: &mut GameState,
    event: AnyEvent,
    rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: RollCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::roll] failed to parse RollCommand: {e}");
            return;
        }
    };

    // Ensure the rolling player is the active player
    let active_idx = state.active_player_index;
    if state.players.get(active_idx).map(|p| p.id.as_str()) != Some(&cmd.player_id) {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "Not your turn" }),
            state,
        );
        return;
    }

    // Generate dice values
    let dice1 = (rng.next_u64() % 6) + 1;
    let dice2 = (rng.next_u64() % 6) + 1;
    let is_seven = dice1 + dice2 == 7;
    let consecutive = state.consecutive_doubles;

    // Publish dice rolled event
    bus.publish_custom(
        "core:dice_rolled",
        "core",
        serde_json::json!({
            "dice1": dice1,
            "dice2": dice2,
            "is_seven": is_seven,
            "consecutive": consecutive,
        }),
        state,
    );

    // Track doubles for three-doubles-to-jail rule
    if dice1 == dice2 {
        state.consecutive_doubles += 1;
        if state.consecutive_doubles >= 3 {
            // Three doubles → go to jail
            if let Some(player) = state.players.get_mut(active_idx) {
                player.jail_turns = 3;
                player.position = "Jail".to_string();
            }
            bus.publish_custom(
                "core:player_sent_to_jail",
                "core",
                serde_json::json!({
                    "player_id": cmd.player_id,
                    "turns": 3,
                }),
                state,
            );
            return;
        }
    } else {
        state.consecutive_doubles = 0;
    }

    // Handle jail / hospital: skip movement while incarcerated
    if let Some(player) = state.players.get(active_idx) {
        if player.is_in_jail() || player.is_in_hospital() {
            bus.publish_custom(
                "core:command_accepted",
                "core",
                serde_json::json!({ "name": "roll_in_jail" }),
                state,
            );
            return;
        }
    }

    // Move the player
    let steps = (dice1 + dice2) as usize;
    let from = state.players[active_idx].position.clone();
    let from_index = match state.board.tile_index(&from) {
        Some(i) => i,
        None => {
            log::error!("[builtin::roll] player on unknown tile '{from}'");
            return;
        }
    };
    let to_index = (from_index + steps) % state.board.tiles.len();
    let to = state.board.tiles[to_index].id.clone();
    let passed_start = to_index < from_index;

    // Update player position
    if let Some(player) = state.players.get_mut(active_idx) {
        player.position = to.clone();
    }

    // Handle passing start (+$200)
    if passed_start {
        if let Some(player) = state.players.get_mut(active_idx) {
            player.cash += 200;
        }
    }

    // Publish player moved event
    bus.publish_custom(
        "core:player_moved",
        "core",
        serde_json::json!({
            "player_id": cmd.player_id.clone(),
            "to_tile": to,
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "roll" }),
        state,
    );
}

/// Handle the `buy_property` command: check affordability, execute purchase,
/// publish result events.
fn handle_buy_property(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: BuyPropertyCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::buy_property] failed to parse BuyPropertyCommand: {e}");
            return;
        }
    };

    // Ensure the buying player is the active player
    let active_idx = state.active_player_index;
    if state.players.get(active_idx).map(|p| p.id.as_str()) != Some(&cmd.player_id) {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "Not your turn" }),
            state,
        );
        return;
    }

    // Look up the property on the board
    let property = match state.board.property(&cmd.tile_id) {
        Some(p) => p.clone(),
        None => {
            bus.publish_custom(
                "core:command_rejected",
                "core",
                serde_json::json!({ "reason": format!("Tile '{}' is not a purchasable property", cmd.tile_id) }),
                state,
            );
            return;
        }
    };

    // Check that property is not already owned
    if property.owner.is_some() {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "Property already owned" }),
            state,
        );
        return;
    }

    // Check affordability
    let price = property.base_price;
    if let Some(player) = state.players.get(active_idx) {
        if !player.can_afford(price) {
            bus.publish_custom(
                "core:command_rejected",
                "core",
                serde_json::json!({ "reason": format!("Cannot afford property: need ${price}, have ${}", player.cash) }),
                state,
            );
            return;
        }
    } else {
        return;
    }

    // Execute purchase: deduct cash and set owner
    if let Some(player) = state.players.get_mut(active_idx) {
        player.cash -= price;
    }
    if let Some(prop) = state.board.property_mut(&cmd.tile_id) {
        prop.owner = Some(cmd.player_id.clone());
    }

    // Publish property bought event
    bus.publish_custom(
        "core:property_bought",
        "core",
        serde_json::json!({
            "player_id": cmd.player_id.clone(),
            "tile_id": cmd.tile_id.clone(),
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "buy_property" }),
        state,
    );
}

/// Handle the `end_turn` command: eliminate bankrupt players, advance the turn,
/// check if the game has been won.
fn handle_end_turn(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: EndTurnCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::end_turn] failed to parse EndTurnCommand: {e}");
            return;
        }
    };

    // Ensure the ending player is the active player
    let active_idx = state.active_player_index;
    if state.players.get(active_idx).map(|p| p.id.as_str()) != Some(&cmd.player_id) {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "Not your turn" }),
            state,
        );
        return;
    }

    // Eliminate bankrupt players
    let mut eliminated_players: Vec<String> = Vec::new();
    let bankrupt_ids: Vec<String> = state
        .players
        .iter()
        .filter(|p| p.is_bankrupt())
        .map(|p| p.id.clone())
        .collect();

    for pid in &bankrupt_ids {
        // Publish player bankrupt event
        bus.publish_custom(
            "core:player_bankrupt",
            "core",
            serde_json::json!({ "player_id": pid }),
            state,
        );
        // Publish player eliminated event
        bus.publish_custom(
            "core:player_eliminated",
            "core",
            serde_json::json!({ "player_id": pid }),
            state,
        );
        eliminated_players.push(pid.clone());
    }

    // Advance the turn
    state.current_turn += 1;
    state.consecutive_doubles = 0;

    // Find next non-bankrupt player
    let player_count = state.players.len();
    let mut next_index = (active_idx + 1) % player_count;
    let mut attempts = 0;
    while attempts < player_count {
        if !state.players[next_index].is_bankrupt() {
            break;
        }
        next_index = (next_index + 1) % player_count;
        attempts += 1;
    }
    state.active_player_index = next_index;

    // Publish turn advanced event
    bus.publish_custom(
        "core:turn_advanced",
        "core",
        serde_json::json!({
            "turn": state.current_turn,
            "eliminated_players": eliminated_players,
        }),
        state,
    );

    // Check game won condition: only one player/team remains solvent
    let remaining = state
        .players
        .iter()
        .filter(|p| !p.is_bankrupt())
        .count();
    if remaining <= 1 {
        if let Some(winner) = state.players.iter().find(|p| !p.is_bankrupt()) {
            bus.publish_custom(
                "core:game_won",
                "core",
                serde_json::json!({
                    "winner_id": winner.id,
                    "remaining_players": remaining,
                }),
                state,
            );
        }
    }
}
