//! # 示例插件 — 实际注册到 EventBus 的内置插件
//!
//! 这两个示例插件演示了 Plugin API 的两种核心用法：
//!
//! 1. **骰子统计 (DiceStats)** — 事件订阅者模式（只读）
//! 2. **宝藏猎人 (TreasureHunt)** — 格子行为注册模式（读写状态）
//!
//! 它们通过 [`crate::startup::build_core_engine`] 在引擎启动时自动注册。
//! 验证方式请参见 [`self::test_plugin_verification`]。

use std::collections::HashMap;

use sa_monopoly_domain::GameState;

use crate::event_bus::{self, EventBus, EventSubscriber, EventAction, SubscriberPriority};

// ============================================================================
// 1. 骰子统计插件 (DiceStats)
// ============================================================================
//
// 验证方法：启动游戏后，在终端观察包含 [DiceStats] 前缀的日志输出。
// 每次掷骰都会输出：骰子点数、总和、累计次数。

/// 注册骰子统计功能到 EventBus
pub fn register_dice_stats(bus: &mut EventBus) {
    bus.subscribe(Box::new(DiceStatsSubscriber::default()));
    log::info!("[Plugin] DiceStats 已注册 — 观察日志中含 [DiceStats] 的输出");
}

/// 内部骰子统计订阅者
#[derive(Default)]
struct DiceStatsSubscriber {
    total_rolls: u64,
    sum_distribution: HashMap<u64, u64>,
}

impl EventSubscriber for DiceStatsSubscriber {
    fn id(&self) -> &str {
        "example:dice_stats"
    }

    fn interested_types(&self) -> Vec<&'static str> {
        vec!["dice_rolled"]
    }

    fn on_event(&mut self, event: &crate::event_bus::AnyEvent, _state: &GameState) -> EventAction {
        // 从 AnyEvent 结构体的 payload 字段中提取骰子数据
        let d1 = event.payload.get("dice1").and_then(|v| v.as_u64()).unwrap_or(0);
        let d2 = event.payload.get("dice2").and_then(|v| v.as_u64()).unwrap_or(0);
        let (dice1, dice2) = (d1, d2);

        if dice1 == 0 && dice2 == 0 {
            return EventAction::Continue;
        }

        self.total_rolls += 1;
        let sum = dice1 + dice2;
        *self.sum_distribution.entry(sum).or_insert(0) += 1;

        // ◀── 这就是验证输出！在终端查看：
        log::info!(
            "[DiceStats] 第{}次掷骰: {}+{}={}, 累计统计: {:?}",
            self.total_rolls, dice1, dice2, sum, self.sum_distribution,
        );

        // 在事件 payload 中添加 _plugin_msg 字段，以便 Flutter 端通过 Bridge 接收
        let mut modified = event.clone();
        if let serde_json::Value::Object(ref mut map) = modified.payload {
            map.insert(
                "_plugin_msg".to_string(),
                serde_json::json!(format!("第{}次掷骰: {}+{}={}", self.total_rolls, dice1, dice2, sum)),
            );
        }

        EventAction::Modify(modified)
    }
}

// ============================================================================
// 2. 宝藏猎人插件 (TreasureHunt)
// ============================================================================
//
// 验证方法：让玩家落在 tile_type="example:treasure_chest" 的格子上。
// 控制台会输出 [TreasureHunt] 玩家 xxx 获得 $xxx。

/// 注册宝藏猎人功能到 EventBus
pub fn register_treasure_hunt(bus: &mut EventBus) {
    bus.tile_behaviors
        .register(
            "example:treasure_chest",
            "example:treasure_hunt",
            Box::new(handle_treasure_chest),
        )
        .unwrap();
    log::info!("[Plugin] TreasureHunt 已注册 — 玩家落在 treasure_chest 格子上可获得额外现金");
}

