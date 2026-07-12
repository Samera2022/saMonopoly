use crate::event_bus::EventBus;
use crate::builtin::commands::register_core_commands;
use crate::builtin::tiles::register_core_tile_behaviors;
use crate::subscribers::{EventLogger, GameLogicHandler};
use crate::example_plugins::{register_dice_stats, register_treasure_hunt};

/// Register core subscribers including built-in subscribers and example plugins.
pub fn register_core_subscribers(bus: &mut EventBus) {
    // Register built-in subscribers
    bus.subscribe(Box::new(EventLogger));
    bus.subscribe(Box::new(GameLogicHandler));

    // ═══ 示例插件注册 ═══════════════════════════════════════════
    // DiceStats: 监听骰子事件并输出统计信息
    register_dice_stats(bus);
    //
    // TreasureHunt: 在 Chance 格子上触发宝藏奖励
    register_treasure_hunt(bus);
    // ═════════════════════════════════════════════════════════════
}

pub fn build_core_engine() -> EventBus {
    let mut bus = EventBus::new();

    // Register core command handlers
    register_core_commands(&mut bus.command_handlers);

    // Register core tile behaviors
    register_core_tile_behaviors(&mut bus.tile_behaviors);

    // Register core subscribers (built-in + example plugins)
    register_core_subscribers(&mut bus);

    bus
}
