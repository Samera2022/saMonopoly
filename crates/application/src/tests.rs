use sa_monopoly_domain::{
    board::BoardGraph, player::Player, property::Property, tile::Tile, tile::TileKind,
    GameState,
};

use crate::commands::GameCommand;
use crate::effects::EffectResolver;
use crate::engine::GameEngine;
use crate::events::GameEvent;
use crate::ports::RngService;

// ─── Helper: a deterministic RNG for testing ─────────────────────────────────

struct TestRng {
    state: u64,
}

impl TestRng {
    fn new(seed: u64) -> Self {
        Self { state: seed.max(1) }
    }
}

impl RngService for TestRng {
    fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        x
    }
}

// ─── Helper: build a minimal linear board ────────────────────────────────────

fn make_tile(id: &str, kind: TileKind) -> Tile {
    Tile {
        id: id.to_string(),
        name_key: format!("tile.{}", id),
        kind,
        linked_property_kind: None,
    }
}

fn make_property(tile_id: &str, price: i64) -> Property {
    Property {
        tile_id: tile_id.to_string(),
        name_key: format!("prop.{}", tile_id),
        kind: sa_monopoly_domain::property::PropertyKind::Ordinary,
        base_price: price,
        rent: vec![10, 20, 30],
        upgrade_level: 0,
        owner: None,
        is_mortgaged: false,
    }
}

/// Create a minimal 6-tile board with a CardShop tile at index 2.
fn test_board() -> sa_monopoly_domain::Board {
    sa_monopoly_domain::Board {
        tiles: vec![
            make_tile("start", TileKind::Start),
            make_tile("prop_a", TileKind::OrdinaryProperty),
            make_tile("card_shop", TileKind::CardShop),
            make_tile("prop_b", TileKind::OrdinaryProperty),
            make_tile("jail", TileKind::Jail),
            make_tile("prop_c", TileKind::OrdinaryProperty),
        ],
        properties: vec![
            make_property("prop_a", 200),
            make_property("prop_b", 150),
            make_property("prop_c", 300),
        ],
        graph: BoardGraph::default(),
    }
}

fn test_player(id: &str, name: &str, cash: i64, position: &str) -> Player {
    Player {
        id: id.to_string(),
        name: name.to_string(),
        cash,
        position: position.to_string(),
        is_ai: false,
        is_llm_controlled: false,
        jail_turns: 0,
        hospital_turns: 0,
        owned_cards: vec![],
        stock_shares: 0,
    }
}

fn test_state() -> GameState {
    GameState {
        board: test_board(),
        players: vec![
            test_player("p1", "Alice", 1500, "start"),
            test_player("p2", "Bob", 1500, "start"),
        ],
        ruleset: sa_monopoly_domain::rules::RuleSetRef {
            id: "test".to_string(),
            version: "1.0".to_string(),
        },
        current_turn: 0,
        active_player_index: 0,
        seed: 42,
        decks: vec![],
        stock_market: None,
        active_auction: None,
        consecutive_doubles: 0,
        max_upgrade_level: 3,
        extension_upgrade_enabled: false,
    }
}

// ─── Integration tests ───────────────────────────────────────────────────────

/// test_full_turn: Roll → move → buy unowned property → end turn
#[test]
fn test_full_turn() {
    let mut state = test_state();
    let mut rng = TestRng::new(42);

    // ── Roll ──
    let event = GameEngine::execute(GameCommand::Roll, &mut state, &mut rng);

    // When rolling results in landing on an unowned property, the engine returns
    // CommandAccepted("unowned_property") as the tile effect. Accept either the tile
    // effect or a direct movement/doubles event.
    let landed = match &event {
        GameEvent::DoublesRolled { .. } | GameEvent::PlayerMoved { .. } => true,
        GameEvent::CommandAccepted { name } if name == "unowned_property" => true,
        _ => false,
    };
    assert!(landed, "expected a movement or unowned_property event, got {event:?}");

    let player_pos_after_roll = state.active_player().unwrap().position.clone();
    assert_ne!(player_pos_after_roll, "start", "player should have moved");

    // ── Buy property if on an unowned tile ──
    let tile_on = state.board.tile(&player_pos_after_roll).unwrap();
    if matches!(tile_on.kind, TileKind::OrdinaryProperty) {
        let buy_event = GameEngine::execute(
            GameCommand::BuyProperty {
                tile_id: player_pos_after_roll.clone(),
            },
            &mut state,
            &mut rng,
        );
        assert!(
            matches!(&buy_event, GameEvent::PropertyBought { .. }),
            "expected PropertyBought, got {buy_event:?}"
        );
        // Verify property is now owned
        let prop = state.board.property(&player_pos_after_roll).unwrap();
        assert_eq!(prop.owner.as_deref(), Some("p1"));
    }

    // ── End turn ──
    let end_event = GameEngine::execute(GameCommand::EndTurn, &mut state, &mut rng);
    assert!(
        matches!(&end_event, GameEvent::TurnAdvanced { .. }),
        "expected TurnAdvanced, got {end_event:?}"
    );

    // After one end turn, it should be player 2's turn
    assert_eq!(state.active_player_index, 1);
    assert_eq!(state.current_turn, 1);
}

