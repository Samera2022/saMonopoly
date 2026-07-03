use sa_monopoly_domain::property::PropertyKind;
use sa_monopoly_domain::tile::TileKind;
use sa_monopoly_domain::{ActiveAuction, GameState};

use crate::cards::StockMarketService;
use crate::commands::GameCommand;
use crate::effects::EffectResolver;
use crate::economy::EconomyService;
use crate::events::GameEvent;
use crate::movement::MovementService;

pub struct GameEngine;

impl GameEngine {
    pub fn execute(
        command: GameCommand,
        state: &mut GameState,
        rng: &mut dyn crate::ports::RngService,
    ) -> GameEvent {
        // Early clone of player id to avoid borrow conflicts throughout the function
        let player_id = state
            .players
            .get(state.active_player_index)
            .map(|p| p.id.clone());

        match command {
            GameCommand::Roll => {
                // Generate dice values
                let dice1 = (rng.next_u64() % 6) + 1;
                let dice2 = (rng.next_u64() % 6) + 1;
                let steps = (dice1 + dice2) as usize;
                let is_doubles = dice1 == dice2;

                let active_idx = state.active_player_index;

                // ─── Get Out of Jail card check ──────────────────────────────────
                // Before the jail/hospital skip, check if player can use card to
                // get out immediately.
                let pid_for_release = player_id.clone().unwrap_or_default();
                let can_use_get_out_of_jail = state
                    .players
                    .get(active_idx)
                    .map(|p| p.jail_turns > 0 && p.owned_cards.iter().any(|c| c == "get_out_of_jail"))
                    .unwrap_or(false);

                if can_use_get_out_of_jail {
                    if let Some(p) = state.players.get_mut(active_idx) {
                        p.owned_cards.retain(|c| c != "get_out_of_jail");
                        p.jail_turns = 0;
                    }
                    return GameEvent::CardConsumed {
                        player_id: pid_for_release,
                        card_id: "get_out_of_jail".to_string(),
                    };
                }

                // Check if player is in jail or hospital → skip turn (decrement counter)
                let status = state
                    .players
                    .get(active_idx)
                    .map(|p| (p.jail_turns, p.hospital_turns))
                    .unwrap_or((0, 0));

                if status.0 > 0 {
                    let pid = player_id.clone().unwrap_or_default();
                    if let Some(p) = state.players.get_mut(active_idx) {
                        p.jail_turns = p.jail_turns.saturating_sub(1);
                        if p.jail_turns == 0 {
                            return GameEvent::PlayerReleasedFromJail { player_id: pid };
                        }
                    }
                    return GameEvent::CommandRejected {
                        reason: "player_in_jail".to_string(),
                    };
                }
                if status.1 > 0 {
                    let pid = player_id.clone().unwrap_or_default();
                    if let Some(p) = state.players.get_mut(active_idx) {
                        p.hospital_turns = p.hospital_turns.saturating_sub(1);
                        if p.hospital_turns == 0 {
                            return GameEvent::PlayerReleasedFromHospital { player_id: pid };
                        }
                    }
                    return GameEvent::CommandRejected {
                        reason: "player_in_hospital".to_string(),
                    };
                }

                // ─── Movement ──────────────────────────────────────────────────────
                if let Some(result) = MovementService::move_steps(state, steps) {
                    let pid = player_id.clone().unwrap_or_default();

                    // Sprint 4: Pass start bonus (+$200)
                    if result.passed_start {
                        if let Some(player) = state.active_player_mut() {
                            player.cash += 200;
                        }
                    }

                    // ─── Sprint 4: Doubles tracking ────────────────────────────────
                    if is_doubles {
                        state.consecutive_doubles += 1;
                    } else {
                        state.consecutive_doubles = 0;
                    }

                    // 3 consecutive doubles → go to jail (no tile effect)
                    if is_doubles && state.consecutive_doubles >= 3 {
                        state.consecutive_doubles = 0;
                        // Clone jail tile ID before mutable borrow
                        let jail_tile_id = state
                            .board
                            .tiles
                            .iter()
                            .find(|t| t.kind == TileKind::Jail)
                            .map(|t| t.id.clone());
                        if let Some(player) = state.active_player_mut() {
                            player.jail_turns = 3;
                            if let Some(jail_id) = jail_tile_id {
                                player.position = jail_id;
                            }
                        }
                        return GameEvent::ThreeDoublesToJail { player_id: pid };
                    }

                    // ─── Tile effect resolution ─────────────────────────────────────
                    let tile_event =
                        EffectResolver::resolve_special_tile(state, &result.to, rng);

                    // ─── Sprint 4: Bankruptcy check after tile effect ───────────────
                    if Self::is_active_player_bankrupt(state) {
                        return GameEvent::PlayerBankrupt { player_id: pid };
                    }

                    // ─── Bonus 200 card check ──────────────────────────────────────
                    // Automatically consume bonus_200 card if player has one and emit
                    // CardConsumed event.
                    if let Some(player) = state.active_player_mut() {
                        if player.owned_cards.iter().any(|c| c == "bonus_200") {
                            player.owned_cards.retain(|c| c != "bonus_200");
                            player.cash += 200;
                            return GameEvent::CardConsumed {
                                player_id: pid,
                                card_id: "bonus_200".to_string(),
                            };
                        }
                    }

                    // ─── Determine return event ────────────────────────────────────
                    if is_doubles {
                        GameEvent::DoublesRolled {
                            dice1,
                            dice2,
                            consecutive: state.consecutive_doubles,
                        }
                    } else {
                        tile_event.unwrap_or(GameEvent::PlayerMoved {
                            player_id: pid,
                            to_tile: result.to,
                        })
                    }
                } else {
                    GameEvent::CommandRejected {
                        reason: "movement_failed".to_string(),
                    }
                }
            }
            GameCommand::BuyProperty { tile_id } => {
                let pid = player_id.clone().unwrap_or_default();
                let event = match state.board.property(&tile_id) {
                    Some(property)
                        if matches!(
                            property.kind,
                            PropertyKind::Ordinary | PropertyKind::Extension
                        ) =>
                    {
                        let can_afford = state
                            .players
                            .get(state.active_player_index)
                            .map(|p| p.can_afford(property.base_price))
                            .unwrap_or(false);
                        if can_afford {
                            let result = EconomyService::buy_property(state, &tile_id, &pid);
                            match result {
                                Ok(_) => GameEvent::PropertyBought {
                                    player_id: pid.clone(),
                                    tile_id,
                                },
                                Err(err) => GameEvent::CommandRejected {
                                    reason: err.to_string(),
                                },
                            }
                        } else {
                            GameEvent::CommandRejected {
                                reason: "insufficient_funds".to_string(),
                            }
                        }
                    }
                    Some(_) => GameEvent::CommandRejected {
                        reason: "cannot_buy_special_property".to_string(),
                    },
                    None => GameEvent::CommandRejected {
                        reason: "tile_not_found".to_string(),
                    },
                };
                // Sprint 4: Bankruptcy check after buying
                if matches!(&event, GameEvent::PropertyBought { .. }) {
                    if Self::is_active_player_bankrupt(state) {
                        return GameEvent::PlayerBankrupt { player_id: pid };
                    }
                }
                event
            }
            GameCommand::UpgradeProperty { tile_id } => {
                let pid = player_id.clone().unwrap_or_default();
                let event = match EconomyService::upgrade_property(state, &tile_id) {
                    Ok(level) => GameEvent::CommandAccepted {
                        name: format!("upgrade_property:{}:{level}", tile_id),
                    },
                    Err(err) => GameEvent::CommandRejected {
                        reason: err.to_string(),
                    },
                };
                // Sprint 4: Bankruptcy check after upgrading
                if matches!(&event, GameEvent::CommandAccepted { .. }) {
                    if Self::is_active_player_bankrupt(state) {
                        return GameEvent::PlayerBankrupt { player_id: pid };
                    }
                }
                event
            }
            GameCommand::PayRent { tile_id } => {
                let pid = player_id.clone().unwrap_or_default();
                let (amount, card_consumed) = match EconomyService::pay_rent(state, &tile_id) {
                    Ok(result) => result,
                    Err(err) => {
                        return GameEvent::CommandRejected {
                            reason: err.to_string(),
                        }
                    }
                };
                let property = match state.board.property(&tile_id) {
                    Some(p) => p,
                    None => {
                        return GameEvent::CommandRejected {
                            reason: "tile_not_found".to_string(),
                        }
                    }
                };
                // When double_rent card was consumed, emit CardConsumed so the
                // consumption point is observable.  The cash transfer has already
                // happened inside pay_rent with the doubled amount.
                if card_consumed {
                    return GameEvent::CardConsumed {
                        player_id: pid.clone(),
                        card_id: "double_rent".to_string(),
                    };
                }
                // Sprint 4: Bankruptcy check after paying rent
                if Self::is_active_player_bankrupt(state) {
                    return GameEvent::PlayerBankrupt { player_id: pid.clone() };
                }
                GameEvent::RentPaid {
                    from_player_id: pid,
                    to_player_id: property.owner.clone().unwrap_or_default(),
                    amount,
                }
            }
            GameCommand::BuyCard { card_id, price } => {
                let pid = match &player_id {
                    Some(id) => id.clone(),
                    None => {
                        return GameEvent::CommandRejected {
                            reason: "no_active_player".to_string(),
                        }
                    }
                };

                // Verify player can afford the card
                let can_afford = state
                    .players
                    .get(state.active_player_index)
                    .map(|p| p.can_afford(price))
                    .unwrap_or(false);

                if !can_afford {
                    return GameEvent::CommandRejected {
                        reason: "insufficient_funds".to_string(),
                    };
                }

                // Validate card_id against predefined shop cards
                let valid_cards = ["get_out_of_jail", "bonus_200", "double_rent"];
                if !valid_cards.contains(&card_id.as_str()) {
                    return GameEvent::CommandRejected {
                        reason: "invalid_card".to_string(),
                    };
                }

                // Deduct cash and add card to player's inventory
                if let Some(player) = state.players.get_mut(state.active_player_index) {
                    player.cash -= price;
                    player.owned_cards.push(card_id.clone());
                }

                GameEvent::CardBought {
                    player_id: pid,
                    card_id,
                    price,
                }
            }
            GameCommand::Trade {
                from_player_id,
                to_player_id,
                offered_property,
                offered_cash,
                requested_property,
                requested_cash,
            } => {
                // Find player indices to avoid simultaneous mutable borrow conflicts
                let from_idx = state.players.iter().position(|p| p.id == from_player_id);
                let to_idx = state.players.iter().position(|p| p.id == to_player_id);

                let (Some(from_idx), Some(to_idx)) = (from_idx, to_idx) else {
                    return GameEvent::CommandRejected {
                        reason: "player_not_found".to_string(),
                    };
                };

                // Verify offered cash affordability
                if offered_cash > 0 {
                    let from_cash = state.players[from_idx].cash;
                    if from_cash < offered_cash {
                        return GameEvent::CommandRejected {
                            reason: "insufficient_funds".to_string(),
                        };
                    }
                }

                // Verify requested cash affordability
                if requested_cash > 0 {
                    let to_cash = state.players[to_idx].cash;
                    if to_cash < requested_cash {
                        return GameEvent::CommandRejected {
                            reason: "insufficient_funds".to_string(),
                        };
                    }
                }

                // Verify offered property ownership
                if let Some(ref prop_id) = offered_property {
                    let prop = match state.board.property(prop_id) {
                        Some(p) => p,
                        None => {
                            return GameEvent::CommandRejected {
                                reason: "tile_not_found".to_string(),
                            }
                        }
                    };
                    if prop.owner.as_deref() != Some(&from_player_id) {
                        return GameEvent::CommandRejected {
                            reason: "property_not_owned".to_string(),
                        };
                    }
                }

                // Verify requested property ownership (belongs to to_player)
                if let Some(ref prop_id) = requested_property {
                    let prop = match state.board.property(prop_id) {
                        Some(p) => p,
                        None => {
                            return GameEvent::CommandRejected {
                                reason: "tile_not_found".to_string(),
                            }
                        }
                    };
                    if prop.owner.as_deref() != Some(&to_player_id) {
                        return GameEvent::CommandRejected {
                            reason: "requested_property_not_owned".to_string(),
                        };
                    }
                }

                // Execute: Transfer cash
                if offered_cash > 0 {
                    state.players[from_idx].cash -= offered_cash;
                    state.players[to_idx].cash += offered_cash;
                }
                if requested_cash > 0 {
                    state.players[to_idx].cash -= requested_cash;
                    state.players[from_idx].cash += requested_cash;
                }

                // Execute: Transfer properties
                if let Some(ref prop_id) = offered_property {
                    if let Some(prop) = state.board.property_mut(prop_id) {
                        prop.owner = Some(to_player_id.clone());
                    }
                }
                if let Some(ref prop_id) = requested_property {
                    if let Some(prop) = state.board.property_mut(prop_id) {
                        prop.owner = Some(from_player_id.clone());
                    }
                }

                // Sprint 4: Bankruptcy check after trade (check active player)
                if let Some(active_id) = &player_id {
                    if active_id == &from_player_id || active_id == &to_player_id {
                        if Self::is_active_player_bankrupt(state) {
                            return GameEvent::PlayerBankrupt {
                                player_id: active_id.clone(),
                            };
                        }
                    }
                }

                GameEvent::TradeCompleted {
                    from_player_id,
                    to_player_id,
                }
            }
            GameCommand::EndTurn => {
                // Sprint 4: Eliminate bankrupt players before advancing turn
                let eliminated: Vec<String> = state
                    .players
                    .iter()
                    .filter(|p| p.is_bankrupt())
                    .map(|p| p.id.clone())
                    .collect();

                // Remove bankrupt players (reverse order to keep indices stable)
                for pid in &eliminated {
                    if let Some(idx) = state.players.iter().position(|p| p.id == *pid) {
                        state.players.remove(idx);
                        // Adjust active_player_index if removal occurs before or at it
                        if idx < state.active_player_index {
                            state.active_player_index =
                                state.active_player_index.saturating_sub(1);
                        } else if idx == state.active_player_index {
                            // If we removed the active player, wrap back to 0
                            state.active_player_index = 0;
                        }
                    }
                }

                // Sprint 7: Game end detection — if only 0 or 1 player remains, game is over
                if state.players.len() <= 1 {
                    if let Some(winner) = state.players.first() {
                        return GameEvent::GameWon {
                            winner_id: winner.id.clone(),
                            remaining_players: state.players.len() as u32,
                        };
                    }
                }

                // Advance turn
                if !state.players.is_empty() {
                    state.active_player_index =
                        (state.active_player_index + 1) % state.players.len();
                    state.current_turn += 1;
                }

                GameEvent::TurnAdvanced {
                    turn: state.current_turn,
                    eliminated_players: eliminated,
                }
            }
            // ─── Mortgage ──────────────────────────────────────────────────────
            GameCommand::Mortgage { tile_id } => {
                let pid = match &player_id {
                    Some(id) => id.clone(),
                    None => {
                        return GameEvent::CommandRejected {
                            reason: "no_active_player".to_string(),
                        }
                    }
                };

                let property = match state.board.property_mut(&tile_id) {
                    Some(p) => p,
                    None => {
                        return GameEvent::CommandRejected {
                            reason: "tile_not_found".to_string(),
                        }
                    }
                };

                // Verify ownership
                if property.owner.as_deref() != Some(&pid) {
                    return GameEvent::CommandRejected {
                        reason: "property_not_owned".to_string(),
                    };
                }

                // Verify not already mortgaged
                if property.is_mortgaged {
                    return GameEvent::CommandRejected {
                        reason: "already_mortgaged".to_string(),
                    };
                }

                // Mortgage: player receives base_price / 2
                let amount = property.base_price / 2;
                property.is_mortgaged = true;

                if let Some(player) = state.players.get_mut(state.active_player_index) {
                    player.cash += amount;
                }

                GameEvent::PropertyMortgaged {
                    player_id: pid,
                    tile_id,
                    amount,
                }
            }
            // ─── Redeem ────────────────────────────────────────────────────────
            GameCommand::Redeem { tile_id } => {
                let pid = match &player_id {
                    Some(id) => id.clone(),
                    None => {
                        return GameEvent::CommandRejected {
                            reason: "no_active_player".to_string(),
                        }
                    }
                };

                let base_price = match state.board.property(&tile_id) {
                    Some(p) => p.base_price,
                    None => {
                        return GameEvent::CommandRejected {
                            reason: "tile_not_found".to_string(),
                        }
                    }
                };

                let property = match state.board.property_mut(&tile_id) {
                    Some(p) => p,
                    None => {
                        return GameEvent::CommandRejected {
                            reason: "tile_not_found".to_string(),
                        }
                    }
                };

                // Verify ownership
                if property.owner.as_deref() != Some(&pid) {
                    return GameEvent::CommandRejected {
                        reason: "property_not_owned".to_string(),
                    };
                }

                // Verify it is mortgaged
                if !property.is_mortgaged {
                    return GameEvent::CommandRejected {
                        reason: "not_mortgaged".to_string(),
                    };
                }

                // Redeem cost: 50% of base price + 10% interest
                let cost = (base_price / 2) + (base_price / 10);
                let can_afford = state
                    .players
                    .get(state.active_player_index)
                    .map(|p| p.can_afford(cost))
                    .unwrap_or(false);

                if !can_afford {
                    return GameEvent::CommandRejected {
                        reason: "insufficient_funds".to_string(),
                    };
                }

                if let Some(player) = state.players.get_mut(state.active_player_index) {
                    player.cash -= cost;
                }

                property.is_mortgaged = false;

                // Sprint 4: Bankruptcy check after redeeming
                if Self::is_active_player_bankrupt(state) {
                    return GameEvent::PlayerBankrupt { player_id: pid };
                }

                GameEvent::PropertyRedeemed {
                    player_id: pid,
                    tile_id,
                    amount: cost,
                }
            }
            // ─── Auction ──────────────────────────────────────────────────────
            GameCommand::Auction { tile_id, starting_bid } => {
                // Validate property exists, is unowned, and not mortgaged
                let property = match state.board.property(&tile_id) {
                    Some(p) => p,
                    None => {
                        return GameEvent::CommandRejected {
                            reason: "tile_not_found".to_string(),
                        }
                    }
                };

                if property.owner.is_some() {
                    return GameEvent::CommandRejected {
                        reason: "already_owned".to_string(),
                    };
                }

                if property.is_mortgaged {
                    return GameEvent::CommandRejected {
                        reason: "property_mortgaged".to_string(),
                    };
                }

                // If there's already an active auction, resolve it first (simplified:
                // auction is resolved immediately and a new one starts)
                if let Some(active) = state.active_auction.take() {
                    Self::resolve_auction(state, active);
                }

                // Start a new auction
                state.active_auction = Some(ActiveAuction {
                    tile_id: tile_id.clone(),
                    highest_bidder: None,
                    highest_bid: starting_bid,
                    starting_bid,
                });

                GameEvent::AuctionStarted {
                    tile_id,
                    starting_bid,
                }
            }
            // ─── Sell Shares ───────────────────────────────────────────────────
            GameCommand::SellShares {
                player_id,
                shares,
            } => {
                let event = StockMarketService::sell_shares(state, &player_id, shares);
                // Selling shares adds cash, so bankruptcy won't occur, but we keep the
                // check for consistency with other handlers.
                if matches!(&event, GameEvent::SharesSold { .. }) {
                    if Self::is_active_player_bankrupt(state) {
                        return GameEvent::PlayerBankrupt { player_id: player_id.clone() };
                    }
                }
                event
            }
            // ─── Bid ───────────────────────────────────────────────────────────
            GameCommand::Bid {
                player_id,
                amount,
            } => {
                let active_auction = match state.active_auction.as_mut() {
                    Some(a) => a,
                    None => {
                        return GameEvent::CommandRejected {
                            reason: "no_active_auction".to_string(),
                        }
                    }
                };

                // Verify the player exists
                if !state.players.iter().any(|p| p.id == player_id) {
                    return GameEvent::CommandRejected {
                        reason: "player_not_found".to_string(),
                    };
                }

                // Validate bid >= starting_bid and > current highest
                if amount < active_auction.starting_bid {
                    return GameEvent::CommandRejected {
                        reason: "bid_below_starting".to_string(),
                    };
                }

                // For the first bid, check against starting_bid; otherwise against highest_bid
                let min_bid = active_auction
                    .highest_bidder
                    .as_ref()
                    .map(|_| active_auction.highest_bid + 1)
                    .unwrap_or(active_auction.starting_bid);

                if amount < min_bid {
                    return GameEvent::CommandRejected {
                        reason: "bid_too_low".to_string(),
                    };
                }

                // Check player can afford the bid
                let can_afford = state
                    .players
                    .iter()
                    .find(|p| p.id == player_id)
                    .map(|p| p.can_afford(amount))
                    .unwrap_or(false);

                if !can_afford {
                    return GameEvent::CommandRejected {
                        reason: "insufficient_funds".to_string(),
                    };
                }

                // Update the highest bid
                active_auction.highest_bidder = Some(player_id.clone());
                active_auction.highest_bid = amount;

                GameEvent::AuctionBid { player_id, amount }
            }
        }
    }

    /// Check if the active player is bankrupt (cash < 0).
    fn is_active_player_bankrupt(state: &GameState) -> bool {
        state
            .active_player()
            .map(|p| p.is_bankrupt())
            .unwrap_or(false)
    }

    /// Resolve an active auction: transfer the property to the highest bidder.
    fn resolve_auction(state: &mut GameState, auction: ActiveAuction) {
        let Some(winner_id) = &auction.highest_bidder else {
            // No bids were placed — nobody gets the property
            return;
        };

        // Deduct the winning bid from the winner
        if let Some(winner) = state.players.iter_mut().find(|p| p.id == *winner_id) {
            winner.cash = winner.cash.saturating_sub(auction.highest_bid);
        }

        // Transfer ownership
        if let Some(property) = state.board.property_mut(&auction.tile_id) {
            property.owner = Some(winner_id.clone());
        }
    }
}
