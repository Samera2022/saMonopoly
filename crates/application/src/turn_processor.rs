use sa_monopoly_domain::GameState;
use sa_monopoly_domain::event::AnyEvent;
use sa_monopoly_domain::property::Property;
use crate::event_bus::EventBus;
use crate::ports::RngService;

/// Represents the decision a player makes during their turn.
#[derive(Debug, Clone)]
pub enum PlayerDecision {
    /// Player chooses to buy the property they landed on.
    BuyProperty(String), // tile_id
    /// Player chooses to upgrade the property they landed on.
    UpgradeProperty(String), // tile_id
    /// Player chooses to do nothing (skip buying/upgrading, pass).
    Pass,
}

/// A trait for making player decisions during a turn.
pub trait DecisionMaker {
    fn decide_buy_property(
        &mut self,
        state: &GameState,
        tile_id: &str,
        price: i64,
    ) -> PlayerDecision;

    /// Called when the active player lands on their own property.
    /// Return `UpgradeProperty(tile_id)` to upgrade, or `Pass` to skip.
    fn decide_upgrade_property(
        &mut self,
        state: &GameState,
        tile_id: &str,
        current_level: u32,
    ) -> PlayerDecision;
}

// ═══════════════════════════════════════════════════════════════════════════
// Human-level Monopoly AI strategy
// ═══════════════════════════════════════════════════════════════════════════

/// Strategic, human-level AI decision maker for Monopoly.
///
/// ## Strategy Principles
///
/// 1. **Color-group priority** — completing a color group is the #1 goal.
///    Orange > Red > Light Blue > Pink > Brown > Yellow > Green > Blue
///    based on ROI and board position (distance from Jail).
///
/// 2. **Selective buying** — not every property is worth buying:
///    - Always buy if it completes a color group (even mortgage others)
///    - Always buy if you already own 50%+ of a color group
///    - Buy railroads aggressively (4 railroads = steady income)
///    - Skip overpriced singles (Green/Blue) unless you already own one
///    - Maintain cash reserve to avoid bankruptcy
///
/// 3. **Strategic upgrading** — only upgrade when you own the full group:
///    - Prioritize cheapest full group first (faster ROI)
///    - Keep cash reserve of ~20% of total assets
///    - Build evenly (each to L1 before L2, etc.)
///
/// 4. **Cash management** — keep safety buffer based on game phase:
///    - Early game: $300-500 reserve
///    - Mid game: proportional to owned property value
///    - Never spend more than 70% of cash on a single property
///
/// 5. **Jail strategy** — pay bail early, stay jailed late:
///    - First 10 turns: pay bail (need to acquire properties)
///    - After owning 3+ properties: stay in jail (avoid opponent rent)
pub struct StrategicAiDecisionMaker;

