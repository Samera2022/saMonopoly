use sa_monopoly_domain::event::AnyEvent;
use sa_monopoly_domain::events::command_events::{
    AuctionCommand, BidCommand, BuyCardCommand, BuyLotteryTicketCommand, BuyPropertyCommand,
    ConfigGetCommand, ConfigSetCommand, EndTurnCommand, MortgageCommand, PayBailCommand,
    PayRentCommand, RedeemCommand, RollCommand, SellSharesCommand, TradeCommand,
    UpgradePropertyCommand, UseCardCommand,
};
use sa_monopoly_domain::ActiveAuction;
use sa_monopoly_domain::GameState;
use sa_monopoly_domain::LotteryState;

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
    registry
        .register(
            "core:command:upgrade_property",
            "core",
            Box::new(handle_upgrade_property),
        )
        .unwrap();
    registry
        .register(
            "core:command:pay_bail",
            "core",
            Box::new(handle_pay_bail),
        )
        .unwrap();
    registry
        .register(
            "core:command:buy_card",
            "core",
            Box::new(handle_buy_card),
        )
        .unwrap();
    registry
        .register(
            "core:command:buy_lottery_ticket",
            "core",
            Box::new(handle_buy_lottery_ticket),
        )
        .unwrap();
    registry
        .register(
            "core:command:use_card",
            "core",
            Box::new(handle_use_card),
        )
        .unwrap();
    registry
        .register(
            "core:command:mortgage",
            "core",
            Box::new(handle_mortgage),
        )
        .unwrap();
    registry
        .register(
            "core:command:redeem",
            "core",
            Box::new(handle_redeem),
        )
        .unwrap();
    registry
        .register(
            "core:command:pay_rent",
            "core",
            Box::new(handle_pay_rent),
        )
        .unwrap();
    registry
        .register(
            "core:command:auction",
            "core",
            Box::new(handle_auction),
        )
        .unwrap();
    registry
        .register(
            "core:command:bid",
            "core",
            Box::new(handle_bid),
        )
        .unwrap();
    registry
        .register(
            "core:command:trade",
            "core",
            Box::new(handle_trade),
        )
        .unwrap();
    registry
        .register(
            "core:command:config_get",
            "core",
            Box::new(handle_config_get),
        )
        .unwrap();
    registry
        .register(
            "core:command:config_set",
            "core",
            Box::new(handle_config_set),
        )
        .unwrap();
    registry
        .register(
            "core:command:sell_shares",
            "core",
            Box::new(handle_sell_shares),
        )
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

    // Handle hospital: reject roll command while hospitalized (no dice published)
    if let Some(player) = state.players.get(active_idx) {
        if player.is_in_hospital() {
            bus.publish_custom(
                "core:command_rejected",
                "core",
                serde_json::json!({ "reason": "player_in_hospital" }),
                state,
            );
            return;
        }
    }

    // Handle jail: still roll dice but mark as jail roll (consecutive=null).
    // If doubles → released and moves; otherwise stays and jail_turns decrements.
    if let Some(player) = state.players.get(active_idx) {
        if player.is_in_jail() {
            bus.publish_custom(
                "core:dice_rolled",
                "core",
                serde_json::json!({
                    "dice1": dice1,
                    "dice2": dice2,
                    "is_seven": dice1 + dice2 == 7,
                    "consecutive": null,
                    "_state_diff": {
                        "player_id": cmd.player_id,
                    },
                }),
                state,
            );

            if dice1 == dice2 {
                // Doubles → released from jail!
                if let Some(p) = state.players.get_mut(active_idx) {
                    p.jail_turns = 0;
                }
                bus.publish_custom(
                    "core:player_released_from_jail",
                    "core",
                    serde_json::json!({
                        "player_id": cmd.player_id.clone(),
                        "dice1": dice1,
                        "dice2": dice2,
                    }),
                    state,
                );
                // Fall through to normal movement below
            } else {
                // No doubles → remain in jail, decrement turns
                if let Some(p) = state.players.get_mut(active_idx) {
                    if p.jail_turns > 0 {
                        p.jail_turns -= 1;
                    }
                }
                bus.publish_custom(
                    "core:command_accepted",
                    "core",
                    serde_json::json!({ "name": "roll_in_jail_failed" }),
                    state,
                );
                return;
            }
        }
    }

    // Publish dice rolled event (normal roll — not jail, not hospital)
    let consecutive = state.consecutive_doubles;
    bus.publish_custom(
        "core:dice_rolled",
        "core",
        serde_json::json!({
            "dice1": dice1,
            "dice2": dice2,
            "is_seven": is_seven,
            "consecutive": consecutive,
            "_state_diff": {
                "player_id": cmd.player_id,
            },
        }),
        state,
    );

    // Track doubles for three-doubles-to-jail rule
    if dice1 == dice2 {
        state.consecutive_doubles += 1;
        if state.consecutive_doubles >= 3 {
            // Three doubles → go to jail (with bail-abuse penalty)
            let jail_tile_id = state
                .board
                .tiles
                .iter()
                .find(|t| t.kind == "core:jail")
                .map(|t| t.id.clone())
                .unwrap_or_else(|| "Jail".to_string());
            let turns = state.send_active_player_to_jail(&jail_tile_id);
            bus.publish_custom(
                "core:player_sent_to_jail",
                "core",
                serde_json::json!({
                    "player_id": cmd.player_id,
                    "turns": turns,
                }),
                state,
            );
            return;
        }
    } else {
        state.consecutive_doubles = 0;
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
            "to_tile": to.clone(),
            "_state_diff": {
                "player_id": cmd.player_id.clone(),
                "from_tile": from,
                "to_tile": to.clone(),
                "passed_start": passed_start,
            },
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
            "_state_diff": {
                "player_id": cmd.player_id.clone(),
                "tile_id": cmd.tile_id.clone(),
                "cash_change": -price,
            },
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

/// Handle the `pay_bail` command: check if the active player is in jail,
/// calculate bail amount (jail_turns × 50), deduct cash, clear jail_turns,
/// increment bail_abuse_count, and publish result events.
fn handle_pay_bail(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: PayBailCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::pay_bail] failed to parse PayBailCommand: {e}");
            return;
        }
    };

    // Ensure the paying player is the active player
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

    // Check if the player is in jail
    let (jail_turns, can_afford) = match state.players.get(active_idx) {
        Some(player) if player.is_in_jail() => {
            let bail_amount = player.jail_turns as i64 * 50;
            (player.jail_turns, player.can_afford(bail_amount))
        }
        Some(_) => {
            // Player exists but is not in jail
            bus.publish_custom(
                "core:command_rejected",
                "core",
                serde_json::json!({ "reason": "Player is not in jail" }),
                state,
            );
            return;
        }
        None => return,
    };

    // Calculate bail amount
    let bail_amount = jail_turns as i64 * 50;

    // Check if player can afford it
    if !can_afford {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": format!("Cannot afford bail: need ${bail_amount}") }),
            state,
        );
        return;
    }

    // Execute bail payment: deduct cash, clear jail_turns, increment abuse count
    if let Some(player) = state.players.get_mut(active_idx) {
        player.cash -= bail_amount;
        player.jail_turns = 0;
    }
    state.bail_abuse_count += 1;

    // Publish bail paid event
    bus.publish_custom(
        "core:bail_paid",
        "core",
        serde_json::json!({
            "player_id": cmd.player_id.clone(),
            "amount": bail_amount,
            "_state_diff": {
                "player_id": cmd.player_id.clone(),
                "cash_change": -(bail_amount as i64),
                "jail_cleared": true,
            },
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "pay_bail" }),
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

/// Handle the `buy_card` command: check affordability, deduct cash, add card
/// to player's owned_cards, and publish result events.
fn handle_buy_card(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: BuyCardCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::buy_card] failed to parse BuyCardCommand: {e}");
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

    // Check affordability using the price from the command
    if let Some(player) = state.players.get(active_idx) {
        if !player.can_afford(cmd.price) {
            bus.publish_custom(
                "core:command_rejected",
                "core",
                serde_json::json!({ "reason": format!("Cannot afford card: need ${}, have ${}", cmd.price, player.cash) }),
                state,
            );
            return;
        }
    } else {
        return;
    }

    // Execute purchase: deduct cash and add card to owned_cards
    if let Some(player) = state.players.get_mut(active_idx) {
        player.cash -= cmd.price;
        player.owned_cards.push(cmd.card_id.clone());
    }

    // Publish card bought event
    bus.publish_custom(
        "core:card_bought",
        "core",
        serde_json::json!({
            "player_id": cmd.player_id.clone(),
            "card_id": cmd.card_id.clone(),
            "price": cmd.price,
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "buy_card" }),
        state,
    );
}