/// test_jail_skip_turn: Player lands on jail → gets 3 jail turns → roll skips
#[test]
fn test_jail_skip_turn() {
    let mut state = test_state();
    let mut rng = TestRng::new(42);

    // Manually put player on jail tile
    if let Some(p) = state.active_player_mut() {
        p.position = "jail".to_string();
    }

    // Resolve tile effect → should send to jail with 3 turns
    let tile_event = EffectResolver::resolve_special_tile(&mut state, "jail", &mut rng);
    assert!(
        matches!(&tile_event, Some(GameEvent::PlayerSentToJail { turns: 3, .. })),
        "expected PlayerSentToJail with 3 turns, got {tile_event:?}"
    );

    // First roll attempt → skipped (still has turns)
    let roll1 = GameEngine::execute(GameCommand::Roll, &mut state, &mut rng);
    assert!(
        matches!(&roll1, GameEvent::CommandRejected { reason } if reason == "player_in_jail"),
        "expected player_in_jail rejection, got {roll1:?}"
    );
    // Jail turns decremented from 3 → 2
    assert_eq!(state.active_player().unwrap().jail_turns, 2);

    // Second roll → skipped (still has turns)
    let roll2 = GameEngine::execute(GameCommand::Roll, &mut state, &mut rng);
    assert!(
        matches!(&roll2, GameEvent::CommandRejected { reason } if reason == "player_in_jail"),
        "expected player_in_jail rejection, got {roll2:?}"
    );
    assert_eq!(state.active_player().unwrap().jail_turns, 1);

    // Third roll → last turn decrements to 0 → released
    let roll3 = GameEngine::execute(GameCommand::Roll, &mut state, &mut rng);
    assert!(
        matches!(&roll3, GameEvent::PlayerReleasedFromJail { .. }),
        "expected PlayerReleasedFromJail, got {roll3:?}"
    );
    assert_eq!(state.active_player().unwrap().jail_turns, 0);
}

/// test_bankruptcy: Player goes into debt → bankruptcy detected
#[test]
fn test_bankruptcy() {
    let mut state = test_state();
    let mut rng = TestRng::new(42);

    // Set player cash to exactly 0 (can afford nothing positive)
    if let Some(p) = state.active_player_mut() {
        p.cash = 0;
    }

    // Try to buy an expensive property → should fail with insufficient funds
    let buy_event = GameEngine::execute(
        GameCommand::BuyProperty {
            tile_id: "prop_c".to_string(), // 300
        },
        &mut state,
        &mut rng,
    );
    assert!(
        matches!(&buy_event, GameEvent::CommandRejected { reason } if reason == "insufficient_funds"),
        "expected insufficient_funds, got {buy_event:?}"
    );

    // Manually set cash negative to trigger bankruptcy
    if let Some(p) = state.active_player_mut() {
        p.cash = -100;
    }
    assert!(state.active_player().unwrap().is_bankrupt());

    // End turn → should eliminate p1 → only p2 remains → game ends
    let end_event = GameEngine::execute(GameCommand::EndTurn, &mut state, &mut rng);
    match &end_event {
        GameEvent::GameWon {
            winner_id,
            remaining_players,
        } => {
            assert_eq!(winner_id, "p2", "p2 should be the winner");
            assert_eq!(*remaining_players, 1);
        }
        other => panic!("expected GameWon, got {other:?}"),
    }

    // Only p2 should remain
    assert_eq!(state.players.len(), 1);
    assert_eq!(state.players[0].id, "p2");
}