impl StrategicAiDecisionMaker {
    /// Score a property from 0-100 based on its desirability.
    /// Used by both buying and upgrading decisions.
    pub fn score_property(state: &GameState, tile_id: &str, player_id: &str) -> i64 {
        let property = match state.board.property(tile_id) {
            Some(p) => p,
            None => return 0,
        };

        let price = property.base_price;
        if price <= 0 {
            return 0;
        }

        // ── 1. Group analysis ─────────────────────────────────────────
        let group_members: Vec<&str> = property.linked_targets
            .iter()
            .map(|s| s.as_str())
            .collect();
        let group_size = group_members.len() + 1; // +1 for this property itself

        let owned_in_group = if group_size > 1 {
            state.board.properties.iter()
                .filter(|p| {
                    p.owner.as_deref() == Some(player_id)
                        && (p.tile_id == tile_id
                            || group_members.contains(&p.tile_id.as_str()))
                })
                .count()
        } else {
            0
        };

        let missing_for_monopoly = group_size.saturating_sub(owned_in_group);

        // ── 2. Group completion bonus ─────────────────────────────────
        let completion_bonus: i64 = if missing_for_monopoly == 1 {
            // Would complete the group! High priority.
            match group_size {
                2 => 80,  // 2-property group: very easy to complete
                3 => 100, // 3-property group: big value
                _ => 60,
            }
        } else if owned_in_group >= 1 {
            // Already own some in this group
            match group_size {
                2 => 40,  // One more to complete
                3 => 60,  // Need 2 more
                _ => 20,
            }
        } else {
            // Don't own any in this group yet
            0
        };

        // ── 3. ROI score (rent vs cost) ──────────────────────────────
        // Rent at level 3 (max before hotel): base_price * 4 / 10
        let rent_l3 = price * 4 / 10;
        // Total upgrade cost to level 3: price/3 + 2*price/3 + price = 2*price
        let upgrade_cost_total = price / 3 + price * 2 / 3 + price;
        // Annualized ROI: 4 turns around the board, each paying rent_l3
        let roi = if upgrade_cost_total > 0 {
            (rent_l3 as f64 / upgrade_cost_total as f64) * 100.0
        } else {
            0.0
        };

        let roi_score = (roi * 10.0) as i64; // 0-~60 scale

        // ── 4. Price score (cheaper = easier to complete groups) ──────
        let price_score = match price {
            0..=60 => 30,
            61..=100 => 25,
            101..=160 => 20,
            161..=220 => 15,
            221..=300 => 10,
            _ => 5,
        };

        // ── 5. Board position score ────────────────────────────────────
        // Properties after Jail are landed on most (dice probability).
        // We score by approximate distance from Jail.
        let position_score = Self::position_value(state, tile_id);

        // ── 6. Railroad premium ───────────────────────────────────────
        let railroad_bonus = if Self::is_railroad(state, tile_id) {
            let owned_rrs = Self::count_railroads_owned(state, player_id);
            match owned_rrs {
                0 => 20, // First RR: good
                1 => 35, // Second: great
                2 => 50, // Third: excellent
                3 => 70, // Completes the set!
                _ => 10,
            }
        } else {
            0
        };

        // ── 7. Utility premium ───────────────────────────────────────
        let utility_bonus = if Self::is_utility(state, tile_id) {
            let owned_utils = Self::count_utilities_owned(state, player_id);
            if owned_utils >= 1 {
                25 // Completes the utility set
            } else {
                15 // First utility
            }
        } else {
            0
        };

        // ── 8. Keep only affordable properties ────────────────────────
        // Don't score too high if we can't afford it
        let cash = state.players.iter()
            .find(|p| p.id == player_id)
            .map(|p| p.cash)
            .unwrap_or(0);

        let affordability_penalty = if cash < price + 100 {
            -50 // Very tight — checked first (stricter condition)
        } else if cash < price + 200 {
            -30 // Tight on cash
        } else {
            0
        };

        completion_bonus + roi_score + price_score + position_score
            + railroad_bonus + utility_bonus + affordability_penalty
    }

