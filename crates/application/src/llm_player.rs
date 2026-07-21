use sa_monopoly_domain::GameState;
use sa_monopoly_domain::tile::tile_types;
use sa_monopoly_domain::types::Money;

// ═══════════════════════════════════════════════════════════════════════════
// LLM Decision Model
// ═══════════════════════════════════════════════════════════════════════════

/// Represents a decision an LLM player can make.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LlmDecision {
    /// The command to execute (e.g. "buy_property", "pass", "upgrade_property").
    pub command: String,
    /// Optional payload for the command.
    #[serde(default)]
    pub payload: serde_json::Value,
    /// Human-readable rationale for the decision.
    #[serde(default)]
    pub rationale: String,
    /// Optional one-line commentary from the LLM (character voice).
    #[serde(default)]
    pub commentary: String,
}

// ═══════════════════════════════════════════════════════════════════════════
// LLM Context — game state summary for LLM consumption
// ═══════════════════════════════════════════════════════════════════════════

/// A structured summary of the current game state, designed to be
/// serialised to JSON and used as LLM prompt context.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LlmContext {
    /// The AI player's own info.
    pub you: PlayerSummary,
    /// All other players.
    pub opponents: Vec<PlayerSummary>,
    /// The tile the AI player just landed on (if any).
    pub landed_tile: Option<TileSummary>,
    /// All properties on the board grouped by colour group.
    pub color_groups: Vec<ColorGroupSummary>,
    /// Available actions the LLM can choose from.
    pub available_actions: Vec<String>,
    /// Current turn number.
    pub turn: u64,
    /// Board layout — tiles in order with their types (linear fallback).
    pub board_layout: Vec<BoardTileInfo>,
    /// Graph edges — directed connections forming paths between tiles.
    pub board_edges: Vec<String>,
    /// Teleporters — special connections between distant tiles.
    pub teleporters: Vec<String>,
    /// Card decks — all possible cards that can be drawn.
    pub card_decks: Vec<CardDeckInfo>,
    /// Recent event log — human-readable actions from recent turns.
    #[serde(default)]
    pub event_log: Vec<String>,
    /// The action this bot already took earlier in the SAME turn, if any.
    /// Passed back on each decision loop so the LLM avoids repeating itself.
    #[serde(default)]
    pub last_action_this_turn: Option<String>,
}

/// Ownership relationship of a tile relative to the deciding player.
///
/// Serialised as short Chinese labels so the LLM immediately understands
/// whose property it is standing on, rather than a raw player id.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum OwnerRelation {
    /// Unowned / not a purchasable property.
    #[serde(rename = "无主")]
    None,
    /// Owned by the deciding player themselves.
    #[serde(rename = "自己")]
    Own,
    /// Owned by a teammate (same non-null team_id).
    #[serde(rename = "己方")]
    Ally,
    /// Owned by an opposing player.
    #[serde(rename = "敌方")]
    Enemy,
}

impl OwnerRelation {
    pub fn label(self) -> &'static str {
        match self {
            OwnerRelation::None => "无主",
            OwnerRelation::Own => "自己",
            OwnerRelation::Ally => "己方",
            OwnerRelation::Enemy => "敌方",
        }
    }
}