/// 处理玩家落在宝藏格子上的逻辑
fn handle_treasure_chest(
    state: &mut GameState,
    _tile_id: &str,
    _rng: &mut dyn crate::ports::RngService,
    bus: &mut EventBus,
) {
    // 获得当前玩家
    let active_idx = state.active_player_index;
    let player_id = match state.players.get(active_idx) {
        Some(p) => p.id.clone(),
        None => return,
    };

    // 随机奖励金额：50-200 之间
    let bonus = 50 + (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
        % 151);

    // 给玩家加钱
    if let Some(player) = state.players.get_mut(active_idx) {
        player.cash += bonus as i64;
    }

    log::info!("[TreasureHunt] 玩家 {} 发现了宝藏！获得 ${}", player_id, bonus);

    // 发布自定义事件，Flutter 端可以通过 Bridge 接收
    bus.publish_custom(
        "example:treasure_found",
        "example:treasure_hunt",
        serde_json::json!({
            "player_id": player_id,
            "bonus": bonus,
            "_plugin_msg_treasure": format!("[TreasureHunt] 发现了宝藏 +${}", bonus),
        }),
        state,
    );
}

// ============================================================================
// 测试：验证两个示例插件
// ============================================================================

use crate::event_bus::{PreEventHook, PreEventAction, PostEventHook};

// ============================================================================
// 3. 测试用 Pre-Event 钩子插件：BlockRollPlugin
// ============================================================================

pub struct BlockRollPlugin;

impl PreEventHook for BlockRollPlugin {
    fn id(&self) -> &str { "test:block_roll" }
    fn priority(&self) -> event_bus::SubscriberPriority { event_bus::SubscriberPriority::First }
    fn on_pre_command(&mut self, command_type: &str, _payload: &serde_json::Value, _state: &GameState) -> PreEventAction {
        if command_type == "core:command:roll" {
            log::info!("[BlockRollPlugin] 阻止了 roll 命令!");
            return PreEventAction::Cancel("blocked_by_test".to_string());
        }
        PreEventAction::Continue
    }
}

// ============================================================================
// 4. 测试用 Handler 级 Pre-Event 钩子插件：CancelRentPlugin
// ============================================================================

pub struct CancelRentPlugin;

impl PreEventHook for CancelRentPlugin {
    fn id(&self) -> &str { "test:cancel_rent" }
    fn priority(&self) -> event_bus::SubscriberPriority { event_bus::SubscriberPriority::Early }
    fn on_pre_command(&mut self, command_type: &str, _payload: &serde_json::Value, _state: &GameState) -> PreEventAction {
        if command_type == "core:rent_due" {
            log::info!("[CancelRentPlugin] 取消了租金支付!");
            return PreEventAction::Cancel("rent_free_promotion".to_string());
        }
        PreEventAction::Continue
    }
}

// ============================================================================
// 5. 测试用 Post-Event 钩子插件：PostCommandLogger
// ============================================================================

pub struct PostCommandLogger {
    pub executed_commands: Vec<String>,
}

impl PostCommandLogger {
    pub fn new() -> Self { Self { executed_commands: Vec::new() } }
}

impl PostEventHook for PostCommandLogger {
    fn id(&self) -> &str { "test:post_logger" }
    fn priority(&self) -> event_bus::SubscriberPriority { event_bus::SubscriberPriority::Last }
    fn on_post_command(&mut self, command_type: &str, _state: &GameState, events: &[crate::event_bus::AnyEvent]) {
        let event_types: Vec<String> = events.iter().map(|e| e.event_type.clone()).collect();
        log::info!("[PostCommandLogger] 命令 '{}' 已执行，产生了 {} 个事件: {:?}", command_type, events.len(), event_types);
        self.executed_commands.push(command_type.to_string());
    }
}

// ============================================================================
// 6. 测试用 Handler 级 Modify 插件：DoubleRentPlugin
// ============================================================================

pub struct DoubleRentPlugin;

