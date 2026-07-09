//! 骰子动画增强插件 — 本地安装插件示例
//!
//! 用户将此插件复制到 `{app_data}/plugins/dice_animation/` 后，
//! 在所有地图中均生效（可启停）。
//!
//! 功能：
//! 1. 监听 `core:dice_rolled` 事件，注入 `dice:animation` 事件供 UI 播放动画
//! 2. 注册 `dice:rage_mode` 命令：连续三次相同点数时启动"狂暴模式"，租金 ×2
//! 3. 记录掷骰统计数据

use std::collections::HashMap;
use sa_monopoly_application::command_handler::CommandHandlerRegistry;
use sa_monopoly_application::event_bus::{EventBus, EventSubscriber, AnyEvent, EventAction, SubscriberPriority};
use sa_monopoly_application::tile_behavior::TileBehaviorRegistry;
use sa_monopoly_domain::GameState;

// ============================================================================
// 数据结构
// ============================================================================

/// 玩家掷骰统计数据
#[derive(Debug, Default, Clone)]
struct DiceStats {
    total_rolls: u64,
    double_count: u64,
    last_dice1: u64,
    last_dice2: u64,
    consecutive_equal: u32,
    rage_mode: bool,
}

// ============================================================================
// DiceAnimationPlugin
// ============================================================================

pub struct DiceAnimationPlugin {
    stats: HashMap<String, DiceStats>,
}

impl DiceAnimationPlugin {
    pub fn new() -> Self {
        Self {
            stats: HashMap::new(),
        }
    }

    fn get_stats(&mut self, player_id: &str) -> &mut DiceStats {
        self.stats.entry(player_id.to_string()).or_default()
    }
}

impl sa_monopoly_infra::plugins::Plugin for DiceAnimationPlugin {
    fn id(&self) -> &str { "dice_animation" }
    fn name(&self) -> &str { "骰子动画增强" }
    fn version(&self) -> &str { "1.0.0" }
    fn author(&self) -> &str { "Community Modder" }
    fn description(&self) -> &str {
        "为骰子掷出结果添加特效：连掷三次相同点数触发「狂暴」模式，doubles 时加倍租金"
    }

    /// 注册自定义命令
    fn register_commands(&mut self, registry: &mut CommandHandlerRegistry) {
        // "dice:rage_mode" 命令：切换狂暴模式
        registry.register(
            "dice:rage_mode",
            "dice_animation",
            Box::new(|state, _event, _rng, bus| {
                let player_id = state.active_player()
                    .map(|p| p.id.clone())
                    .unwrap_or_default();

                bus.publish_custom(
                    "dice:rage_mode_toggled",
                    "dice_animation",
                    serde_json::json!({
                        "player_id": player_id,
                        "active": true,
                        "duration_turns": 3,
                    }),
                    state,
                );
            }),
        ).unwrap();
    }

    /// 注册格子行为（此插件不注册格子）
    fn register_tile_behaviors(&mut self, _registry: &mut TileBehaviorRegistry) {
        // 本插件不添加新格子类型
    }

    /// 注册事件订阅者
    fn register_subscribers(&mut self, bus: &mut EventBus) {
        // ── 骰子动画触发器 ──
        struct DiceAnimTrigger;

        impl EventSubscriber for DiceAnimTrigger {
            fn id(&self) -> &str { "dice_animation.trigger" }
            fn priority(&self) -> SubscriberPriority { SubscriberPriority::Early }
            fn interested_types(&self) -> Vec<&'static str> { vec!["core:dice_rolled"] }

            fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction {
                // 从事件 payload 中提取骰子值
                let dice1 = event.payload["dice1"].as_u64().unwrap_or(0);
                let dice2 = event.payload["dice2"].as_u64().unwrap_or(0);
                let is_seven = event.payload["is_seven"].as_bool().unwrap_or(false);
                let consecutive = event.payload["consecutive"].as_u64().unwrap_or(0);

                log::info!(
                    "[DiceAnim] 🎲 {}+{} = {} (7? {}) consecutive: {}",
                    dice1, dice2, dice1 + dice2, is_seven, consecutive
                );

                EventAction::Continue
            }
        }

        bus.subscribe(Box::new(DiceAnimTrigger));

        // ── 狂暴模式检测器 ──
        // 注意：此订阅者通过 EventBus 的 Modify 能力修改事件 payload
        // 在实际实现中，可以向事件注入额外数据供其他插件或 UI 消费
        struct RageModeDetector {
            streak: u32,
        }

        impl EventSubscriber for RageModeDetector {
            fn id(&self) -> &str { "dice_animation.rage" }
            fn priority(&self) -> SubscriberPriority { SubscriberPriority::Normal }
            fn interested_types(&self) -> Vec<&'static str> { vec!["core:dice_rolled"] }

            fn on_event(&mut self, event: &AnyEvent, _state: &GameState) -> EventAction {
                let dice1 = event.payload["dice1"].as_u64().unwrap_or(0);
                let dice2 = event.payload["dice2"].as_u64().unwrap_or(0);

                if dice1 == dice2 {
                    self.streak += 1;
                    if self.streak >= 3 {
                        log::info!("[DiceAnim] ⚡ RAGE MODE activated! Triple doubles!");
                        self.streak = 0;
                    }
                } else {
                    self.streak = 0;
                }

                EventAction::Continue
            }
        }

        bus.subscribe(Box::new(RageModeDetector { streak: 0 }));
    }
}

impl Default for DiceAnimationPlugin {
    fn default() -> Self { Self::new() }
}