/// Handle the `buy_lottery_ticket` command: ensure active player,
/// initialize lottery state if needed, check affordability of the fixed $50
/// ticket price, deduct cash, record the chosen number, and publish result events.
fn handle_buy_lottery_ticket(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: BuyLotteryTicketCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!(
                "[builtin::buy_lottery_ticket] failed to parse BuyLotteryTicketCommand: {e}"
            );
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

    // Initialize lottery state if not already initialized
    if state.lottery_state.is_none() {
        state.lottery_state = Some(LotteryState::new(state.current_turn));
    }

    // Fixed ticket price
    let ticket_price: i64 = LotteryState::BASE_TICKET_PRICE;

    // Check affordability
    if let Some(player) = state.players.get(active_idx) {
        if !player.can_afford(ticket_price) {
            bus.publish_custom(
                "core:command_rejected",
                "core",
                serde_json::json!({ "reason": format!("Cannot afford lottery ticket: need ${ticket_price}, have ${}", player.cash) }),
                state,
            );
            return;
        }
    } else {
        return;
    }

    // Execute purchase: deduct cash
    if let Some(player) = state.players.get_mut(active_idx) {
        player.cash -= ticket_price;
    }

    // Record the chosen number in lottery state
    if let Some(ref mut lottery) = state.lottery_state {
        lottery.player_numbers.insert(cmd.player_id.clone(), cmd.number);
    }

    // Publish lottery ticket bought event
    bus.publish_custom(
        "core:lottery_ticket_bought",
        "core",
        serde_json::json!({
            "player_id": cmd.player_id.clone(),
            "number": cmd.number,
            "ticket_price": ticket_price,
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "buy_lottery_ticket" }),
        state,
    );
}

