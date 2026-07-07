//! 传送门系统插件 — 地图捆绑插件示例
//!
//! 功能：注册 "portal" 格子系统，玩家落在传送门上时被传送到目标位置。
//!
//! 地图 `map.json` 声明：
//! ```json
//! {
//!     "plugins": [
//!         {
//!             "id": "portal_system",
//!             "name": "传送门系统",
//!             "min_version": "1.0.0",
//!             "mandatory": false,
//!             "source": "bundled"
//!         }
//!     ],
//!     "tiles": [
//!         { "id": "portal_red", "name_key": "tile.portal_red",
//!           "tile_type": "SpecialProperty",
//!           "attributes": { "plugin": "portal_system", "pair": "portal_blue" } },
//!         { "id": "portal_blue", "name_key": "tile.portal_blue",
//!           "tile_type": "SpecialProperty",
//!           "attributes": { "plugin": "portal_system", "pair": "portal_red" } }
//!     ]
//! }
//! ```

use std::collections::HashMap;
use sa_monopoly_application::event_bus::{EventBus, EventSubscriber, AnyEvent, EventAction, SubscriberPriority};
use sa_monopoly_application::tile_behavior::TileBehaviorRegistry;
use sa_monopoly_domain::GameState;

// ============================================================================
// PortalPlugin — implements the Plugin trait
// ============================================================================

pub struct PortalPlugin {
    /// 传送门配对表: tile_id → target_tile_id
    portals: HashMap<String, String>,
}

impl PortalPlugin {
    pub fn new() -> Self {
        Self {
            portals: HashMap::new(),
        }
    }

    /// 从地图的格子定义中加载传送门配对
    pub fn load_portals(&mut self, state: &GameState) {
        for tile in &state.board.tiles {
            // 查找 tile 属性中 plugin="portal_system" 的格子
            // 在实际实现中，通过 tile 的 custom data 或 attributes 获取
            if tile.id.starts_with("portal_") {
                // 简化的配对逻辑：portal_red ↔ portal_blue
                let pair = if tile.id == "portal_red" {
                    "portal_blue".to_string()
                } else if tile.id == "portal_blue" {
                    "portal_red".to_string()
                } else {
                    continue;
                };
                self.portals.insert(tile.id.clone(), pair);
            }
        }
    }
}

impl sa_monopoly_infra::plugins::Plugin for PortalPlugin {
    fn id(&self) -> &str { "portal_system" }
    fn name(&self) -> &str { "传送门系统" }
    fn version(&self) -> &str { "1.0.0" }
    fn author(&self) -> &str { "Map Author" }
    fn description(&self) -> &str { "添加传送门格子：玩家落在传送门上会被传送到另一个传送门" }

    /// 注册传送门格子行为
    fn register_tile_behaviors(&mut self, registry: &mut TileBehaviorRegistry) {
        let portals = self.portals.clone();
        registry.register(
            "plugin:portal",  // 格子类型标识符
            "portal_system",
            Box::new(move |state, tile_id, _rng, bus| {
                // 查找传送目标
                if let Some(target) = portals.get(tile_id) {
                    // 获取当前玩家
                    let player_id = state.active_player()
                        .map(|p| p.id.clone())
                        .unwrap_or_default();

                    // 传送玩家
                    if let Some(player) = state.active_player_mut() {
                        player.position = target.clone();
                    }

                    // 发布传送事件
                    bus.publish_custom(
                        "portal:teleported",
                        "portal_system",
                        serde_json::json!({
                            "player_id": player_id,
                            "from": tile_id,
                            "to": target,
                        }),
                        state,
                    );

                    log::info!("[Portal] {} teleported from {} to {}", player_id, tile_id, target);
                } else {
                    log::warn!("[Portal] No target found for portal '{}'", tile_id);
                }
            }),
        ).unwrap();
    }

    /// 注册订阅者：监听玩家移动，检查是否落在传送门上
    fn register_subscribers(&mut self, bus: &mut EventBus) {
        struct PortalTrigger;
        impl EventSubscriber for PortalTrigger {
            fn id(&self) -> &str { "portal_system.trigger" }
            fn priority(&self) -> SubscriberPriority { SubscriberPriority::Normal }
            fn interested_types(&self) -> Vec<&'static str> {
                vec!["core:player_moved"]
            }
            fn on_event(&mut self, event: &AnyEvent, _state: &GameState) -> EventAction {
                // 当玩家移动时，检查是否落在 portal 格子上
                // (实际触发在 tile_behavior 中处理)
                log::debug!("[Portal] Player moved event: {:?}", event);
                EventAction::Continue
            }
        }
        bus.subscribe(Box::new(PortalTrigger));
    }
}

impl Default for PortalPlugin {
    fn default() -> Self { Self::new() }
}