/// Resolve a tile owner id into (owner display name, relation) relative to the
/// deciding player, accounting for team membership.
fn resolve_ownership(
    state: &GameState,
    player_id: &str,
    owner_id: Option<&str>,
) -> (Option<String>, OwnerRelation) {
    let owner_id = match owner_id {
        Some(id) => id,
        None => return (None, OwnerRelation::None),
    };
    let owner = state.players.iter().find(|p| p.id == owner_id);
    let owner_name = owner.map(|p| p.name.clone()).unwrap_or_else(|| owner_id.to_string());

    if owner_id == player_id {
        return (Some(owner_name), OwnerRelation::Own);
    }

    // Same non-null team means an ally.
    let me_team = state.players.iter()
        .find(|p| p.id == player_id)
        .and_then(|p| p.team_id.as_deref());
    let owner_team = owner.and_then(|p| p.team_id.as_deref());
    let relation = match (me_team, owner_team) {
        (Some(a), Some(b)) if a == b => OwnerRelation::Ally,
        _ => OwnerRelation::Enemy,
    };
    (Some(owner_name), relation)
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct BoardTileInfo {
    pub id: String,
    pub tile_type: String,
    pub name: String,
    /// Owner of this tile (None if not a property or unowned).
    pub owner: Option<String>,
    /// Human-readable owner name (player name, not raw id).
    #[serde(default)]
    pub owner_name: Option<String>,
    /// Ownership relation relative to the deciding player.
    #[serde(default = "owner_relation_none")]
    pub owner_relation: OwnerRelation,
    /// Price if this is a purchasable property.
    pub price: Option<i64>,
}

fn owner_relation_none() -> OwnerRelation {
    OwnerRelation::None
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CardDeckInfo {
    pub deck_id: String,
    pub cards: Vec<CardInfo>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CardInfo {
    pub id: String,
    pub effect: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PlayerSummary {
    pub id: String,
    pub name: String,
    pub cash: Money,
    pub position: String,
    pub property_count: usize,
    pub owned_tiles: Vec<String>,
    pub owned_cards: Vec<String>,
    pub is_in_jail: bool,
    pub jail_turns: u32,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TileSummary {
    pub id: String,
    pub name: String,
    pub base_price: Option<Money>,
    pub owner: Option<String>,
    /// Human-readable owner name (player name, not raw id).
    #[serde(default)]
    pub owner_name: Option<String>,
    /// Ownership relation relative to the deciding player.
    #[serde(default = "owner_relation_none")]
    pub owner_relation: OwnerRelation,
    pub upgrade_level: Option<u32>,
    pub group: Vec<String>,
    pub current_rent: Option<Money>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ColorGroupSummary {
    pub properties: Vec<GroupPropertySummary>,
    pub fully_owned_by_you: bool,
    pub fully_owned_by_opponent: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct GroupPropertySummary {
    pub tile_id: String,
    pub base_price: Money,
    pub owner: Option<String>,
    /// Human-readable owner name (player name, not raw id).
    #[serde(default)]
    pub owner_name: Option<String>,
    /// Ownership relation relative to the deciding player.
    #[serde(default = "owner_relation_none")]
    pub owner_relation: OwnerRelation,
    pub upgrade_level: u32,
}

// ═══════════════════════════════════════════════════════════════════════════
// Context Builder
// ═══════════════════════════════════════════════════════════════════════════

/// Build an [`LlmContext`] from the current game state for the given player.
///
/// `event_log` — optional recent action history (human-readable strings)
/// passed from the Flutter side, shown in the prompt so the LLM knows what
/// happened in recent turns.
pub fn build_llm_context(
    state: &GameState,
    player_id: &str,
    event_log: Vec<String>,
    last_action_this_turn: Option<String>,
) -> LlmContext {
    let player = state.players.iter().find(|p| p.id == player_id);

    // ── Player summary ────────────────────────────────────────────────
    let you = player.map(|p| {
        let owned_tiles: Vec<String> = state.board.properties.iter()
            .filter(|prop| prop.owner.as_deref() == Some(&p.id))
            .map(|prop| prop.tile_id.clone())
            .collect();
        PlayerSummary {
            id: p.id.clone(),
            name: p.name.clone(),
            cash: p.cash,
            position: p.position.clone(),
            property_count: owned_tiles.len(),
            owned_tiles,
            owned_cards: p.owned_cards.clone(),
            is_in_jail: p.jail_turns > 0,
            jail_turns: p.jail_turns,
        }
    }).unwrap_or_else(|| PlayerSummary {
        id: player_id.to_string(),
        name: "Unknown".to_string(),
        cash: 0,
        position: String::new(),
        property_count: 0,
        owned_tiles: vec![],
        owned_cards: vec![],
        is_in_jail: false,
        jail_turns: 0,
    });

    // ── Opponent summaries ────────────────────────────────────────────
    let opponents: Vec<PlayerSummary> = state.players.iter()
        .filter(|p| p.id != player_id)
        .map(|p| {
            let owned_tiles: Vec<String> = state.board.properties.iter()
                .filter(|prop| prop.owner.as_deref() == Some(&p.id))
                .map(|prop| prop.tile_id.clone())
                .collect();
            PlayerSummary {
                id: p.id.clone(),
                name: p.name.clone(),
                cash: p.cash,
                position: p.position.clone(),
                property_count: owned_tiles.len(),
                owned_tiles,
                owned_cards: p.owned_cards.clone(),
                is_in_jail: p.jail_turns > 0,
                jail_turns: p.jail_turns,
            }
        })
        .collect();

    // ── Landed tile ──────────────────────────────────────────────────
    let landed_tile = player.and_then(|p| {
        let tile = state.board.tile(&p.position)?;
        let property = state.board.property(&p.position);
        let group: Vec<String> = property
            .map(|prop| {
                let mut ids = prop.linked_targets.clone();
                ids.push(prop.tile_id.clone());
                ids
            })
            .unwrap_or_default();
        let owner_id = property.and_then(|p| p.owner.clone());
        let (owner_name, owner_relation) =
            resolve_ownership(state, player_id, owner_id.as_deref());
        Some(TileSummary {
            id: tile.id.clone(),
            name: tile.name_key.clone(),
            base_price: property.map(|p| p.base_price),
            owner: owner_id,
            owner_name,
            owner_relation,
            upgrade_level: property.map(|p| p.upgrade_level),
            group,
            current_rent: property.map(|p| p.current_rent()),
        })
    });

    // ── Color groups ─────────────────────────────────────────────────
    let color_groups = build_color_groups(state, player_id);

    // ── Available actions ────────────────────────────────────────────
    let mut available_actions = vec![
        "end_turn".to_string(),
    ];

    // Check current tile type for tile-specific actions
    let current_tile_kind = player.as_ref()
        .and_then(|p| state.board.tile(&p.position))
        .map(|t| t.kind.as_str().to_string())
        .unwrap_or_default();

    // Can buy if standing on an unowned, affordable property
    if let Some(tile) = &landed_tile {
        if tile.owner.is_none() {
            if let Some(price) = tile.base_price {
                if you.cash >= price {
                    available_actions.push("buy_property".to_string());
                }
            }
        }
    }

    // Tile-specific actions.
    // NOTE: tile kinds are namespaced constants like "core:lottery", so we
    // must compare against tile_types::* rather than bare strings like
    // "lottery" (a previous bug that silently hid these actions).
    match current_tile_kind.as_str() {
        tile_types::LOTTERY => {
            // Can buy lottery ticket
            let ticket_price = state.lottery_state
                .as_ref()
                .map(|ls| ls.ticket_price)
                .unwrap_or(50);
            if you.cash >= ticket_price {
                available_actions.push("buy_lottery_ticket".to_string());
            }
        }
        tile_types::CARD_SHOP => {
            // Can buy cards (prices listed in current tile info)
            if you.cash >= 100 { // cheapest card
                available_actions.push("buy_card".to_string());
            }
        }
        tile_types::JAIL | tile_types::HOSPITAL => {
            // If player is imprisoned, can pay bail
            if you.is_in_jail && you.cash >= 50 {
                available_actions.push("pay_bail".to_string());
            }
        }
        _ => {}
    }

    // Can use cards if player has any
    if !you.owned_cards.is_empty() {
        available_actions.push("use_card".to_string());
    }

    // Can upgrade if any owned property in a full group can be upgraded
    let can_upgrade = state.board.properties.iter().any(|prop| {
        if prop.owner.as_deref() != Some(player_id) { return false; }
        if prop.upgrade_level >= state.max_upgrade_level as u32 { return false; }
        let group: Vec<&str> = prop.linked_targets.iter().map(|s| s.as_str()).collect();
        if group.is_empty() { return false; }
        let all_owned = group.iter().all(|tid| {
            state.board.property(tid)
                .and_then(|p| p.owner.as_deref()) == Some(player_id)
        });
        if !all_owned { return false; }
        let cost = prop.upgrade_cost();
        you.cash >= cost + 100
    });
    if can_upgrade {
        available_actions.push("upgrade_property".to_string());
    }

    // ── Board layout ─────────────────────────────────────────────────
    let board_layout: Vec<BoardTileInfo> = state.board.tiles.iter()
        .map(|t| {
            // Tile kinds are namespaced constants (e.g. "core:lottery"), so
            // match against tile_types::* rather than bare strings.
            let tile_type = match t.kind.as_str() {
                tile_types::START => "起点",
                tile_types::ORDINARY_PROPERTY => "地产",
                tile_types::EXTENSION_PROPERTY => "公用事业",
                tile_types::SPECIAL_PROPERTY => "特殊",
                tile_types::CHANCE => "机会",
                tile_types::CARD_SHOP => "卡片商店",
                tile_types::LOTTERY => "彩票",
                tile_types::BANK => "银行/税收",
                tile_types::JAIL => "监狱",
                tile_types::HOSPITAL => "医院",
                tile_types::GO_TO_JAIL => "前往监狱",
                _ => &t.kind,
            };
            let prop = state.board.property(&t.id);
            let owner_id = prop.and_then(|p| p.owner.clone());
            let (owner_name, owner_relation) =
                resolve_ownership(state, player_id, owner_id.as_deref());
            BoardTileInfo {
                id: t.id.clone(),
                tile_type: tile_type.to_string(),
                name: t.name_key.clone(),
                owner: owner_id,
                owner_name,
                owner_relation,
                price: prop.map(|p| p.base_price),
            }
        })
        .collect();

    // ── Board graph edges ────────────────────────────────────────────
    let board_edges: Vec<String> = state.board.graph.edges.iter()
        .map(|e| {
            let label = e.label.as_deref().unwrap_or("");
            if label.is_empty() {
                format!("{} → {}", e.from, e.to)
            } else {
                format!("{} → {} [{}]", e.from, e.to, label)
            }
        })
        .collect();

    // ── Teleporters ──────────────────────────────────────────────────
    let teleporters: Vec<String> = state.board.graph.teleporters.iter()
        .map(|t| {
            let cond = t.condition.as_deref().unwrap_or("always");
            format!("{} ⇢ {} ({})", t.from, t.to, cond)
        })
        .collect();

    // ── Card decks ───────────────────────────────────────────────────
    let card_decks: Vec<CardDeckInfo> = state.decks.iter()
        .map(|deck| {
            let cards: Vec<CardInfo> = deck.cards.iter()
                .map(|c| {
                    let effect = match c.effect_key.as_str() {
                        "bonus_200" => "获得 $200 奖金",
                        "get_out_of_jail" => "获得免罪出狱卡",
                        "double_rent" => "下次收取租金翻倍",
                        _ => &c.effect_key,
                    };
                    CardInfo {
                        id: c.id.clone(),
                        effect: effect.to_string(),
                    }
                })
                .collect();
            CardDeckInfo {
                deck_id: deck.id.clone(),
                cards,
            }
        })
        .collect();

    LlmContext {
        you,
        opponents,
        landed_tile,
        color_groups,
        available_actions,
        turn: state.current_turn,
        board_layout,
        board_edges,
        teleporters,
        card_decks,
        event_log,
        last_action_this_turn,
    }
}

fn build_color_groups(state: &GameState, player_id: &str) -> Vec<ColorGroupSummary> {
    use std::collections::HashMap;

    // Group properties by their linked_targets (colour group).
    // We use a simple approach: properties that share linked_targets
    // belong to the same group.
    let mut group_map: HashMap<String, Vec<GroupPropertySummary>> = HashMap::new();

    for prop in &state.board.properties {
        if prop.linked_targets.is_empty() {
            continue; // No group — treat as singleton
        }
        // Use the sorted set of all group members as the group key
        let mut all_ids: Vec<String> = prop.linked_targets.clone();
        all_ids.push(prop.tile_id.clone());
        all_ids.sort();
        let key = all_ids.join(",");

        let (owner_name, owner_relation) =
            resolve_ownership(state, player_id, prop.owner.as_deref());
        let entry = group_map.entry(key).or_default();
        entry.push(GroupPropertySummary {
            tile_id: prop.tile_id.clone(),
            base_price: prop.base_price,
            owner: prop.owner.clone(),
            owner_name,
            owner_relation,
            upgrade_level: prop.upgrade_level,
        });
    }

    group_map.into_values().map(|properties| {
        let all_owned_by_you = properties.iter().all(|p| p.owner.as_deref() == Some(player_id));
        let any_owned_by_opponent = properties.iter().any(|p| {
            p.owner.as_deref().map_or(false, |o| o != player_id)
        });
        ColorGroupSummary {
            fully_owned_by_you: all_owned_by_you && !properties.is_empty(),
            fully_owned_by_opponent: any_owned_by_opponent
                && properties.iter().all(|p| p.owner.is_some()),
            properties,
        }
    }).collect()
}

/// Build a human-readable prompt string from the LLM context.
/// This can be sent to an LLM API for decision-making.
pub fn build_llm_prompt(ctx: &LlmContext) -> String {
    let mut prompt = String::new();

    prompt.push_str("You are playing Monopoly. Your goal is to bankrupt your opponents.\n\n");

    // Remind the bot what it already did earlier THIS turn so it does not
    // repeat the same action or contradict itself within one turn.
    if let Some(last) = &ctx.last_action_this_turn {
        prompt.push_str("--- 你本回合已执行的上一步 ---\n");
        prompt.push_str(&format!("{}\n", last));
        prompt.push_str("请不要重复上述已完成的动作；若无更多有益操作，请选择 end_turn。\n\n");
    }

    prompt.push_str(&format!("--- YOUR STATUS ---\n"));
    prompt.push_str(&format!("Cash: ${}\n", ctx.you.cash));
    prompt.push_str(&format!("Position: {}\n", ctx.you.position));
    prompt.push_str(&format!("Properties owned: {}\n", ctx.you.owned_tiles.join(", ")));
    prompt.push_str(&format!("Cards: {}\n", ctx.you.owned_cards.join(", ")));
    if ctx.you.is_in_jail {
        prompt.push_str(&format!("In jail for {} more turns\n", ctx.you.jail_turns));
    }
    prompt.push('\n');

    prompt.push_str("--- OPPONENTS ---\n");
    for opp in &ctx.opponents {
        prompt.push_str(&format!("{}: ${} cash, {} properties", opp.name, opp.cash, opp.property_count));
        if !opp.owned_tiles.is_empty() {
            prompt.push_str(&format!(" [{}]", opp.owned_tiles.join(", ")));
        }
        if opp.is_in_jail {
            prompt.push_str(" (in jail)");
        }
        prompt.push('\n');
    }
    prompt.push('\n');

    if let Some(tile) = &ctx.landed_tile {
        prompt.push_str("--- CURRENT TILE ---\n");
        prompt.push_str(&format!("You are on: {}\n", tile.name));
        if let Some(price) = tile.base_price {
            prompt.push_str(&format!("Price: ${}\n", price));
            if let Some(rent) = tile.current_rent {
                prompt.push_str(&format!("Current rent: ${}\n", rent));
            }
        }
        match tile.owner_relation {
            OwnerRelation::None => {
                if tile.base_price.is_some() {
                    prompt.push_str("所有者: 无主（可购买）\n");
                }
            }
            rel => {
                let name = tile.owner_name.as_deref().unwrap_or("?");
                prompt.push_str(&format!("所有者: {} [{}]\n", name, rel.label()));
                if rel == OwnerRelation::Own {
                    prompt.push_str("注意: 这是你自己的地产，落在自己地产上不需要付租金。\n");
                }
            }
        }
        if !tile.group.is_empty() {
            prompt.push_str(&format!("Colour group: {}\n", tile.group.join(", ")));
        }
        prompt.push('\n');
    }

    prompt.push_str("--- COLOUR GROUPS ---\n");
    for group in &ctx.color_groups {
        let names: Vec<String> = group.properties.iter()
            .map(|p| {
                let owner = match p.owner_relation {
                    OwnerRelation::None => "无主".to_string(),
                    rel => format!(
                        "{}·{}",
                        p.owner_name.as_deref().unwrap_or("?"),
                        rel.label()
                    ),
                };
                format!("{}({})", p.tile_id, owner)
            })
            .collect();
        let status = if group.fully_owned_by_you {
            " [COMPLETE - you own all]"
        } else if group.fully_owned_by_opponent {
            " [COMPLETE - opponent owns all]"
        } else {
            ""
        };
        prompt.push_str(&format!("  {}{}\n", names.join(", "), status));
    }
    prompt.push('\n');

    // ── Board topology ────────────────────────────────────────────────
    prompt.push_str("--- BOARD TOPOLOGY ---\n");

    // Show each tile with owner info
    if !ctx.board_edges.is_empty() {
        prompt.push_str("Paths (tile connections):\n");
        for edge in &ctx.board_edges {
            prompt.push_str(&format!("  {}\n", edge));
        }
    } else {
        prompt.push_str("Tiles in order around the board:\n");
        for (i, tile) in ctx.board_layout.iter().enumerate() {
            let owner_info = match tile.owner_relation {
                OwnerRelation::None => {
                    if tile.price.is_some() {
                        " [无主]".to_string()
                    } else {
                        String::new()
                    }
                }
                rel => format!(
                    " [所有者: {}·{}]",
                    tile.owner_name.as_deref().unwrap_or("?"),
                    rel.label()
                ),
            };
            let price_info = tile.price
                .map(|p| format!(" ${}", p))
                .unwrap_or_default();
            prompt.push_str(&format!(
                "  {}. {}{}{} ({})\n",
                i + 1, tile.name, price_info, owner_info, tile.tile_type
            ));
        }
    }

    // Show teleporters if any
    if !ctx.teleporters.is_empty() {
        prompt.push_str("\nTeleporters (special connections):\n");
        for tp in &ctx.teleporters {
            prompt.push_str(&format!("  {}\n", tp));
        }
    }

    // Show property group links (linked_targets) for context
    let group_links: Vec<String> = ctx.color_groups.iter()
        .filter(|g| g.properties.len() > 1)
        .map(|g| {
            let ids: Vec<&str> = g.properties.iter().map(|p| p.tile_id.as_str()).collect();
            format!("[{}]", ids.join(" ↔ "))
        })
        .collect();
    if !group_links.is_empty() {
        prompt.push_str("\nProperty colour groups (linked rent):\n");
        for link in &group_links {
            prompt.push_str(&format!("  {}\n", link));
        }
    }
    prompt.push('\n');

    // ── Card decks ────────────────────────────────────────────────────
    if !ctx.card_decks.is_empty() {
        prompt.push_str("--- AVAILABLE CARDS / EVENTS ---\n");
        for deck in &ctx.card_decks {
            prompt.push_str(&format!("Deck '{}':\n", deck.deck_id));
            for card in &deck.cards {
                prompt.push_str(&format!("  - {}: {}\n", card.id, card.effect));
            }
        }
        prompt.push('\n');
    }

    prompt.push_str("--- AVAILABLE ACTIONS ---\n");
    for action in &ctx.available_actions {
        match action.as_str() {
            "buy_property" => prompt.push_str("  buy_property - Purchase the unowned property you are standing on\n"),
            "upgrade_property" => prompt.push_str("  upgrade_property - Upgrade one of your properties (need full colour group)\n"),
            "buy_card" => prompt.push_str("  buy_card - Buy a card from the Card Shop\n"),
            "buy_lottery_ticket" => prompt.push_str("  buy_lottery_ticket - Buy a lottery ticket (pick a number 1-100)\n"),
            "pay_bail" => prompt.push_str("  pay_bail - Pay bail to get out of jail\n"),
            "use_card" => prompt.push_str("  use_card - Use a card from your inventory\n"),
            "end_turn" => prompt.push_str("  end_turn - End your turn (default if nothing else)\n"),
            _ => prompt.push_str(&format!("  {}\n", action)),
        }
    }
    prompt.push('\n');

    prompt.push_str("Respond with one JSON object only. Use exactly one of these forms:\n");
    prompt.push_str(r#"{"command":"buy_property","payload":{"tile_id":"<tile id>"},"rationale":"...","commentary":"..."}"#);
    prompt.push('\n');
    prompt.push_str(r#"{"command":"upgrade_property","payload":{"tile_id":"<tile id>"},"rationale":"...","commentary":"..."}"#);
    prompt.push('\n');
    prompt.push_str(r#"{"command":"buy_card","payload":{"card_id":"<card id>","price":100},"rationale":"...","commentary":"..."}"#);
    prompt.push('\n');
    prompt.push_str(r#"{"command":"buy_lottery_ticket","payload":{"number":7},"rationale":"...","commentary":"..."}"#);
    prompt.push('\n');
    prompt.push_str(r#"{"command":"pay_bail","payload":{},"rationale":"...","commentary":"..."}"#);
    prompt.push('\n');
    prompt.push_str(r#"{"command":"use_card","payload":{"card_id":"<card id>"},"rationale":"...","commentary":"..."}"#);
    prompt.push('\n');
    prompt.push_str(r#"{"command":"end_turn","payload":{},"rationale":"...","commentary":"..."}"#);

    prompt
}

#[cfg(test)]
mod tests {
    use super::*;
    use sa_monopoly_domain::{Board, BoardGraph, Player};

    fn make_player(id: &str, cash: i64, pos: &str) -> Player {
        Player {
            id: id.to_string(),
            name: id.to_string(),
            cash,
            position: pos.to_string(),
            is_ai: false,
            is_llm_controlled: true,
            jail_turns: 0,
            hospital_turns: 0,
            owned_cards: vec![],
            stock_shares: 0,
            team_id: None,
        }
    }

    fn make_empty_state(players: Vec<Player>) -> GameState {
        GameState {
            board: Board {
                tiles: vec![],
                properties: vec![],
                graph: BoardGraph::default(),
                auto_link_rent: false,
            },
            players,
            ruleset: sa_monopoly_domain::rules::RuleSetRef {
                id: "test".to_string(),
                version: "1.0.0".to_string(),
            },
            current_turn: 1,
            active_player_index: 0,
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
    fn test_build_llm_context_basic() {
        let players = vec![
            make_player("p1", 1500, "start"),
            make_player("p2", 1500, "start"),
        ];
        let state = make_empty_state(players);
        let ctx = build_llm_context(&state, "p1", vec![], None);

        assert_eq!(ctx.you.cash, 1500);
        assert_eq!(ctx.opponents.len(), 1);
        assert_eq!(ctx.opponents[0].id, "p2");
        assert!(ctx.landed_tile.is_none());
        assert!(ctx.available_actions.contains(&"end_turn".to_string()));
    }

    #[test]
    fn test_build_llm_context_with_tile() {
        use sa_monopoly_domain::tile::{Tile, tile_types};
        use sa_monopoly_domain::property::{Property, PropertyKind};

        let tile = Tile {
            id: "prop_1".to_string(),
            name_key: "Test Property".to_string(),
            kind: tile_types::ORDINARY_PROPERTY.to_string(),
            linked_property_kind: None,
        };
        let prop = Property {
            tile_id: "prop_1".to_string(),
            name_key: "prop.prop_1".to_string(),
            kind: PropertyKind::Ordinary,
            base_price: 200,
            rent: vec![20],
            upgrade_level: 0,
            owner: None,
            is_mortgaged: false,
            linked_targets: vec!["prop_2".to_string()],
        };

        let players = vec![
            make_player("p1", 1500, "prop_1"),
            make_player("p2", 1500, "start"),
        ];
        let mut state = make_empty_state(players);
        state.board.tiles.push(tile);
        state.board.properties.push(prop);

        let ctx = build_llm_context(&state, "p1", vec![], None);

        assert!(ctx.landed_tile.is_some());
        let tile = ctx.landed_tile.as_ref().unwrap();
        assert_eq!(tile.base_price, Some(200));
        assert!(tile.owner.is_none());
        assert!(ctx.available_actions.contains(&"buy_property".to_string()));
    }

    #[test]
    fn test_build_llm_prompt_contains_actions() {
        let players = vec![
            make_player("p1", 1500, "prop_1"),
            make_player("p2", 1500, "start"),
        ];
        let state = make_empty_state(players);
        let ctx = build_llm_context(&state, "p1", vec![], None);
        let prompt = build_llm_prompt(&ctx);

        assert!(prompt.contains("end_turn"));
        assert!(prompt.contains("buy_property"));
        assert!(prompt.contains("upgrade_property"));
        assert!(prompt.contains("$1500"));
    }

    #[test]
    fn test_available_actions_includes_buy_when_on_unowned() {
        use sa_monopoly_domain::tile::{Tile, tile_types};
        use sa_monopoly_domain::property::{Property, PropertyKind};

        let tile = Tile {
            id: "prop_1".to_string(),
            name_key: "Test Property".to_string(),
            kind: tile_types::ORDINARY_PROPERTY.to_string(),
            linked_property_kind: None,
        };
        let prop = Property {
            tile_id: "prop_1".to_string(),
            name_key: "prop.prop_1".to_string(),
            kind: PropertyKind::Ordinary,
            base_price: 200,
            rent: vec![20],
            upgrade_level: 0,
            owner: None,
            is_mortgaged: false,
            linked_targets: vec![],
        };

        let players = vec![
            make_player("p1", 1500, "prop_1"),
        ];
        let mut state = make_empty_state(players);
        state.board.tiles.push(tile);
        state.board.properties.push(prop);

        let ctx = build_llm_context(&state, "p1", vec![], None);
        assert!(ctx.available_actions.contains(&"buy_property".to_string()));
    }

    #[test]
    fn test_available_actions_excludes_buy_when_cant_afford() {
        use sa_monopoly_domain::tile::{Tile, tile_types};
        use sa_monopoly_domain::property::{Property, PropertyKind};

        let tile = Tile {
            id: "prop_1".to_string(),
            name_key: "Expensive Property".to_string(),
            kind: tile_types::ORDINARY_PROPERTY.to_string(),
            linked_property_kind: None,
        };
        let prop = Property {
            tile_id: "prop_1".to_string(),
            name_key: "prop.prop_1".to_string(),
            kind: PropertyKind::Ordinary,
            base_price: 5000,
            rent: vec![500],
            upgrade_level: 0,
            owner: None,
            is_mortgaged: false,
            linked_targets: vec![],
        };

        let players = vec![
            make_player("p1", 100, "prop_1"),
        ];
        let mut state = make_empty_state(players);
        state.board.tiles.push(tile);
        state.board.properties.push(prop);

        let ctx = build_llm_context(&state, "p1", vec![], None);
        assert!(!ctx.available_actions.contains(&"buy_property".to_string()));
    }

    #[test]
    fn test_available_actions_includes_lottery_on_lottery_tile() {
        use sa_monopoly_domain::lottery::LotteryState;
        use sa_monopoly_domain::tile::{Tile, tile_types};

        // Regression guard: tile kinds are namespaced (e.g. "core:lottery").
        // A previous bug matched the bare string "lottery", so this action
        // never appeared and LLM/A2CM players could not buy lottery tickets.
        let tile = Tile {
            id: "lottery_1".to_string(),
            name_key: "tile.lottery_1".to_string(),
            kind: tile_types::LOTTERY.to_string(),
            linked_property_kind: None,
        };
        let players = vec![make_player("p1", 1500, "lottery_1")];
        let mut state = make_empty_state(players);
        state.board.tiles.push(tile);
        state.lottery_state = Some(LotteryState::new(0));

        let ctx = build_llm_context(&state, "p1", vec![], None);
        assert!(
            ctx.available_actions.contains(&"buy_lottery_ticket".to_string()),
            "lottery tile should expose buy_lottery_ticket, got {:?}",
            ctx.available_actions
        );

        // board_layout tile_type must be translated, not the raw "core:lottery".
        let lottery_layout = ctx.board_layout.iter()
            .find(|t| t.id == "lottery_1")
            .expect("lottery tile should be in board_layout");
        assert_eq!(
            lottery_layout.tile_type, "彩票",
            "namespaced kind should map to a translated label"
        );
    }

    #[test]
    fn test_ownership_relation_labels_self_and_enemy() {
        use sa_monopoly_domain::tile::{Tile, tile_types};
        use sa_monopoly_domain::property::{Property, PropertyKind};

        let mk_tile = |id: &str| Tile {
            id: id.to_string(),
            name_key: format!("tile.{id}"),
            kind: tile_types::ORDINARY_PROPERTY.to_string(),
            linked_property_kind: None,
        };
        let mk_prop = |id: &str, owner: &str| Property {
            tile_id: id.to_string(),
            name_key: format!("prop.{id}"),
            kind: PropertyKind::Ordinary,
            base_price: 100,
            rent: vec![10],
            upgrade_level: 0,
            owner: Some(owner.to_string()),
            is_mortgaged: false,
            linked_targets: vec![],
        };

        // p1 stands on its OWN property; p2 owns another tile (enemy).
        let players = vec![
            make_player("p1", 1000, "prop_a"),
            make_player("p2", 1000, "start"),
        ];
        let mut state = make_empty_state(players);
        state.board.tiles.push(mk_tile("prop_a"));
        state.board.tiles.push(mk_tile("prop_b"));
        state.board.properties.push(mk_prop("prop_a", "p1"));
        state.board.properties.push(mk_prop("prop_b", "p2"));

        let ctx = build_llm_context(&state, "p1", vec![], Some("buy_property prop_a".into()));

        // Landed tile is p1's own property.
        let landed = ctx.landed_tile.as_ref().expect("landed tile");
        assert_eq!(landed.owner_relation, OwnerRelation::Own);
        assert_eq!(landed.owner_name.as_deref(), Some("p1"));

        // board_layout reflects self vs enemy correctly.
        let a = ctx.board_layout.iter().find(|t| t.id == "prop_a").unwrap();
        let b = ctx.board_layout.iter().find(|t| t.id == "prop_b").unwrap();
        assert_eq!(a.owner_relation, OwnerRelation::Own);
        assert_eq!(b.owner_relation, OwnerRelation::Enemy);

        // last_action is carried through into the context.
        assert_eq!(ctx.last_action_this_turn.as_deref(), Some("buy_property prop_a"));

        // Prompt should call the landed tile "自己", not a raw player id.
        let prompt = build_llm_prompt(&ctx);
        assert!(prompt.contains("[自己]"), "prompt should label own tile: {prompt}");
        assert!(prompt.contains("你本回合已执行的上一步"));
    }
}
