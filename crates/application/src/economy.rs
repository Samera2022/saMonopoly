use sa_monopoly_domain::DomainError;
use sa_monopoly_domain::GameState;
use sa_monopoly_domain::Money;

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
        let property = state
            .board
            .property_mut(tile_id)
            .ok_or_else(|| DomainError::TileNotFound(tile_id.to_string()))?;
        property.upgrade_level = property.upgrade_level.saturating_add(1);
        Ok(property.upgrade_level)
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
        let mut amount = property.current_rent();

        // ─── Double Rent card check ─────────────────────────────────────────────
        // If the paying player has a "double_rent" card, consume it and double the
        // rent amount.
        let active_idx = state.active_player_index;
        let has_double_rent = state
            .players
            .get(active_idx)
            .map(|p| p.owned_cards.iter().any(|c| c == "double_rent"))
            .unwrap_or(false);

        let mut card_consumed = false;
        if has_double_rent {
            if let Some(player) = state.players.get_mut(active_idx) {
                player.owned_cards.retain(|c| c != "double_rent");
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
                .ok_or_else(|| DomainError::ActivePlayerNotFound)?;

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
