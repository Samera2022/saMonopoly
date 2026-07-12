// Integration tests for the sa-monopoly-application crate.
//
// The old engine-based tests (GameEngine, GameCommand, GameEvent) have been
// removed as part of the migration to the EventBus architecture.
//
// New tests should be written against EventBus::execute_command and
// EventBus::publish_custom.

#[cfg(test)]
mod tests {
    use sa_monopoly_domain::{
        GameState, Board, BoardGraph, Player, RuleSetRef,
        tile::{Tile, tile_types},
    };
    use crate::event_bus::EventBus;
    use crate::builtin::commands::register_core_commands;
    use crate::builtin::tiles::register_core_tile_behaviors;
    use crate::ports::RngService;
    use crate::startup::register_core_subscribers;

    struct TestRng(u64);
    impl RngService for TestRng {
        fn next_u64(&mut self) -> u64 {
            let v = self.0;
            self.0 = self.0.wrapping_add(1);
            v
        }
    }

    fn make_board() -> Board {
        // 4 tiles: start(0) -> card_shop_1(1) -> mid(2) -> end(3)
        Board {
            tiles: vec![
                Tile {
                    id: "start".into(),
                    name_key: "tile.start".into(),
                    kind: tile_types::START.into(),
                    linked_property_kind: None,
                },
                Tile {
                    id: "card_shop_1".into(),
                    name_key: "tile.card_shop_1".into(),
                    kind: tile_types::CARD_SHOP.into(),  // "core:card_shop"
                    linked_property_kind: None,
                },
                Tile {
                    id: "mid".into(),
                    name_key: "tile.mid".into(),
                    kind: tile_types::START.into(),
                    linked_property_kind: None,
                },
                Tile {
                    id: "end".into(),
                    name_key: "tile.end".into(),
                    kind: tile_types::START.into(),
                    linked_property_kind: None,
                },
            ],
            properties: vec![],
            graph: BoardGraph::default(),
            auto_link_rent: false,
        }
    }

    fn make_player(name: &str, pos: &str) -> Player {
        Player {
            id: format!("player_{name}"),
            name: name.into(),
            cash: 1500,
            position: pos.into(),
            is_ai: false,
            is_llm_controlled: false,
            jail_turns: 0,
            hospital_turns: 0,
            owned_cards: vec![],
            stock_shares: 0,
            team_id: None,
        }
    }