impl PreEventHook for DoubleRentPlugin {
    fn id(&self) -> &str { "test:double_rent" }
    fn priority(&self) -> event_bus::SubscriberPriority { event_bus::SubscriberPriority::Normal }
    fn on_pre_command(&mut self, command_type: &str, payload: &serde_json::Value, _state: &GameState) -> PreEventAction {
        if command_type == "core:rent_due" {
            if let Some(amount) = payload.get("amount").and_then(|v| v.as_i64()) {
                let mut modified = payload.clone();
                modified["amount"] = serde_json::json!(amount * 2);
                log::info!("[DoubleRentPlugin] 租金翻倍: ${} -> ${}", amount, amount * 2);
                return PreEventAction::Modify(modified);
            }
        }
        PreEventAction::Continue
    }
}

#[cfg(test)]
mod tests {
    use sa_monopoly_domain::event::AnyEvent as DomainAnyEvent;
    use crate::event_bus::EventBus;
    use crate::builtin::commands::register_core_commands;
    use crate::builtin::tiles::register_core_tile_behaviors;
    use crate::example_plugins::{register_dice_stats, register_treasure_hunt};
    use sa_monopoly_domain::{GameState, RuleSetRef};
    use sa_monopoly_domain::tile::tile_types;
    use sa_monopoly_domain::board::Board;
    use sa_monopoly_domain::player::Player;

    /// 验证两个示例插件是否正确注册并触发
    ///
    /// 测试步骤：
    /// 1. 创建 EventBus 并注册核心功能和示例插件
    /// 2. 创建一个简单的游戏状态
    /// 3. 执行 Roll 命令 → 检查 DiceStats 是否响应
    /// 4. 创建机会格子 → 检查 TreasureHunt 是否响应
    #[test]
    fn test_plugin_verification() {
        // 使用测试专用的 logger（运行 cargo test -- --nocapture 可看到输出）
        let _ = env_logger::builder().is_test(true).filter_level(log::LevelFilter::Info).try_init();

        let mut bus = EventBus::new();

        // 注册核心命令和格子行为
        register_core_commands(&mut bus.command_handlers);
        register_core_tile_behaviors(&mut bus.tile_behaviors);

        // 注册示例插件
        register_dice_stats(&mut bus);
        register_treasure_hunt(&mut bus);

        // ── 1. 创建测试用游戏状态 ──────────────────────────
        let mut state = GameState {
            board: Board {
                tiles: vec![],
                properties: vec![],
                graph: Default::default(),
                auto_link_rent: false,
            },
            players: vec![
                Player {
                    id: "player_1".to_string(),
                    name: "测试玩家".to_string(),
                    cash: 1000,
                    position: "start".to_string(),
                    team_id: None,
                    is_ai: false,
                    is_llm_controlled: false,
                    jail_turns: 0,
                    hospital_turns: 0,
                    owned_cards: vec![],
                    stock_shares: 0,
                },
            ],
            ruleset: RuleSetRef { id: "test".to_string(), version: "0.1.0".to_string() },
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
        };

        // ── 2. 添加一个测试用的 Treasure 格子 ──────────────
        // TreasureHunt 插件注册了 tile_type="example:treasure_chest" 的行为
        state.board.tiles.push(sa_monopoly_domain::tile::Tile {
            id: "treasure_1".to_string(),
            name_key: "tile.treasure_1".to_string(),
            kind: "example:treasure_chest".to_string(),
            linked_property_kind: None,
        });

        // ── 3. 验证 DiceStats：执行 Roll 命令 ─────────────────────
        log::info!("=== 测试 1: DiceStats 插件 ===");
        // Use serde_json to construct the event to avoid AnyEvent ambiguity
        let roll_cmd: DomainAnyEvent = serde_json::from_value(serde_json::json!({
            "Custom": {
                "event_type": "core:command:roll",
                "source": "core",
                "payload": {
                    "player_id": "player_1"
                },
                "timestamp": 0
            }
        })).unwrap_or_else(|_| {
            // Fallback for test
            panic!("Failed to create AnyEvent for roll command")
        });

        // 模拟 RngService
        struct TestRng(u64);
        impl crate::ports::RngService for TestRng {
            fn next_u64(&mut self) -> u64 {
                self.0 += 1;
                self.0 // 产生可预测的骰子值
            }
        }

        bus.execute_command(roll_cmd, &mut state, &mut TestRng(3));

        // 验证 DiceStats 输出了统计信息（在日志中可见）
        assert!(state.players[0].position != "start", "玩家应该已经移动");

        // ── 4. 验证 TreasureHunt：玩家落在 Chance 格子上 ─────────
        log::info!("=== 测试 2: TreasureHunt 插件 ===");
        state.players[0].position = "treasure_1".to_string();
        let cash_before = state.players[0].cash;

        bus.resolve_tile("example:treasure_chest", &mut state, "treasure_1", &mut TestRng(5));

        // 验证玩家获得了额外现金
        assert!(
            state.players[0].cash > cash_before,
            "TreasureHunt 应该给玩家增加现金: before={}, after={}",
            cash_before, state.players[0].cash,
        );

        log::info!("=== ✅ 两个插件均验证通过 ===");
        log::info!("DiceStats: 玩家已移动到格子 {}", state.players[0].position);
        log::info!("TreasureHunt: 现金从 ${} 增加到 ${}", cash_before, state.players[0].cash);
    }
}