    /// Position value based on distance from key tiles (Jail and Hospital).
    ///
    /// ## Why distance from Jail/Hospital matters
    ///
    /// In Monopoly, Jail is the most common "starting point" on the board:
    /// players frequently land on "Go to Jail" or draw cards that send them
    /// there.  When leaving Jail, players roll two dice, and the most common
    /// sum is **7** (6/36 ≈ 16.7%), followed by 6 and 8 (5/36 each).
    ///
    /// Therefore properties that are 6-9 spaces after Jail get the highest
    /// foot traffic, generating the most rent income for their owner.
    /// The same logic applies to Hospital, which also serves as a respawn
    /// point that players leave by rolling dice.
    ///
    /// This function finds the nearest respawn point (Jail or Hospital) and
    /// scores properties based on dice-probability-weighted distance from it.
    fn position_value(state: &GameState, tile_id: &str) -> i64 {
        // Find all respawn tiles (Jail and Hospital)
        let respawn_indices: Vec<usize> = state.board.tiles.iter()
            .enumerate()
            .filter(|(_, t)| {
                let kind = t.kind.to_lowercase();
                kind == "jail" || kind.contains("jail")
                    || kind == "hospital" || kind.contains("hospital")
            })
            .map(|(i, _)| i)
            .collect();

        if respawn_indices.is_empty() {
            return 10;
        }

        let tile_idx = match state.board.tile_index(tile_id) {
            Some(i) => i,
            None => return 10,
        };

        let n = state.board.tiles.len();

        // For each respawn point, calculate the forward distance from it
        // to this tile, then score based on dice probability.
        let mut best_score: i64 = 0;

        for &respawn in &respawn_indices {
            let dist = if tile_idx >= respawn {
                tile_idx - respawn
            } else {
                n - respawn + tile_idx
            };

            // Dice probability-based scoring (most common rolls = highest score)
            // Dice sum probabilities from 2d6:
            //   7 → 6/36 (16.7%),  6 or 8 → 5/36 (13.9%)
            //   5 or 9 → 4/36 (11.1%),  4 or 10 → 3/36 (8.3%)
            //   3 or 11 → 2/36 (5.6%),  2 or 12 → 1/36 (2.8%)
            let score = match dist {
                7 => 25,
                6 | 8 => 22,
                5 | 9 => 18,
                4 | 10 => 14,
                3 | 11 => 10,
                2 | 12 => 6,
                13..=20 => 10 + (20 - dist as i64) / 2,
                _ => 5,
            };

            if score > best_score {
                best_score = score;
            }
        }

        if best_score > 0 { best_score } else { 10 }
    }

    /// Check if a tile is a railroad (identified by name or color_group in JSON).
    #[allow(unused_variables)]
    fn is_railroad(_state: &GameState, tile_id: &str) -> bool {
        // Railroads are ordinary_property tiles with "rr_" prefix in classic map
        tile_id.starts_with("rr_") || tile_id.to_lowercase().contains("railroad")
    }

    /// Count how many railroads a player owns.
    fn count_railroads_owned(state: &GameState, player_id: &str) -> usize {
        state.board.properties.iter()
            .filter(|p| {
                p.owner.as_deref() == Some(player_id)
                    && (p.tile_id.starts_with("rr_")
                        || p.tile_id.to_lowercase().contains("railroad"))
            })
            .count()
    }

    /// Check if a tile is a utility/extension property.
    fn is_utility(state: &GameState, tile_id: &str) -> bool {
        state.board.property(tile_id)
            .map(|p| p.tile_id.starts_with("util_"))
            .unwrap_or(false)
    }

    /// Count how many utilities a player owns.
    fn count_utilities_owned(state: &GameState, player_id: &str) -> usize {
        state.board.properties.iter()
            .filter(|p| {
                p.owner.as_deref() == Some(player_id)
                    && p.tile_id.starts_with("util_")
            })
            .count()
    }

    /// Get the best property for this player to upgrade.
    /// Returns (tile_id, priority_score).
    pub fn best_upgrade_target(state: &GameState, player_id: &str) -> Option<(String, i64)> {
        let owned_properties: Vec<&Property> = state.board.properties.iter()
            .filter(|p| p.owner.as_deref() == Some(player_id))
            .collect();

        if owned_properties.is_empty() {
            return None;
        }

        let player = state.players.iter().find(|p| p.id == player_id)?;
        let cash = player.cash;

        // Calculate safety reserve based on worst-case opponent rent.
        let safety_reserve = Self::required_safety_reserve(state, player_id);

        // Analyze which color groups are fully owned
        let mut candidates: Vec<(String, i64)> = Vec::new();

        for prop in &owned_properties {
            let tile_id = &prop.tile_id;
            let group: Vec<&str> = prop.linked_targets.iter().map(|s| s.as_str()).collect();

            if group.is_empty() {
                continue; // No group defined — can't benefit from group bonus
            }

            // Check if player owns ALL properties in this group
            let all_owned = group.iter().all(|tid| {
                state.board.property(tid)
                    .and_then(|p| p.owner.as_deref())
                    == Some(player_id)
            });

            if !all_owned {
                continue; // Don't upgrade incomplete groups
            }

            // Calculate upgrade cost
            let cost = prop.upgrade_cost();
            let next_level = prop.upgrade_level + 1;

            if next_level > state.max_upgrade_level as u32 {
                continue; // Already at max level
            }

            // Check affordability: must survive 3× the highest opponent rent
            if cash < cost + safety_reserve {
                continue; // Can't afford with reserve
            }

            // Upgrading the property with the LOWEST level in the group = even build
            let min_level = group.iter()
                .filter_map(|tid| state.board.property(tid))
                .map(|p| p.upgrade_level)
                .min()
                .unwrap_or(0);

            let is_lowest = prop.upgrade_level <= min_level;

            // Score: prefer cheap groups, even distribution, and group with highest ROI
            let rent_increase = prop.current_rent() * 2 - prop.current_rent(); // rent doubles each level
            let roi = if cost > 0 { rent_increase as f64 / cost as f64 } else { 0.0 };

            let mut priority = (roi * 50.0) as i64;
            if is_lowest {
                priority += 30; // Even building bonus
            }
            if prop.upgrade_level == 0 {
                priority += 20; // First upgrade in group is most impactful
            }
            // Penalty for high-level upgrades (diminishing returns)
            priority -= (prop.upgrade_level as i64) * 5;

            candidates.push((tile_id.clone(), priority));
        }

        // Sort by priority descending
        candidates.sort_by(|a, b| b.1.cmp(&a.1));
        candidates.into_iter().next()
    }

