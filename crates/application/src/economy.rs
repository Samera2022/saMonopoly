use sa_monopoly_domain::DomainError;
use sa_monopoly_domain::GameState;
use sa_monopoly_domain::Money;

use crate::event_bus::AnyEvent;

fn make_event(event_type: &str, payload: serde_json::Value) -> AnyEvent {
    AnyEvent::new(event_type, "core", payload)
}

pub struct EconomyService;

impl EconomyService {
    pub fn buy_property(
        state: &mut GameState,
        tile_id: &str,
        player_id: &str,
    ) -> Result<Money, DomainError> {
        // Look up the property's base price first (immutable borrow)
        let base_price = state
            .board
            .property(tile_id)
            .ok_or_else(|| DomainError::TileNotFound(tile_id.to_string()))?
            .base_price;

        // Find the player and deduct cash
        let player = state
            .players
            .iter_mut()
            .find(|p| p.id == player_id)
            .ok_or_else(|| DomainError::PlayerNotFound(player_id.to_string()))?;

        if player.cash < base_price {
            return Err(DomainError::InsufficientFunds {
                have: player.cash,
                need: base_price,
            });
        }
        player.cash -= base_price;

        // Set the property owner
        let property = state
            .board
            .property_mut(tile_id)
            .ok_or_else(|| DomainError::TileNotFound(tile_id.to_string()))?;
        property.owner = Some(player_id.to_string());

        Ok(base_price)
    }

    pub fn upgrade_property(state: &mut GameState, tile_id: &str) -> Result<u32, DomainError> {
        use sa_monopoly_domain::property::PropertyKind;

        // ─── Check max_upgrade_level (0 = disabled) ──────────────────────────
        if state.max_upgrade_level == 0 {
            return Err(DomainError::UpgradesDisabled);
        }

        // ─── Ownership check & kind validation ────────────────────────────────
        let active_player_id = state
            .active_player()
            .map(|p| p.id.clone())
            .ok_or(DomainError::ActivePlayerNotFound)?;

        let (current_level, base) = {
            let property = state
                .board
                .property(tile_id)
                .ok_or_else(|| DomainError::TileNotFound(tile_id.to_string()))?;

            // Only Ordinary properties can be upgraded by default.
            // Extension (utility) properties can only be upgraded when the
            // `extension_upgrade_enabled` flag is set.
            match property.kind {
                PropertyKind::Ordinary => { /* allowed */ }
                PropertyKind::Extension if state.extension_upgrade_enabled => { /* allowed */ }
                PropertyKind::Extension => {
                    return Err(DomainError::InvalidCommand(
                        "extension upgrades are disabled".to_string(),
                    ));
                }
                _ => {
                    return Err(DomainError::InvalidCommand(
                        "only ordinary properties can be upgraded".to_string(),
                    ));
                }
            }

            // Verify ownership
            if property.owner.as_deref() != Some(&active_player_id) {
                return Err(DomainError::UpgradeNotOwned(tile_id.to_string()));
            }

            (property.upgrade_level, property.base_price)
        };

        // ─── Max level check ──────────────────────────────────────────────────
        let max_level = state.max_upgrade_level as u32;
        if current_level >= max_level {
            return Err(DomainError::MaxUpgradeLevel(
                tile_id.to_string(),
                max_level as u64,
            ));
        }

        // ─── Deduct upgrade cost ──────────────────────────────────────────────
        // cost = base * (1 + current_level) / 3
        // This softer curve ensures:
        //   L0→L1: ~33% of base (was 50%)
        //   L1→L2: ~67% of base (was 100%)
        //   L2→L3: 100% of base  (was 150%)
        let cost = base * (1 + current_level as i64) / 3;

        // Check affordability before mutating
        let player = state
            .players
            .get(state.active_player_index)
            .ok_or(DomainError::ActivePlayerNotFound)?;
        if player.cash < cost {
            return Err(DomainError::InsufficientFunds {
                have: player.cash,
                need: cost,
            });
        }

        // ─── Apply upgrade ────────────────────────────────────────────────────
        // Deduct cost from player
        if let Some(player) = state.players.get_mut(state.active_player_index) {
            player.cash -= cost;
        }

        // Increment upgrade level
        let property = state
            .board
            .property_mut(tile_id)
            .ok_or_else(|| DomainError::TileNotFound(tile_id.to_string()))?;
        property.upgrade_level = current_level + 1;

        Ok(property.upgrade_level)
    }

    /// Buy a lottery ticket: player chooses a number (1-50) and pays the
    /// ticket price.
    pub fn buy_lottery_ticket(
        state: &mut GameState,
        number: u32,
    ) -> Result<AnyEvent, String> {
        crate::cards::LotteryService::buy_ticket(state, number)
    }