/// test_pass_start_bonus: Player passing start receives +$200
#[test]
fn test_pass_start_bonus() {
    let mut state = test_state();
    let mut rng = TestRng::new(42);

    let initial_cash = state.active_player().unwrap().cash;

    // Place player near the end so that a roll of ~4 lands past start
    // Board has 6 tiles: start(0), prop_a(1), card_shop(2), prop_b(3), jail(4), prop_c(5)
    // If player is at prop_c (index 5), rolling 1 step wraps to start(0) → passes start.
    if let Some(p) = state.active_player_mut() {
        p.position = "prop_c".to_string(); // last tile before wrap
    }

    // Roll a 1 → wrap around to start
    let _event = GameEngine::execute(GameCommand::Roll, &mut state, &mut rng);

    // We expect DoublesRolled (since dice1 == dice2 == 1 with seed 42? actually need to check)
    // The important thing: cash should have increased by 200 (pass start bonus)
    let final_cash = state.active_player().unwrap().cash;
    assert_eq!(
        final_cash,
        initial_cash + 200,
        "expected +200 pass start bonus, cash went from {initial_cash} to {final_cash}"
    );

    // The tile landed on should be "start"
    assert_eq!(state.active_player().unwrap().position, "start");
}

/// test_card_shop: Player lands on CardShop tile → gets card list → buys a card
#[test]
fn test_card_shop_land_and_buy() {
    let mut state = test_state();
    let mut rng = TestRng::new(42);

    // Place player on the card_shop tile
    if let Some(p) = state.active_player_mut() {
        p.position = "card_shop".to_string();
    }

    // Resolve tile effect → should get CardShopList
    let event = EffectResolver::resolve_special_tile(&mut state, "card_shop", &mut rng);
    match event {
        Some(GameEvent::CardShopList { cards }) => {
            assert_eq!(cards.len(), 3, "expected 3 shop cards");
            assert!(cards.contains(&"get_out_of_jail".to_string()));
            assert!(cards.contains(&"bonus_200".to_string()));
            assert!(cards.contains(&"double_rent".to_string()));
        }
        other => panic!("expected CardShopList, got {other:?}"),
    }

    // Buy the bonus_200 card (price: 100)
    let initial_cash = state.active_player().unwrap().cash;
    let buy_event = GameEngine::execute(
        GameCommand::BuyCard {
            card_id: "bonus_200".to_string(),
            price: 100,
        },
        &mut state,
        &mut rng,
    );
    assert!(
        matches!(&buy_event, GameEvent::CardBought { card_id, price, .. } if card_id == "bonus_200" && *price == 100),
        "expected CardBought for bonus_200 at price 100, got {buy_event:?}"
    );

    // Verify cash deducted
    let final_cash = state.active_player().unwrap().cash;
    assert_eq!(final_cash, initial_cash - 100, "cash should be reduced by 100");

    // Verify card in inventory
    let player = state.active_player().unwrap();
    assert!(
        player.owned_cards.contains(&"bonus_200".to_string()),
        "player should own bonus_200 card, owned: {:?}",
        player.owned_cards
    );

    // Try buying with insufficient funds
    if let Some(p) = state.active_player_mut() {
        p.cash = 10; // not enough for any card
    }
    let fail_event = GameEngine::execute(
        GameCommand::BuyCard {
            card_id: "get_out_of_jail".to_string(),
            price: 50,
        },
        &mut state,
        &mut rng,
    );
    assert!(
        matches!(&fail_event, GameEvent::CommandRejected { reason } if reason == "insufficient_funds"),
        "expected insufficient_funds, got {fail_event:?}"
    );

    // Try buying an invalid card (give enough cash so insufficient_funds doesn't trigger first)
    if let Some(p) = state.active_player_mut() {
        p.cash = 5000;
    }
    let invalid_event = GameEngine::execute(
        GameCommand::BuyCard {
            card_id: "invalid_card".to_string(),
            price: 100,
        },
        &mut state,
        &mut rng,
    );
    assert!(
        matches!(&invalid_event, GameEvent::CommandRejected { reason } if reason == "invalid_card"),
        "expected invalid_card rejection, got {invalid_event:?}"
    );
}