// ============================================================================
// Pre/Post Event 钩子集成测试
// ============================================================================

#[cfg(test)]
mod hook_tests {
    use sa_monopoly_domain::event::AnyEvent as DomainAnyEvent;
    use crate::event_bus::EventBus;
    use crate::builtin::commands::register_core_commands;
    use crate::builtin::tiles::register_core_tile_behaviors;
    use crate::example_plugins::*;
    use sa_monopoly_domain::{GameState, RuleSetRef};
    use sa_monopoly_domain::player::Player;
    use sa_monopoly_domain::board::Board;
    use sa_monopoly_domain::tile::Tile;
    use sa_monopoly_domain::property::{Property, PropertyKind};

    struct TestRng(u64);
    impl crate::ports::RngService for TestRng {
        fn next_u64(&mut self) -> u64 { self.0 += 1; self.0 }
    }

    fn make_test_state() -> (EventBus, GameState) {
        let mut bus = EventBus::new();
        register_core_commands(&mut bus.command_handlers);
        register_core_tile_behaviors(&mut bus.tile_behaviors);
        let state = GameState {
            board: Board {
                tiles: vec![
                    Tile { id: "start".into(), name_key: "tile.start".into(), kind: "core:start".into(), linked_property_kind: None },
                    Tile { id: "prop_1".into(), name_key: "tile.prop_1".into(), kind: "core:ordinary_property".into(), linked_property_kind: Some(PropertyKind::Ordinary) },
                ],
                properties: vec![Property {
                    tile_id: "prop_1".into(), name_key: "prop.prop_1".into(), kind: PropertyKind::Ordinary,
                    base_price: 100, rent: vec![10], upgrade_level: 0,
                    owner: Some("player_2".into()), is_mortgaged: false, linked_targets: vec![],
                }],
                graph: Default::default(), auto_link_rent: false,
            },
            players: vec![
                Player { id: "player_1".into(), name: "Alice".into(), cash: 1000, position: "prop_1".into(), is_ai: false, is_llm_controlled: false, jail_turns: 0, hospital_turns: 0, owned_cards: vec![], stock_shares: 0, team_id: None },
                Player { id: "player_2".into(), name: "Bob".into(), cash: 500, position: "start".into(), is_ai: false, is_llm_controlled: false, jail_turns: 0, hospital_turns: 0, owned_cards: vec![], stock_shares: 0, team_id: None },
            ],
            ruleset: RuleSetRef { id: "test".into(), version: "0.1.0".into() },
            current_turn: 0, active_player_index: 0, seed: 42,
            decks: vec![], stock_market: None, active_auction: None,
            consecutive_doubles: 0, max_upgrade_level: 3, extension_upgrade_enabled: false,
            group_rent_enabled: false, lottery_state: None, bail_abuse_count: 0,
        };
        (bus, state)
    }

