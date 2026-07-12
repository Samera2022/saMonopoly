use std::collections::HashMap;
use sa_monopoly_domain::{
    GameState, Board, BoardGraph, CardDeck, Player, RuleSetRef,
    tile::{Tile, tile_types},
    property::{Property, PropertyKind},
};

/// Convert map JSON + player list into a ready-to-play GameState.
/// Preset owners from properties[].owner are applied.
pub fn map_json_to_game_state(
    map_value: &serde_json::Value,
    players: Vec<Player>,
    ruleset: RuleSetRef,
    seed: u64,
) -> GameState {
    // 1. Parse tiles
    let tiles: Vec<Tile> = map_value["tiles"].as_array()
        .map(|arr| arr.iter().map(tile_from_json).collect())
        .unwrap_or_default();

    // 2. Parse properties with preset owners
    let properties = build_properties_from_json(map_value);

    // 3. Build board
    let auto_link = map_value["rules"]["auto_link_rent"].as_bool().unwrap_or(false);
    let board = Board {
        tiles,
        properties,
        graph: BoardGraph::default(),
        auto_link_rent: auto_link,
    };

    // Initialize default chance card deck
    let mut chance_deck = CardDeck {
        id: "chance".to_string(),
        cards: vec![
            sa_monopoly_domain::card::Card {
                id: "bonus_200".to_string(),
                name_key: "card.bonus_200".to_string(),
                effect_key: "bonus_200".to_string(),
            },
            sa_monopoly_domain::card::Card {
                id: "get_out_of_jail".to_string(),
                name_key: "card.get_out_of_jail".to_string(),
                effect_key: "get_out_of_jail".to_string(),
            },
            sa_monopoly_domain::card::Card {
                id: "double_rent".to_string(),
                name_key: "card.double_rent".to_string(),
                effect_key: "double_rent".to_string(),
            },
        ],
    };

    // Simple Fisher-Yates shuffle using the seed
    let len = chance_deck.cards.len();
    for i in (1..len).rev() {
        let j = (seed as usize + i * 7) % (i + 1);
        chance_deck.cards.swap(i, j);
    }

    GameState {
        board,
        players,
        ruleset,
        current_turn: 0,
        active_player_index: 0,
        seed,
        decks: vec![chance_deck],
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

fn tile_from_json(tile: &serde_json::Value) -> Tile {
    let id = tile["id"].as_str().unwrap_or("");
    let kind = match tile["tile_type"].as_str() {
        Some("start") => tile_types::START,
        Some("ordinary_property") => tile_types::ORDINARY_PROPERTY,
        Some("extension_property") => tile_types::EXTENSION_PROPERTY,
        Some("special_property") => tile_types::SPECIAL_PROPERTY,
        Some("chance") => tile_types::CHANCE,
        Some("card_shop") => tile_types::CARD_SHOP,
        Some("lottery") => tile_types::LOTTERY,
        Some("bank") => tile_types::BANK,
        Some("jail") => tile_types::JAIL,
        Some("hospital") => tile_types::HOSPITAL,
        Some("go_to_jail") => tile_types::GO_TO_JAIL,
        _ => tile_types::START,
    };
    Tile {
        id: id.to_string(),
        name_key: tile["name_key"].as_str().unwrap_or(id).to_string(),
        kind: kind.to_string(),
        linked_property_kind: None,
    }
}

fn build_properties_from_json(map_value: &serde_json::Value) -> Vec<Property> {
    // Build a lookup of tile kind
    let mut tile_kinds: HashMap<&str, &str> = HashMap::new();
    if let Some(tiles) = map_value["tiles"].as_array() {
        for t in tiles {
            if let (Some(id), Some(kind)) = (t["id"].as_str(), t["tile_type"].as_str()) {
                tile_kinds.insert(id, kind);
            }
        }
    }

    let mut properties = Vec::new();
    if let Some(props) = map_value["properties"].as_array() {
        for p in props {
            let tid = p["tile_id"].as_str().unwrap_or("");
            let price = p["base_price"].as_i64().unwrap_or(0);
            let kind = match tile_kinds.get(tid) {
                Some(&"extension_property") => PropertyKind::Extension,
                _ => PropertyKind::Ordinary,
            };

            // Read linked_targets from JSON or color_group-based defaults
            let linked_targets: Vec<String> = p["linked_targets"].as_array()
                .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                .unwrap_or_default();

            // Preset owner: prefer index (integer, e.g. 0 → "player_0"),
            // fall back to player ID string (e.g. "player_1").
            let owner: Option<String> = p["owner"].as_i64()
                .map(|idx| format!("player_{idx}"))
                .or_else(|| p["owner"].as_str().map(String::from));

            properties.push(Property {
                tile_id: tid.to_string(),
                name_key: format!("prop.{tid}"),
                kind,
                base_price: price,
                rent: vec![price / 10],
                upgrade_level: 0,
                owner,
                is_mortgaged: false,
                linked_targets,
            });
        }
    }
    properties
}