    /// Use a card from the active player's inventory.
    pub fn use_card(state: &mut GameState, card_id: &str) -> Result<AnyEvent, String> {
        let player_id = state
            .active_player()
            .map(|p| p.id.clone())
            .ok_or("no_active_player".to_string())?;

        // Check that the player actually owns this card
        let has_card = state
            .players
            .get(state.active_player_index)
            .map(|p| p.owned_cards.iter().any(|c| c == card_id))
            .unwrap_or(false);
        if !has_card {
            return Err("card not owned".to_string());
        }

        match card_id {
            "get_out_of_jail" => {
                // Auto-consumed by engine on roll; mark as used
                // Remove only ONE copy of the card (player may hold duplicates)
                if let Some(player) = state.players.get_mut(state.active_player_index) {
                    if let Some(pos) = player.owned_cards.iter().position(|c| c == card_id) {
                        player.owned_cards.swap_remove(pos);
                    }
                    player.jail_turns = 0;
                }
                Ok(make_event(
                    "core:card_used",
                    serde_json::json!({
                        "player_id": player_id,
                        "card_id": card_id,
                    }),
                ))
            }
            "bonus_200" => {
                // Auto-consumed by engine on roll; manually use here
                if let Some(player) = state.players.get_mut(state.active_player_index) {
                    if let Some(pos) = player.owned_cards.iter().position(|c| c == card_id) {
                        player.owned_cards.swap_remove(pos);
                    }
                    player.cash += 200;
                }
                Ok(make_event(
                    "core:card_used",
                    serde_json::json!({
                        "player_id": player_id,
                        "card_id": card_id,
                    }),
                ))
            }
            "double_rent" => {
                // This card is auto-consumed during rent payment;
                // manually mark as ready for next rent
                if let Some(player) = state.players.get_mut(state.active_player_index) {
                    if let Some(pos) = player.owned_cards.iter().position(|c| c == card_id) {
                        player.owned_cards.swap_remove(pos);
                    }
                }
                Ok(make_event(
                    "core:card_used",
                    serde_json::json!({
                        "player_id": player_id,
                        "card_id": card_id,
                    }),
                ))
            }
            "skip_turn" => {
                // Skip the next turn by setting jail_turns = 1 (skip without jail)
                if let Some(player) = state.players.get_mut(state.active_player_index) {
                    if let Some(pos) = player.owned_cards.iter().position(|c| c == card_id) {
                        player.owned_cards.swap_remove(pos);
                    }
                    player.jail_turns = 1;
                }
                Ok(make_event(
                    "core:card_used",
                    serde_json::json!({
                        "player_id": player_id,
                        "card_id": card_id,
                    }),
                ))
            }
            _ => Err("unknown card".to_string()),
        }
    }

    pub fn pay_rent(state: &mut GameState, tile_id: &str) -> Result<(Money, bool), DomainError> {
        // Look up property and extract owner + rent (immutable borrow on board)
        let property = state
            .board
            .property(tile_id)
            .ok_or_else(|| DomainError::TileNotFound(tile_id.to_string()))?;

        let owner_id = property
            .owner
            .as_ref()
            .ok_or_else(|| DomainError::PropertyNotOwned(tile_id.to_string()))?
            .clone();

        // If group rent is enabled, check if the player owns all properties
        // in the same linked group and sum their rents.
        let mut amount = if state.group_rent_enabled {
            state.board.group_rent(tile_id).unwrap_or_else(|| property.current_rent())
        } else {
            property.current_rent()
        };

        // ─── Double Rent card check ─────────────────────────────────────────────
        // If the paying player has a "double_rent" card, consume it and double the
        // rent amount.  The doubling applies before the rent is deducted, making it
        // a powerful swing tool.
        let active_idx = state.active_player_index;
        let has_double_rent = state
            .players
            .get(active_idx)
            .map(|p| p.owned_cards.iter().any(|c| c == "double_rent"))
            .unwrap_or(false);

        let mut card_consumed = false;
        if has_double_rent {
            if let Some(player) = state.players.get_mut(active_idx) {
                // Remove only ONE copy
                if let Some(pos) = player.owned_cards.iter().position(|c| c == "double_rent") {
                    player.owned_cards.swap_remove(pos);
                }
            }
            amount *= 2;
            card_consumed = true;
        }

        // Deduct rent from the active player (current turn)
        // Scope ensures the mutable borrow on players is released before the next step
        {
            let active_player = state
                .players
                .get_mut(active_idx)
                .ok_or(DomainError::ActivePlayerNotFound)?;

            if active_player.cash < amount {
                return Err(DomainError::InsufficientFunds {
                    have: active_player.cash,
                    need: amount,
                });
            }
            active_player.cash -= amount;
        }
        // Mutable borrow on `state.players` released — safe to borrow again

        // Transfer rent to the property owner
        let owner = state
            .players
            .iter_mut()
            .find(|p| p.id == owner_id)
            .ok_or_else(|| DomainError::PlayerNotFound(owner_id.clone()))?;
        owner.cash += amount;

        Ok((amount, card_consumed))
    }
}