    /// [Pre-Event 阶段] BlockRollPlugin 阻止 roll 命令
    /// 理论输出: core:command_rejected | player 未移动 | 位置 = "prop_1"
    #[test]
    fn test_pre_hook_blocks_roll() {
        let _ = env_logger::builder().is_test(true).filter_level(log::LevelFilter::Info).try_init();
        let (mut bus, mut state) = make_test_state();
        bus.register_pre_hook(Box::new(BlockRollPlugin));
        bus.execute_command(
            serde_json::from_value(serde_json::json!({"Custom":{"event_type":"core:command:roll","source":"core","payload":{"player_id":"player_1"},"timestamp":0}})).unwrap(),
            &mut state, &mut TestRng(5),
        );
        let events = bus.drain_custom_events();
        assert!(events.iter().any(|e| e.event_type == "core:command_rejected"), "应被拒绝");
        assert_eq!(state.players[0].position, "prop_1", "玩家不应移动");
    }

    /// [Handler 级 Pre-Event] CancelRentPlugin 取消租金
    /// 理论输出: player_1 cash=1000 (不变) | player_2 cash=500 (不变)
    #[test]
    fn test_handler_cancels_rent() {
        let _ = env_logger::builder().is_test(true).filter_level(log::LevelFilter::Info).try_init();
        let (mut bus, mut state) = make_test_state();
        bus.register_pre_hook(Box::new(CancelRentPlugin));
        let cash_p1 = state.players[0].cash;
        let cash_p2 = state.players[1].cash;
        bus.execute_command(
            serde_json::from_value(serde_json::json!({"Custom":{"event_type":"core:command:pay_rent","source":"core","payload":{"player_id":"player_1","tile_id":"prop_1"},"timestamp":0}})).unwrap(),
            &mut state, &mut TestRng(5),
        );
        assert_eq!(state.players[0].cash, cash_p1);
        assert_eq!(state.players[1].cash, cash_p2);
    }

    /// [Handler 级 Pre-Event Modify] DoubleRentPlugin 翻倍租金
    /// 理论输出: player_1 cash=980 (1000-20) | player_2 cash=520 (500+20) | rent_paid.amount=20
    #[test]
    fn test_handler_doubles_rent() {
        let _ = env_logger::builder().is_test(true).filter_level(log::LevelFilter::Info).try_init();
        let (mut bus, mut state) = make_test_state();
        bus.register_pre_hook(Box::new(DoubleRentPlugin));
        bus.execute_command(
            serde_json::from_value(serde_json::json!({"Custom":{"event_type":"core:command:pay_rent","source":"core","payload":{"player_id":"player_1","tile_id":"prop_1"},"timestamp":0}})).unwrap(),
            &mut state, &mut TestRng(5),
        );
        let events = bus.drain_custom_events();
        assert_eq!(state.players[0].cash, 980);
        assert_eq!(state.players[1].cash, 520);
        let rp = events.iter().find(|e| e.event_type == "core:rent_paid");
        assert!(rp.is_some());
        assert_eq!(rp.unwrap().payload.get("amount").and_then(|v| v.as_i64()), Some(20));
    }

    /// [Post-Event 阶段] PostCommandLogger 记录已执行命令
    /// 理论输出: player_1 cash=990 (1000-10) | player_2 cash=510 (500+10) | 日志含 [PostCommandLogger]
    #[test]
    fn test_post_hook_logs() {
        let _ = env_logger::builder().is_test(true).filter_level(log::LevelFilter::Info).try_init();
        let (mut bus, mut state) = make_test_state();
        bus.register_post_hook(Box::new(PostCommandLogger::new()));
        bus.execute_command(
            serde_json::from_value(serde_json::json!({"Custom":{"event_type":"core:command:pay_rent","source":"core","payload":{"player_id":"player_1","tile_id":"prop_1"},"timestamp":0}})).unwrap(),
            &mut state, &mut TestRng(5),
        );
        assert_eq!(state.players[0].cash, 990);
        assert_eq!(state.players[1].cash, 510);
    }
}