    /// Decide whether the AI should buy the property they just landed on.
    /// Returns true if the AI should buy.
    pub fn evaluate_buy(state: &GameState, tile_id: &str, player_id: &str) -> bool {
        let property = match state.board.property(tile_id) {
            Some(p) => p,
            None => return false,
        };

        // Already owned
        if property.owner.is_some() {
            return false;
        }

        let price = property.base_price;
        let player = match state.players.iter().find(|p| p.id == player_id) {
            Some(p) => p,
            None => return false,
        };

        let cash = player.cash;

        // Can't afford
        if cash < price {
            return false;
        }

        // ── Rule 1: Always buy if it completes a color group ────
        let group: Vec<&str> = property.linked_targets.iter()
            .map(|s| s.as_str())
            .collect();

        if !group.is_empty() {
            let all_others_owned = group.iter().all(|tid| {
                state.board.property(tid)
                    .and_then(|p| p.owner.as_deref())
                    == Some(player_id)
            });
            if all_others_owned {
                // Completes the group — buy even if it hurts
                return true;
            }

            // ── Rule 2: Strong buy if already own 50%+ of group ──
            let owned_in_group = group.iter()
                .filter(|tid| {
                    state.board.property(tid)
                        .and_then(|p| p.owner.as_deref())
                        == Some(player_id)
                })
                .count();
            let group_size = group.len() + 1; // +1 for this property

            // Own more than half of the group members (excluding self)
            let owns_majority = owned_in_group * 2 > group.len();
            if owns_majority && group_size <= 3 {
                // Close to completing a small group
                let remaining_cost: i64 = group.iter()
                    .filter(|tid| {
                        state.board.property(tid)
                            .and_then(|p| p.owner.as_deref())
                            != Some(player_id)
                    })
                    .filter_map(|tid| state.board.property(tid))
                    .map(|p| p.base_price)
                    .sum();

                if cash >= remaining_cost + price + 200 {
                    return true; // Can afford to complete the group
                }
            }

            // ── Rule 3: Own 2 of 3 in the group — strong buy ──
            if owned_in_group >= 2 {
                return true; // One away from monopoly
            }

            // ── Rule 3b: Denial buy — block opponents from completing group ──
            // If any opponent owns at least half of this group's properties,
            // buy this one to deny them the group rent bonus.
            for opponent in &state.players {
                if opponent.id == player_id { continue; }
                let opp_owned = group.iter()
                    .filter(|tid| {
                        state.board.property(tid)
                            .and_then(|p| p.owner.as_deref())
                            == Some(&opponent.id)
                    })
                    .count();
                // Opponent owns at least half the group and we can afford it
                let half = (group_size as f64 / 2.0).ceil() as usize;
                if opp_owned >= half && opp_owned > 0 {
                    if cash >= price + 100 {
                        return true;
                    }
                }
            }
        }

        // ── Rule 4: Railroad — buy aggressively ───────────────
        if Self::is_railroad(state, tile_id) {
            if cash >= price + 200 {
                return true; // Always buy railroads with reasonable reserve
            }
        }

        // ── Rule 5: Utility — buy if can afford both ──────────
        if Self::is_utility(state, tile_id) {
            let owned_utils = Self::count_utilities_owned(state, player_id);
            let total_utils = state.board.properties.iter()
                .filter(|p| Self::is_utility(state, &p.tile_id))
                .count();
            if owned_utils >= 1 || total_utils <= 1 {
                if cash >= price + 200 {
                    return true;
                }
            }
        }

        // ── Rule 6: Score-based decision ──────────────────────
        let score = Self::score_property(state, tile_id, player_id);

        // Dynamic threshold based on cash position.
        let threshold = if cash > 1000 {
            40 // Early game (>$1000): buy most things
        } else if cash > 500 {
            55 // Mid game ($500-$1000): moderate selectivity
        } else {
            70 // Late game (<$500): only buy premium properties
        };

        if score >= threshold {
            return true;
        }

        // ── Rule 7: Never buy very expensive properties if cash is tight ──
        if price > cash / 2 {
            return false; // Don't spend more than 50% of cash on one property
        }

        // ── Rule 8: Fallback — buy any unowned property if cash is plentiful ──
        // In early game with plenty of cash, having more properties is always
        // better. This ensures the AI doesn't skip too many properties.
        if cash > price + 300 {
            return true;
        }

        false
    }