/// Handle the `upgrade_property` command: validate ownership, affordability,
/// and max level; execute the upgrade; publish result events.
fn handle_upgrade_property(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: UpgradePropertyCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::upgrade_property] failed to parse UpgradePropertyCommand: {e}");
            return;
        }
    };

    // Ensure the upgrading player is the active player
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

    // Check that property is owned by the player
    if property.owner.as_deref() != Some(&cmd.player_id) {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "You do not own this property" }),
            state,
        );
        return;
    }

    // Check if already at max upgrade level
    if (property.upgrade_level as u64) >= state.max_upgrade_level {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": format!("Property already at max upgrade level ({})", state.max_upgrade_level) }),
            state,
        );
        return;
    }

    // Calculate upgrade cost
    let cost = property.upgrade_cost();

    // Check affordability
    if let Some(player) = state.players.get(active_idx) {
        if !player.can_afford(cost) {
            bus.publish_custom(
                "core:command_rejected",
                "core",
                serde_json::json!({ "reason": format!("Cannot afford upgrade: need ${cost}, have ${}", player.cash) }),
                state,
            );
            return;
        }
    } else {
        return;
    }

    // Execute upgrade: deduct cash and increment upgrade level
    if let Some(player) = state.players.get_mut(active_idx) {
        player.cash -= cost;
    }
    let new_level: u32;
    if let Some(prop) = state.board.property_mut(&cmd.tile_id) {
        prop.upgrade_level += 1;
        new_level = prop.upgrade_level;
    } else {
        return;
    }

    // Publish property upgraded event
    bus.publish_custom(
        "core:property_upgraded",
        "core",
        serde_json::json!({
            "player_id": cmd.player_id.clone(),
            "tile_id": cmd.tile_id.clone(),
            "new_level": new_level,
            "cost": cost,
            "_state_diff": {
                "player_id": cmd.player_id.clone(),
                "tile_id": cmd.tile_id.clone(),
                "cash_change": -(cost as i64),
                "new_level": new_level,
            },
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "upgrade_property" }),
        state,
    );
}