/// test_buy_property_with_insufficient_funds
#[test]
fn test_buy_property_insufficient_funds() {
    let mut state = test_state();
    let mut rng = TestRng::new(42);

    // Set cash low
    if let Some(p) = state.active_player_mut() {
        p.cash = 50;
    }

    let buy_event = GameEngine::execute(
        GameCommand::BuyProperty {
            tile_id: "prop_a".to_string(), // costs 200
        },
        &mut state,
        &mut rng,
    );
    assert!(
        matches!(&buy_event, GameEvent::CommandRejected { reason } if reason == "insufficient_funds"),
        "expected insufficient_funds, got {buy_event:?}"
    );
}

/// test_end_turn_advances_to_next_player
#[test]
fn test_end_turn_cycle() {
    let mut state = test_state();
    let mut rng = TestRng::new(42);

    // End turn → should go to player 2
    let e1 = GameEngine::execute(GameCommand::EndTurn, &mut state, &mut rng);
    assert!(matches!(&e1, GameEvent::TurnAdvanced { turn: 1, .. }));
    assert_eq!(state.active_player_index, 1);

    // End turn → should go back to player 1
    let e2 = GameEngine::execute(GameCommand::EndTurn, &mut state, &mut rng);
    assert!(matches!(&e2, GameEvent::TurnAdvanced { turn: 2, .. }));
    assert_eq!(state.active_player_index, 0);
}

/// test_game_end: When only one player remains after bankruptcy elimination, game ends with a winner.
#[test]
fn test_game_end() {
    let mut state = test_state();
    let mut rng = TestRng::new(42);

    // Make player 1 (p1, active) bankrupt
    if let Some(p) = state.active_player_mut() {
        p.cash = -500;
    }
    assert!(state.active_player().unwrap().is_bankrupt());

    // End turn → should eliminate p1, leaving only p2 → GameWon
    let end_event = GameEngine::execute(GameCommand::EndTurn, &mut state, &mut rng);

    match &end_event {
        GameEvent::GameWon {
            winner_id,
            remaining_players,
        } => {
            assert_eq!(winner_id, "p2", "p2 should be the winner");
            assert_eq!(*remaining_players, 1, "only 1 player should remain");
        }
        other => panic!("expected GameWon, got {other:?}"),
    }

    // Only p2 should remain in the state
    assert_eq!(state.players.len(), 1);
    assert_eq!(state.players[0].id, "p2");

    // Verify the turn did not advance (game over)
    assert_eq!(state.current_turn, 0);
}

/// test_mortgage_and_redeem_property
#[test]
fn test_mortgage_and_redeem() {
    let mut state = test_state();
    let mut rng = TestRng::new(42);

    // First buy a property
    let buy_event = GameEngine::execute(
        GameCommand::BuyProperty {
            tile_id: "prop_a".to_string(),
        },
        &mut state,
        &mut rng,
    );
    assert!(matches!(&buy_event, GameEvent::PropertyBought { .. }));

    let cash_before_mortgage = state.active_player().unwrap().cash;

    // Mortgage it
    let mortgage_event = GameEngine::execute(
        GameCommand::Mortgage {
            tile_id: "prop_a".to_string(),
        },
        &mut state,
        &mut rng,
    );
    assert!(
        matches!(&mortgage_event, GameEvent::PropertyMortgaged { amount, .. } if *amount == 100),
        "expected PropertyMortgaged with 100, got {mortgage_event:?}"
    );

    // Cash should have increased by 100 (200/2)
    assert_eq!(
        state.active_player().unwrap().cash,
        cash_before_mortgage + 100
    );

    // Redeem it
    let redeem_event = GameEngine::execute(
        GameCommand::Redeem {
            tile_id: "prop_a".to_string(),
        },
        &mut state,
        &mut rng,
    );
    // Redeem cost: 200/2 + 200/10 = 100 + 20 = 120
    assert!(
        matches!(&redeem_event, GameEvent::PropertyRedeemed { amount, .. } if *amount == 120),
        "expected PropertyRedeemed with 120, got {redeem_event:?}"
    );
}