    /// Calculate the minimum cash reserve needed to survive 3× the highest
    /// opponent rent on the board (including group rent).
    ///
    /// If no opponent owns any property, falls back to a flat $200 minimum.
    pub fn required_safety_reserve(state: &GameState, player_id: &str) -> i64 {
        let max_rent = state.board.properties.iter()
            .filter(|p| {
                // Only consider properties owned by other players
                p.owner.as_deref().map_or(false, |owner| owner != player_id)
            })
            .filter_map(|p| {
                let base_rent = p.current_rent();
                if base_rent <= 0 {
                    return None;
                }
                // Check if this property has group rent (field is on GameState, not Board)
                if state.group_rent_enabled && !p.linked_targets.is_empty() {
                    // Get the group rent (sum of all group members' current rent)
                    if let Some(group_total) = state.board.group_rent(&p.tile_id) {
                        return Some(group_total);
                    }
                }
                Some(base_rent)
            })
            .max()
            .unwrap_or(0);
        // Buffer: survive 3 rounds of worst-case rent + a small buffer
        let reserve = max_rent * 3 + 200;
        // But also ensure at least $100 minimum
        reserve.max(100)
    }
}

impl DecisionMaker for StrategicAiDecisionMaker {
    fn decide_buy_property(
        &mut self,
        state: &GameState,
        tile_id: &str,
        price: i64,
    ) -> PlayerDecision {
        if price <= 0 {
            return PlayerDecision::Pass;
        }

        let player_id = match state.active_player() {
            Some(p) => p.id.clone(),
            None => return PlayerDecision::Pass,
        };

        if Self::evaluate_buy(state, tile_id, &player_id) {
            PlayerDecision::BuyProperty(tile_id.to_string())
        } else {
            PlayerDecision::Pass
        }
    }