/// Handle the `use_card` command: verify ownership, consume the card,
/// and publish result events.
fn handle_use_card(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: UseCardCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::use_card] failed to parse UseCardCommand: {e}");
            return;
        }
    };

    // Ensure the using player is the active player
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

    // Check if the player owns the card
    let owns_card = match state.players.get(active_idx) {
        Some(player) => player.owned_cards.contains(&cmd.card_id),
        None => false,
    };

    if !owns_card {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": format!("Player does not own card '{}'", cmd.card_id) }),
            state,
        );
        return;
    }

    // Consume the card: remove card_id from owned_cards
    if let Some(player) = state.players.get_mut(active_idx) {
        player.owned_cards.retain(|c| c != &cmd.card_id);
    }

    // Publish card used event
    bus.publish_custom(
        "core:card_used",
        "core",
        serde_json::json!({
            "player_id": cmd.player_id.clone(),
            "card_id": cmd.card_id.clone(),
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "use_card" }),
        state,
    );
}

/// Handle the `mortgage` command: validate ownership, verify not already
/// mortgaged, set `is_mortgaged = true`, credit player 100 cash,
/// and publish result events.
fn handle_mortgage(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: MortgageCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::mortgage] failed to parse MortgageCommand: {e}");
            return;
        }
    };

    // Ensure the mortgaging player is the active player
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

    // Check that property is owned by the player
    if property.owner.as_deref() != Some(&cmd.player_id) {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "You do not own this property" }),
            state,
        );
        return;
    }

    // Check that property is not already mortgaged
    if property.is_mortgaged {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "Property is already mortgaged" }),
            state,
        );
        return;
    }

    // Execute mortgage: set is_mortgaged and credit player with 100 cash
    let amount: i64 = 100;
    if let Some(prop) = state.board.property_mut(&cmd.tile_id) {
        prop.is_mortgaged = true;
    }
    if let Some(player) = state.players.get_mut(active_idx) {
        player.cash += amount;
    }

    // Publish property mortgaged event
    bus.publish_custom(
        "core:property_mortgaged",
        "core",
        serde_json::json!({
            "tile_id": cmd.tile_id.clone(),
            "amount": amount,
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "mortgage" }),
        state,
    );
}

/// Handle the `redeem` command: validate ownership, verify property is
/// currently mortgaged, check affordability of the $110 redemption fee,
/// set `is_mortgaged = false`, deduct cash, and publish result events.
fn handle_redeem(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: RedeemCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::redeem] failed to parse RedeemCommand: {e}");
            return;
        }
    };

    // Ensure the redeeming player is the active player
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

    // Check that property is owned by the player
    if property.owner.as_deref() != Some(&cmd.player_id) {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "You do not own this property" }),
            state,
        );
        return;
    }

    // Check that property is currently mortgaged
    if !property.is_mortgaged {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "Property is not mortgaged" }),
            state,
        );
        return;
    }

    // Check affordability of the $110 redemption fee
    let amount: i64 = 110;
    if let Some(player) = state.players.get(active_idx) {
        if !player.can_afford(amount) {
            bus.publish_custom(
                "core:command_rejected",
                "core",
                serde_json::json!({ "reason": format!("Cannot afford redemption: need ${amount}, have ${}", player.cash) }),
                state,
            );
            return;
        }
    } else {
        return;
    }

    // Execute redemption: un-mortgage the property and deduct cash
    if let Some(prop) = state.board.property_mut(&cmd.tile_id) {
        prop.is_mortgaged = false;
    }
    if let Some(player) = state.players.get_mut(active_idx) {
        player.cash -= amount;
    }

    // Publish property redeemed event
    bus.publish_custom(
        "core:property_redeemed",
        "core",
        serde_json::json!({
            "tile_id": cmd.tile_id.clone(),
            "amount": amount,
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "redeem" }),
        state,
    );
}

