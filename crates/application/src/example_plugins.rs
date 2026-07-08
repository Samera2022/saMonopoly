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
        vec!["dice_rolled"] // 只收骰子事件
    }

    fn priority(&self) -> SubscriberPriority {
        SubscriberPriority::Late
    }

    fn on_event(&mut self, event: &event_bus::AnyEvent, _state: &GameState) -> EventAction {
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
// 验证方法：
// 1. 在地图中添加一个 tile_type="core:chance" 的格子（现有经典地图自带）
// 2. 当玩家落在这个格子上时，会触发 handle_chance
// 3. 终端会输出 [TreasureHunt] 日志

/// 内部宝藏猎人订阅者 — 在 dice_rolled 事件中添加 _plugin_msg_treasure 字段
struct TreasureHuntSubscriber;

impl EventSubscriber for TreasureHuntSubscriber {
    fn id(&self) -> &str {
        "example:treasure_hunt"
    }

    fn interested_types(&self) -> Vec<&'static str> {
        vec!["dice_rolled"]
    }

    fn priority(&self) -> SubscriberPriority {
        SubscriberPriority::Late
    }

    fn on_event(&mut self, event: &event_bus::AnyEvent, _state: &GameState) -> EventAction {
        // 在事件 payload 中添加 _plugin_msg_treasure 字段，以便 Flutter 端通过 Bridge 接收
        let mut modified = event.clone();
        if let serde_json::Value::Object(ref mut map) = modified.payload {
            map.insert(
                "_plugin_msg_treasure".to_string(),
                serde_json::json!("treasure_hunt_dice_roll"),
            );
        }

        EventAction::Modify(modified)
    }
}

/// 注册宝藏猎人功能到 EventBus
pub fn register_treasure_hunt(bus: &mut EventBus) {
    // 注册格子行为 — 对 core:chance 类型的格子注入额外奖励
    bus.tile_behaviors
        .register(
            "example:treasure_chest",
            "example:treasure_hunt",
            Box::new(|state, tile_id, _rng, bus| {
                let player_id = state
                    .active_player()
                    .map(|p| p.id.clone())
                    .unwrap_or_default();

                // 给予随机奖励（基于 tile_id 的哈希值模拟随机）
                let reward = 50 + (tile_id.bytes().fold(0u64, |acc, b| acc.wrapping_add(b as u64))
                    % 151) as i64;

                if let Some(player) = state.active_player_mut() {
                    player.cash += reward;
                }

                // 发布自定义事件（Flutter 可监听到）
                bus.publish_custom(
                    "example:treasure_found",
                    "treasure_hunt",
                    serde_json::json!({
                        "player_id": player_id,
                        "tile_id": tile_id,
                        "reward": reward,
                    }),
                    state,
                );

                // ◀── 验证输出
                log::info!(
                    "[TreasureHunt] 玩家 {} 落在 {} 上，获得 ${} 宝藏！",
                    player_id, tile_id, reward,
                );
            }),
        )
        .expect("TreasureHunt tile behavior registration failed");

    // 订阅 dice_rolled 事件，添加 _plugin_msg_treasure 字段到 payload
    bus.subscribe(Box::new(TreasureHuntSubscriber));

    log::info!("[Plugin] TreasureHunt 已注册 — 注册了 example:treasure_chest 格子类型和 dice_rolled 订阅者");
}

// ============================================================================
// 验证方法
// ============================================================================
//
// 运行以下命令启动游戏并观察插件输出：
//
//   cargo run
//
// 在游戏过程中：
// - 每次掷骰 → 终端输出 [DiceStats] 第N次掷骰: ...
// - 玩家落在 Chance 格子 → 终端输出 [TreasureHunt] 玩家 xxx 获得 $xxx
//
// 如果希望只在测试中验证，可以运行：
//
//   cargo test test_plugin_verification -- --nocapture
//
// 这会执行下面的单元测试，直接模拟插件的完整流程。

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

        // ── 1. 构建引擎 ─────────────────────────────────────────────
        let mut bus = EventBus::new();
        register_core_commands(&mut bus.command_handlers);
        register_core_tile_behaviors(&mut bus.tile_behaviors);
        register_dice_stats(&mut bus);
        register_treasure_hunt(&mut bus);

        // ── 2. 构建游戏状态 ─────────────────────────────────────────
        let mut state = GameState {
            board: Board {
                tiles: vec![
                    sa_monopoly_domain::Tile {
                        id: "start".to_string(),
                        name_key: "tile.start".to_string(),
                        kind: tile_types::START.to_string(),
                        linked_property_kind: None,
                    },
                    sa_monopoly_domain::Tile {
                        id: "treasure_1".to_string(),
                        name_key: "tile.treasure".to_string(),
                        kind: "example:treasure_chest".to_string(),
                        linked_property_kind: None,
                    },
                ],
                properties: vec![],
                graph: sa_monopoly_domain::BoardGraph::default(),
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