    fn decide_upgrade_property(
        &mut self,
        state: &GameState,
        tile_id: &str,
        _current_level: u32,
    ) -> PlayerDecision {
        let player_id = match state.active_player() {
            Some(p) => p.id.clone(),
            None => return PlayerDecision::Pass,
        };

        let property = match state.board.property(tile_id) {
            Some(p) => p,
            None => return PlayerDecision::Pass,
        };

        // Check if this property's group is fully owned
        let group: Vec<&str> = property.linked_targets.iter()
            .map(|s| s.as_str())
            .collect();

        if group.is_empty() {
            return PlayerDecision::Pass;
        }

        let all_owned = group.iter().all(|tid| {
            state.board.property(tid)
                .and_then(|p| p.owner.as_deref())
                == Some(&player_id)
        });

        if !all_owned {
            return PlayerDecision::Pass; // Don't upgrade incomplete groups
        }

        // Check affordability
        let cost = property.upgrade_cost();
        let player = match state.players.iter().find(|p| p.id == player_id) {
            Some(p) => p,
            None => return PlayerDecision::Pass,
        };

        let safety_reserve = Self::required_safety_reserve(state, &player_id);
        if player.cash < cost + safety_reserve {
            return PlayerDecision::Pass;
        }

        // Check max upgrade level
        let next_level = property.upgrade_level + 1;
        if next_level > state.max_upgrade_level as u32 {
            return PlayerDecision::Pass;
        }

        // Even building: only upgrade if this is the lowest-level property in the group
        let min_level = group.iter()
            .filter_map(|tid| state.board.property(tid))
            .map(|p| p.upgrade_level)
            .min()
            .unwrap_or(0);

        if property.upgrade_level <= min_level {
            PlayerDecision::UpgradeProperty(tile_id.to_string())
        } else {
            PlayerDecision::Pass
        }
    }
}

/// Legacy simple AI decision maker (kept for backward compatibility).
pub struct AiDecisionMaker;

impl DecisionMaker for AiDecisionMaker {
    fn decide_buy_property(
        &mut self,
        state: &GameState,
        tile_id: &str,
        price: i64,
    ) -> PlayerDecision {
        if price <= 0 {
            return PlayerDecision::Pass;
        }
        // Only buy if the AI can afford it and keeps at least $50 reserve.
        if let Some(player) = state.active_player() {
            if player.cash >= price + 50 {
                return PlayerDecision::BuyProperty(tile_id.to_string());
            }
        }
        PlayerDecision::Pass
    }

    fn decide_upgrade_property(
        &mut self,
        _state: &GameState,
        _tile_id: &str,
        _current_level: u32,
    ) -> PlayerDecision {
        PlayerDecision::Pass
    }
}

/// Processes a complete turn for the active player.
pub struct TurnProcessor;