/// Handle the `pay_rent` command: locate the property and its owner,
/// calculate rent, transfer funds from the active player to the owner,
/// and publish result events.
fn handle_pay_rent(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: PayRentCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::pay_rent] failed to parse PayRentCommand: {e}");
            return;
        }
    };

    // Ensure the paying player is the active player
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

    // Verify the property has an owner
    let owner_id = match &property.owner {
        Some(id) => id.clone(),
        None => {
            bus.publish_custom(
                "core:command_rejected",
                "core",
                serde_json::json!({ "reason": "Property has no owner" }),
                state,
            );
            return;
        }
    };

    // Verify the owner is not the current player (no self-payment)
    if owner_id == cmd.player_id {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "Cannot pay rent to yourself" }),
            state,
        );
        return;
    }

    // Calculate rent
    let rent_amount = property.current_rent();

    // ★ Pre-Event: 让插件决定是否/如何收租
    let pre = bus.fire_command_pre_hook("core:rent_due", serde_json::json!({
        "player_id": cmd.player_id.clone(),
        "owner_id": owner_id.clone(),
        "amount": rent_amount,
        "tile_id": cmd.tile_id.clone(),
    }), state);

    if pre.is_canceled() {
        bus.publish_custom("core:command_rejected", "core",
            serde_json::json!({
                "reason": "cancelled_by_plugin",
                "plugin_event": "core:rent_due",
                "cancel_reason": pre.payload.get("cancel_reason"),
            }), state);
        return;
    }

    // 插件可能修改了金额
    let final_amount = pre.payload.get("amount")
        .and_then(|v| v.as_i64())
        .unwrap_or(rent_amount);

    // Check affordability (using final_amount)
    if let Some(player) = state.players.get(active_idx) {
        if !player.can_afford(final_amount) {
            bus.publish_custom(
                "core:command_rejected",
                "core",
                serde_json::json!({ "reason": format!("Cannot afford rent: need ${final_amount}, have ${}", player.cash) }),
                state,
            );
            return;
        }
    } else {
        return;
    }

    // Find the owner's index in the players vector
    let owner_idx = match state.players.iter().position(|p| p.id == owner_id) {
        Some(idx) => idx,
        None => {
            log::error!("[builtin::pay_rent] owner '{owner_id}' not found in players list");
            return;
        }
    };

    // Execute rent transfer: deduct from payer, add to owner
    if let Some(player) = state.players.get_mut(active_idx) {
        player.cash -= final_amount;
    }
    if let Some(owner) = state.players.get_mut(owner_idx) {
        owner.cash += final_amount;
    }

    // Publish rent paid event
    bus.publish_custom(
        "core:rent_paid",
        "core",
        serde_json::json!({
            "from_player_id": cmd.player_id.clone(),
            "to_player_id": owner_id.clone(),
            "amount": final_amount,
            "tile_id": cmd.tile_id.clone(),
            "_state_diff": {
                "from_player_id": cmd.player_id.clone(),
                "to_player_id": owner_id.clone(),
                "from_cash_change": -(final_amount as i64),
                "to_cash_change": final_amount as i64,
            },
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "pay_rent" }),
        state,
    );
}

/// Handle the `auction` command: set active auction state and publish events.
fn handle_auction(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: AuctionCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::auction] failed to parse AuctionCommand: {e}");
            return;
        }
    };

    // Ensure the initiating player is the active player
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

    // Set the active auction
    state.active_auction = Some(ActiveAuction {
        tile_id: cmd.tile_id.clone(),
        highest_bidder: None,
        highest_bid: cmd.starting_bid,
        starting_bid: cmd.starting_bid,
    });

    // Publish auction started event
    bus.publish_custom(
        "core:auction_started",
        "core",
        serde_json::json!({
            "tile_id": cmd.tile_id.clone(),
            "starting_bid": cmd.starting_bid,
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "auction" }),
        state,
    );
}