    /// Test: rolling onto a card_shop tile should publish core:card_shop_landed
    #[test]
    fn test_roll_lands_on_card_shop_publishes_event() {
        let _ = env_logger::builder().is_test(true).filter_level(log::LevelFilter::Info).try_init();

        let mut bus = EventBus::new();
        register_core_commands(&mut bus.command_handlers);
        register_core_tile_behaviors(&mut bus.tile_behaviors);
        register_core_subscribers(&mut bus);

        let board = make_board();
        let players = vec![make_player("0", "start")];

        let mut state = GameState {
            board,
            players,
            ruleset: RuleSetRef { id: "test".into(), version: "1.0".into() },
            current_turn: 0,
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
        };

        // Roll with RNG that generates dice1=1, dice2=1 (sum=2).
        // Player moves from start (idx 0) to card_shop_1 (idx 2 mod 4 = 2... wait)
        // Actually: 0 + 1 = 1 → card_shop_1. With dice sum=2, (0+2)%4 = 2 → "mid"
        // We need dice sum=1, but minimum is 2. So we need to adjust.
        // rng.next_u64() = 0 → (0 % 6) + 1 = 1
        // rng.next_u64() = 1 → (1 % 6) + 1 = 2
        // Sum = 3 → (0 + 3) % 4 = 3 → "end" (not card_shop)
        // 
        // We need the player to land on tile index 1 (card_shop_1).
        // (0 + steps) % 4 = 1 → steps = 1 or 5 or 9...
        // Minimum dice sum is 2 (1+1) → steps=2 → (0+2)%4 = 2 → "mid"
        // That won't reach card_shop_1.
        //
        // Let's put card_shop at index 2 and use dice sum=2:
        // Board: start(0) → prop(1) → card_shop(2) → end(3)
        // Dice: 1+1=2 → (0+2)%4 = 2 → card_shop! ✅

        // Re-build board with card_shop at index 2
        let board = Board {
            tiles: vec![
                Tile { id: "start".into(), name_key: "tile.start".into(), kind: tile_types::START.into(), linked_property_kind: None },
                Tile { id: "prop".into(), name_key: "tile.prop".into(), kind: tile_types::ORDINARY_PROPERTY.into(), linked_property_kind: None },
                Tile { id: "card_shop_1".into(), name_key: "tile.card_shop_1".into(), kind: tile_types::CARD_SHOP.into(), linked_property_kind: None },
                Tile { id: "end".into(), name_key: "tile.end".into(), kind: tile_types::START.into(), linked_property_kind: None },
            ],
            properties: vec![],
            graph: BoardGraph::default(),
            auto_link_rent: false,
        };
        state.board = board;

        // RNG seed 0: next_u64()=0 → dice1 = (0%6)+1 = 1
        // next_u64()=1 → dice2 = (1%6)+1 = 2
        // Sum=3 → (0+3)%4 = 3 → "end" — NOT card_shop!
        // Need: (0 + steps) % 4 = 2 → steps = 2 or 6 or 10...
        // With dice sum=2: dice1=1, dice2=1 → need rng values where (v%6)+1=1 → v%6=0
        // So we need rng where first two calls return multiples of 6 (v % 6 == 0)
        // Seed 0: 0%6=0, but 1%6=1
        // We could use seed where rng generates values that are multiples of 6.
        // Actually, let's just use a deterministic seed we control.

        // Use TestRng that returns 0, 0, ... (first dice = 1, second dice = 1, sum=2)
        let mut rng = TestRng(0);
        // First call: 0 % 6 = 0 → +1 = 1 ✅ (dice1)
        // But second call: 1 % 6 = 1 → +1 = 2 (dice2, sum=3)
        // Hmm. We need both dice to be 1. That means both rng values must be multiples of 6.

        // Let me use a custom approach: set the seed so that rng returns two values that are multiples of 6.
        // XorShift64 with state=0 always returns 0 (x ^= x << 13 = 0, etc.)
        // So TestRng(0) returns 0, 1, 2, 3, ... 
        // Let's just skip ahead to get two 0-values... actually that's not possible with TestRng just incrementing.
        // 
        // Simplest fix: use TestRng with values that produce dice1=1 and dice2=1
        // We need rng to return 0 (→ dice 1) and 0 again (→ dice 1) — not possible with incrementing
        // 
        // Alternative: use a different seed
        // Or: use a board where card_shop is at index where any dice sum works
        // With 4 tiles: steps=2 → (0+2)%4 = 2 (card_shop) if steps sum to 2
        // Minimum sum=2 (1+1), which is exactly 2. Perfect!
        // We need both dice to be 1: dice1 = (v1%6)+1 = 1 → v1%6=0 → v1=0,6,12,...
        //                      dice2 = (v2%6)+1 = 1 → v2%6=0 → v2=0,6,12,...
        // With TestRng(0): 0%6=0→1, 1%6=1→2... not both 1.
        // 
        // Easiest: implement TestRng to cycle through known values
        // OR just use two separate RNG calls with the same value
        // OR override TestRng to return predefined values

        // Simplest: use a custom RngService that returns specific values
        struct FixedRng(Vec<u64>, usize);
        impl RngService for FixedRng {
            fn next_u64(&mut self) -> u64 {
                let v = self.0[self.1 % self.0.len()];
                self.1 += 1;
                v
            }
        }
        let mut rng = FixedRng(vec![0, 0, 0, 0, 0], 0); // All die rolls = (0%6)+1 = 1
        // dice1=1, dice2=1, sum=2 → (0+2)%4 = 2 → card_shop_1 ✅

        let command = sa_monopoly_domain::event::AnyEvent::Custom {
            event_type: "core:command:roll".into(),
            source: "core".into(),
            payload: serde_json::json!({"player_id": "player_0"}),
            timestamp: 0,
        };

        bus.execute_command(command, &mut state, &mut rng);

        // Drain events
        let events = bus.drain_custom_events();
        
        // Print all events for debugging
        for (i, e) in events.iter().enumerate() {
            log::info!("Event[{}]: event_type={}", i, e.event_type);
        }

        // Verify player position
        assert_eq!(state.players[0].position, "card_shop_1",
            "Player should have moved to card_shop_1");

        // Verify card_shop_landed event was published
        let card_shop_event = events.iter().find(|e| e.event_type == "core:card_shop_landed");
        assert!(card_shop_event.is_some(), 
            "Expected core:card_shop_landed event in: {:?}", 
            events.iter().map(|e| &e.event_type).collect::<Vec<_>>());
        
        // Verify the event has the right fields
        if let Some(ev) = card_shop_event {
            let tile_id = ev.payload.get("tile_id").and_then(|v| v.as_str());
            assert_eq!(tile_id, Some("card_shop_1"), "tile_id should be card_shop_1");
        }
    }
}