impl TurnProcessor {
    /// Execute a full turn for the active player, publishing events through
    /// the `EventBus` instead of returning them as a `Vec<GameEvent>`.
    pub fn process_turn_with_bus(
        state: &mut GameState,
        rng: &mut dyn RngService,
        _decision_maker: &mut dyn DecisionMaker,
        bus: &mut EventBus,
    ) {
        // Phase 1: Roll
        let player_id = state.active_player()
            .map(|p| p.id.clone())
            .unwrap_or_default();
        let roll_cmd = AnyEvent::Custom {
            category: "game".to_string(),
            event_type: "core:command:roll".to_string(),
            source: "core".to_string(),
            payload: serde_json::json!({ "player_id": player_id }),
            timestamp: 0,
        };
        bus.execute_command(roll_cmd, state, rng);

        // NOTE: end_turn is NOT called here — Flutter handles it after
        // the AI/LLM finishes its post-movement decisions (buy, upgrade,
        // etc.).  This ensures the AI is still the active player when
        // making purchases.
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sa_monopoly_domain::{
        Board, BoardGraph, Player,
        tile::{Tile, tile_types},
        property::{Property, PropertyKind},
    };

    fn make_tile(id: &str, kind: &str) -> Tile {
        Tile {
            id: id.to_string(),
            name_key: format!("tile.{}", id),
            kind: kind.to_string(),
            linked_property_kind: None,
        }
    }

    fn make_property(tile_id: &str, price: i64, owner: Option<&str>) -> Property {
        Property {
            tile_id: tile_id.to_string(),
            name_key: format!("prop.{}", tile_id),
            kind: PropertyKind::Ordinary,
            base_price: price,
            rent: vec![price / 10],
            upgrade_level: 0,
            owner: owner.map(String::from),
            is_mortgaged: false,
            linked_targets: vec![],
        }
    }

    fn make_player(id: &str, cash: i64) -> Player {
        Player {
            id: id.to_string(),
            name: id.to_string(),
            cash,
            position: "start".to_string(),
            is_ai: true,
            is_llm_controlled: false,
            jail_turns: 0,
            hospital_turns: 0,
            owned_cards: vec![],
            stock_shares: 0,
            team_id: None,
        }
    }

    /// Build a minimal state with given properties and a player.
    fn make_state(
        tiles: Vec<Tile>,
        properties: Vec<Property>,
        players: Vec<Player>,
        active_idx: usize,
    ) -> GameState {
        GameState {
            board: Board {
                tiles,
                properties,
                graph: BoardGraph::default(),
                auto_link_rent: false,
            },
            players,
            ruleset: sa_monopoly_domain::rules::RuleSetRef {
                id: "test".to_string(),
                version: "1.0.0".to_string(),
            },
            current_turn: 0,
            active_player_index: active_idx,
            seed: 42,
            decks: vec![],
            stock_market: None,
            active_auction: None,
            consecutive_doubles: 0,
            max_upgrade_level: 3,
            extension_upgrade_enabled: false,
            group_rent_enabled: false,
            lottery_state: None,
            bail_abuse_count: 0,
            pending_events: vec![],
        }
    }

    #[test]
    fn test_strategic_ai_buys_affordable_property() {
        let tiles = vec![
            make_tile("start", tile_types::START),
            make_tile("prop_1", tile_types::ORDINARY_PROPERTY),
        ];
        let properties = vec![make_property("prop_1", 100, None)];
        let players = vec![make_player("p1", 1000)];
        let state = make_state(tiles, properties, players, 0);

        assert!(StrategicAiDecisionMaker::evaluate_buy(&state, "prop_1", "p1"));
    }

    #[test]
    fn test_strategic_ai_skips_unaffordable() {
        let tiles = vec![
            make_tile("start", tile_types::START),
            make_tile("prop_1", tile_types::ORDINARY_PROPERTY),
        ];
        let properties = vec![make_property("prop_1", 500, None)];
        let players = vec![make_player("p1", 100)];
        let state = make_state(tiles, properties, players, 0);

        assert!(!StrategicAiDecisionMaker::evaluate_buy(&state, "prop_1", "p1"));
    }

    #[test]
    fn test_strategic_ai_completes_group() {
        let tiles = vec![
            make_tile("start", tile_types::START),
            make_tile("prop_1", tile_types::ORDINARY_PROPERTY),
            make_tile("prop_2", tile_types::ORDINARY_PROPERTY),
        ];
        let mut p1 = make_property("prop_1", 100, Some("p1"));
        p1.linked_targets = vec!["prop_2".to_string()];
        let p2 = make_property("prop_2", 100, None);
        let players = vec![make_player("p1", 1000)];
        let state = make_state(tiles, vec![p1, p2], players, 0);

        // p1 already owns prop_1, buying prop_2 completes the brown group
        assert!(StrategicAiDecisionMaker::evaluate_buy(&state, "prop_2", "p1"));
    }

    #[test]
    fn test_strategic_ai_skips_already_owned() {
        let tiles = vec![
            make_tile("start", tile_types::START),
            make_tile("prop_1", tile_types::ORDINARY_PROPERTY),
        ];
        let properties = vec![make_property("prop_1", 100, Some("other"))];
        let players = vec![make_player("p1", 1000)];
        let state = make_state(tiles, properties, players, 0);

        assert!(!StrategicAiDecisionMaker::evaluate_buy(&state, "prop_1", "p1"));
    }

    #[test]
    fn test_strategic_ai_buys_railroad() {
        let tiles = vec![
            make_tile("start", tile_types::START),
            make_tile("rr_1", tile_types::ORDINARY_PROPERTY),
        ];
        let properties = vec![make_property("rr_1", 200, None)];
        let players = vec![make_player("p1", 1500)];
        let state = make_state(tiles, properties, players, 0);

        assert!(StrategicAiDecisionMaker::evaluate_buy(&state, "rr_1", "p1"));
    }

    #[test]
    fn test_strategic_ai_upgrade_needs_full_group() {
        // Player owns prop_1 but NOT prop_2 — should not upgrade
        let tiles = vec![
            make_tile("start", tile_types::START),
            make_tile("prop_1", tile_types::ORDINARY_PROPERTY),
            make_tile("prop_2", tile_types::ORDINARY_PROPERTY),
        ];
        let mut p1 = make_property("prop_1", 100, Some("p1"));
        p1.linked_targets = vec!["prop_2".to_string()];
        let p2 = make_property("prop_2", 100, None);
        let players = vec![make_player("p1", 1000)];
        let state = make_state(tiles, vec![p1, p2], players, 0);

        let mut ai = StrategicAiDecisionMaker;
        let decision = ai.decide_upgrade_property(&state, "prop_1", 0);
        assert!(matches!(decision, PlayerDecision::Pass));
    }

    #[test]
    fn test_strategic_ai_upgrades_when_full_group() {
        let tiles = vec![
            make_tile("start", tile_types::START),
            make_tile("prop_1", tile_types::ORDINARY_PROPERTY),
            make_tile("prop_2", tile_types::ORDINARY_PROPERTY),
        ];
        let mut p1 = make_property("prop_1", 100, Some("p1"));
        p1.linked_targets = vec!["prop_2".to_string()];
        let mut p2 = make_property("prop_2", 100, Some("p1"));
        p2.linked_targets = vec!["prop_1".to_string()];
        let players = vec![make_player("p1", 1000)];
        let state = make_state(tiles, vec![p1, p2], players, 0);

        let mut ai = StrategicAiDecisionMaker;
        let decision = ai.decide_upgrade_property(&state, "prop_1", 0);
        assert!(matches!(decision, PlayerDecision::UpgradeProperty(_)));
    }

    #[test]
    fn test_best_upgrade_target_returns_some() {
        let tiles = vec![
            make_tile("start", tile_types::START),
            make_tile("prop_1", tile_types::ORDINARY_PROPERTY),
            make_tile("prop_2", tile_types::ORDINARY_PROPERTY),
        ];
        let mut p1 = make_property("prop_1", 100, Some("p1"));
        p1.linked_targets = vec!["prop_2".to_string()];
        let mut p2 = make_property("prop_2", 100, Some("p1"));
        p2.linked_targets = vec!["prop_1".to_string()];
        let players = vec![make_player("p1", 1000)];
        let state = make_state(tiles, vec![p1, p2], players, 0);

        let result = StrategicAiDecisionMaker::best_upgrade_target(&state, "p1");
        assert!(result.is_some());
        let (tile_id, _score) = result.unwrap();
        assert!(tile_id == "prop_1" || tile_id == "prop_2");
    }

    #[test]
    fn test_best_upgrade_none_without_full_group() {
        let tiles = vec![
            make_tile("start", tile_types::START),
            make_tile("prop_1", tile_types::ORDINARY_PROPERTY),
            make_tile("prop_2", tile_types::ORDINARY_PROPERTY),
        ];
        let mut p1 = make_property("prop_1", 100, Some("p1"));
        p1.linked_targets = vec!["prop_2".to_string()];
        let p2 = make_property("prop_2", 100, None); // Not owned by p1
        let players = vec![make_player("p1", 1000)];
        let state = make_state(tiles, vec![p1, p2], players, 0);

        let result = StrategicAiDecisionMaker::best_upgrade_target(&state, "p1");
        assert!(result.is_none());
    }

    #[test]
    fn test_score_property_returns_positive() {
        let tiles = vec![
            make_tile("start", tile_types::START),
            make_tile("prop_1", tile_types::ORDINARY_PROPERTY),
        ];
        let properties = vec![make_property("prop_1", 100, None)];
        let players = vec![make_player("p1", 1500)];
        let state = make_state(tiles, properties, players, 0);

        let score = StrategicAiDecisionMaker::score_property(&state, "prop_1", "p1");
        assert!(score > 0);
    }
}