/// Handle the `bid` command: update the highest bid in the active auction.
fn handle_bid(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: BidCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::bid] failed to parse BidCommand: {e}");
            return;
        }
    };

    // Ensure there is an active auction
    let active_auction = match &state.active_auction {
        Some(a) => a.clone(),
        None => {
            bus.publish_custom(
                "core:command_rejected",
                "core",
                serde_json::json!({ "reason": "No active auction" }),
                state,
            );
            return;
        }
    };

    // If the bid is higher than the current highest, update the auction
    if cmd.amount > active_auction.highest_bid {
        state.active_auction = Some(ActiveAuction {
            tile_id: active_auction.tile_id.clone(),
            highest_bidder: Some(cmd.player_id.clone()),
            highest_bid: cmd.amount,
            starting_bid: active_auction.starting_bid,
        });
    }

    // Publish bid placed event
    bus.publish_custom(
        "core:bid_placed",
        "core",
        serde_json::json!({
            "player_id": cmd.player_id.clone(),
            "amount": cmd.amount,
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "bid" }),
        state,
    );
}

/// Handle the `trade` command: validate both players exist and publish trade proposal.
fn handle_trade(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: TradeCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::trade] failed to parse TradeCommand: {e}");
            return;
        }
    };

    // Ensure the initiating player is the active player
    let active_idx = state.active_player_index;
    if state.players.get(active_idx).map(|p| p.id.as_str()) != Some(&cmd.from_player_id) {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "Not your turn" }),
            state,
        );
        return;
    }

    // Validate both players exist
    let from_exists = state.players.iter().any(|p| p.id == cmd.from_player_id);
    let to_exists = state.players.iter().any(|p| p.id == cmd.to_player_id);

    if !from_exists || !to_exists {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "One or both players not found" }),
            state,
        );
        return;
    }

    // Publish trade proposed event
    bus.publish_custom(
        "core:trade_proposed",
        "core",
        serde_json::json!({
            "from_player_id": cmd.from_player_id.clone(),
            "to_player_id": cmd.to_player_id.clone(),
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "trade" }),
        state,
    );
}

/// Handle the `config_get` command: simulate loading a config value.
fn handle_config_get(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: ConfigGetCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::config_get] failed to parse ConfigGetCommand: {e}");
            return;
        }
    };

    // Publish config loaded event with a simulated value
    bus.publish_custom(
        "core:config_loaded",
        "core",
        serde_json::json!({
            "key": cmd.key.clone(),
            "value": "simulated_value",
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "config_get" }),
        state,
    );
}

/// Handle the `config_set` command: publish an updated config value.
fn handle_config_set(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: ConfigSetCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::config_set] failed to parse ConfigSetCommand: {e}");
            return;
        }
    };

    // Publish config updated event
    bus.publish_custom(
        "core:config_updated",
        "core",
        serde_json::json!({
            "key": cmd.key.clone(),
            "value": cmd.value,
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "config_set" }),
        state,
    );
}

/// Handle the `sell_shares` command: validate shares ownership, execute sale.
fn handle_sell_shares(
    state: &mut GameState,
    event: AnyEvent,
    _rng: &mut dyn RngService,
    bus: &mut EventBus,
) {
    // Parse the command
    let cmd: SellSharesCommand = match event.into_typed() {
        Ok(c) => c,
        Err(e) => {
            log::error!("[builtin::sell_shares] failed to parse SellSharesCommand: {e}");
            return;
        }
    };

    // Ensure the selling player is the active player
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

    // Check the player has enough shares
    let has_shares = match state.players.get(active_idx) {
        Some(player) => player.stock_shares >= cmd.shares,
        None => false,
    };

    if !has_shares {
        bus.publish_custom(
            "core:command_rejected",
            "core",
            serde_json::json!({ "reason": "Insufficient shares" }),
            state,
        );
        return;
    }

    // Execute sale: deduct shares and add cash (simplified price: shares * 100)
    let total_price = cmd.shares as i64 * 100;
    if let Some(player) = state.players.get_mut(active_idx) {
        player.stock_shares -= cmd.shares;
        player.cash += total_price;
    }

    // Publish shares sold event
    bus.publish_custom(
        "core:shares_sold",
        "core",
        serde_json::json!({
            "player_id": cmd.player_id.clone(),
            "shares": cmd.shares,
            "total_price": total_price,
        }),
        state,
    );

    // Publish command accepted
    bus.publish_custom(
        "core:command_accepted",
        "core",
        serde_json::json!({ "name": "sell_shares" }),
        state,
    );
}
