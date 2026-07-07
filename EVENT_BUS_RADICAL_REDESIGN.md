# EventBus 激进改革方案 — 完全事件驱动架构

> **原则**：不保留任何历史包袱。核心引擎、命令、事件、格子全部通过 EventBus 连接。插件不是"附加物"，而是与核心代码平等的参与者。

---

## 1. 核心理念：一切皆事件

### 旧架构（当前）
```
GameCommand → GameEngine::execute() → GameEvent → BridgeResponse → Flutter
```

### 新架构（激进改革）
```
                    ┌──────────────────────────────────────┐
                    │            EventBus                  │
                    │                                      │
CommandEvent ──────►│  CommandHandlerRegistry               │
  (Roll)            │    ├─ core::roll_handler             │──► DiceRolledEvent
                    │    ├─ core::buy_property_handler     │──► PropertyBoughtEvent
                    │    ├─ core::end_turn_handler         │──► TurnAdvancedEvent
                    │    └─ plugin::custom_handler         │──► CustomEvent
                    │                                      │
TileEvent ─────────►│  TileHandlerRegistry                  │
  (Land on X)      │    ├─ core::ordinary_property        │──► RentEvent
                    │    ├─ core::jail_handler             │──► JailEvent
                    │    └─ plugin::magic_portal_handler   │──► CustomEvent
                    │                                      │
                    │  Event Subscribers                    │
                    │    ├─ BridgeBroadcaster → Flutter    │
                    │    ├─ SchedulerBridge → timed effects│
                    │    ├─ Logger → log                   │
                    │    ├─ NetworkSync → peers            │
                    │    └─ Plugin subscribers             │
                    └──────────────────────────────────────┘
```

**所有组件都是 EventBus 上的对等节点**，没有"核心 vs 插件"的区分。

---

## 2. 删除封闭枚举

### 2.1 `GameEvent` 枚举 → 删除

```rust
// ❌ 删除整个 GameEvent 枚举
// 所有事件改为独立结构体，通过 AnyEvent 统一传递

// ✅ 新方案：事件是实现了 Event  trait 的结构体
// 事件类型完全由字符串标识符区分
```

### 2.2 `GameCommand` 枚举 → 删除

```rust
// ❌ 删除整个 GameCommand 枚举
// 命令也是事件的一种（CommandEvent）
```

### 2.3 `TileKind` 枚举 → 删除

```rust
// ❌ 删除整个 TileKind 枚举
// 格子类型改为 String 标识符 + 行为注册表
```

---

## 3. 新类型系统

### 3.1 `Event` trait

```rust
// crates/domain/src/event.rs (新文件)
use serde::{Serialize, Deserialize};
use std::any::Any;

/// 任何事件都必须实现此 trait
pub trait GameEvent: Send + Sync + 'static {
    /// 事件类型标识符（全局唯一，如 "core:dice_rolled"）
    fn event_type(&self) -> &'static str;

    /// 来源（"core" 或插件 ID）
    fn source(&self) -> &str {
        "core"
    }

    /// 用于 downcasting
    fn as_any(&self) -> &dyn Any;
}

/// 统一事件包装器
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AnyEvent {
    /// 核心事件（Rust 类型安全，通过 serde 序列化）
    Typed {
        event_type: String,
        source: String,
        #[serde(with = "serde_json::value::RawValue")]
        payload: Box<serde_json::value::RawValue>,
        timestamp: u64,
    },
    /// 模组自定义事件（无 Rust 类型，纯 JSON）
    Custom {
        event_type: String,
        source: String,
        payload: serde_json::Value,
        timestamp: u64,
    },
}
```

### 3.2 核心事件定义（独立结构体）

```rust
// crates/domain/src/events/ 目录
// 每个事件一个文件，或集中在一个 mod 中

// core_events.rs
pub mod core_events {
    use serde::{Serialize, Deserialize};
    use super::GameEvent;

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct DiceRolled {
        pub dice1: u64,
        pub dice2: u64,
        pub is_seven: bool,
        pub consecutive: u32,
        pub player_id: String,
    }
    impl GameEvent for DiceRolled {
        fn event_type(&self) -> &'static str { "core:dice_rolled" }
        fn as_any(&self) -> &dyn std::any::Any { self }
    }

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct TurnAdvanced {
        pub turn: u64,
        pub eliminated_players: Vec<String>,
    }
    impl GameEvent for TurnAdvanced {
        fn event_type(&self) -> &'static str { "core:turn_advanced" }
        fn as_any(&self) -> &dyn std::any::Any { self }
    }

    // ... 所有核心事件类似定义
}
```

### 3.3 AnyEvent 序列化桥接

核心事件在 EventBus 内部以 `AnyEvent::Typed` 形式传递，payload 是预序列化的 JSON：

```rust
impl AnyEvent {
    /// 从实现了 GameEvent + Serialize 的事件创建
    pub fn from_typed<E: GameEvent + Serialize>(event: &E) -> Result<Self, serde_json::Error> {
        let json = serde_json::value::to_raw_value(&event)?;
        Ok(AnyEvent::Typed {
            event_type: event.event_type().to_string(),
            source: event.source().to_string(),
            payload: json,
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
        })
    }

    /// 反序列化为具体类型
    pub fn into_typed<E: GameEvent + DeserializeOwned>(self) -> Result<E, serde_json::Error> {
        match self {
            AnyEvent::Typed { payload, .. } => {
                serde_json::from_str(payload.get())
            }
            AnyEvent::Custom { payload, .. } => {
                serde_json::from_value(payload)
            }
        }
    }
}
```

---

## 4. 新命令系统：Command 是事件的一种

### 4.1 命令定义为事件

```rust
// crates/domain/src/events/command_events.rs
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RollCommand {
    pub player_id: String,
}
impl GameEvent for RollCommand {
    fn event_type(&self) -> &'static str { "core:command:roll" }
    fn as_any(&self) -> &dyn std::any::Any { self }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BuyPropertyCommand {
    pub player_id: String,
    pub tile_id: String,
}
impl GameEvent for BuyPropertyCommand {
    fn event_type(&self) -> &'static str { "core:command:buy_property" }
    fn as_any(&self) -> &dyn std::any::Any { self }
}

// 模组自定义命令
// 无需 Rust 类型，直接用 AnyEvent::Custom
```

### 4.2 命令处理器注册表

```rust
// crates/application/src/command_handler.rs (新)
use sa_monopoly_domain::GameState;
use crate::event_bus::{EventBus, AnyEvent};

/// 命令处理器签名
pub type CommandHandler = Box<
    dyn FnMut(&mut GameState, AnyEvent, &mut dyn RngService, &mut EventBus) + Send + Sync
>;

/// 命令处理器注册表
pub struct CommandHandlerRegistry {
    handlers: HashMap<String, (CommandHandler, String)>, // (handler, plugin_id)
}

impl CommandHandlerRegistry {
    pub fn new() -> Self { Self { handlers: HashMap::new() } }

    /// 注册命令处理器
    pub fn register(
        &mut self,
        command_type: &str,  // "core:command:roll"
        plugin_id: &str,
        handler: CommandHandler,
    ) -> Result<(), String> {
        if self.handlers.contains_key(command_type) {
            return Err(format!("command handler '{}' already registered", command_type));
        }
        self.handlers.insert(
            command_type.to_string(),
            (handler, plugin_id.to_string()),
        );
        Ok(())
    }

    /// 注销某个插件的所有处理器
    pub fn unregister_plugin(&mut self, plugin_id: &str) {
        self.handlers.retain(|_, (_, pid)| pid != plugin_id);
    }

    /// 分发命令
    pub fn dispatch(
        &mut self,
        command_type: &str,
        state: &mut GameState,
        event: AnyEvent,
        rng: &mut dyn RngService,
        bus: &mut EventBus,
    ) -> bool {
        if let Some((handler, _)) = self.handlers.get_mut(command_type) {
            handler(state, event, rng, bus);
            true
        } else {
            false
        }
    }
}
```

---

## 5. 新格子系统：TileBehavior 注册表

### 5.1 格子类型定义为字符串

```rust
// crates/domain/src/tile.rs (重写)

/// 格子类型：完全开放的字符串标识符
pub type TileTypeId = String;

/// 预定义的核心格子类型常量
pub mod tile_types {
    pub const START: &str = "core:start";
    pub const ORDINARY_PROPERTY: &str = "core:ordinary_property";
    pub const SPECIAL_PROPERTY: &str = "core:special_property";
    pub const EXTENSION_PROPERTY: &str = "core:extension_property";
    pub const CHANCE: &str = "core:chance";
    pub const CARD_SHOP: &str = "core:card_shop";
    pub const LOTTERY: &str = "core:lottery";
    pub const BANK: &str = "core:bank";
    pub const JAIL: &str = "core:jail";
    pub const HOSPITAL: &str = "core:hospital";
    pub const GO_TO_JAIL: &str = "core:go_to_jail";
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tile {
    pub id: TileId,
    pub name_key: String,
    pub kind: TileTypeId,  // ← 从枚举改为字符串
    pub linked_property_kind: Option<PropertyKind>,
}
```

### 5.2 格子行为处理器注册表

```rust
// crates/application/src/tile_behavior.rs (新)
use sa_monopoly_domain::{GameState, TileTypeId};
use crate::event_bus::EventBus;

/// 玩家落在格子上时触发的行为
pub type TileBehavior = Box<
    dyn Fn(&mut GameState, &str, &mut dyn RngService, &mut EventBus) + Send + Sync
>;

/// 格子行为注册表
pub struct TileBehaviorRegistry {
    behaviors: HashMap<TileTypeId, (TileBehavior, String)>, // (behavior, plugin_id)
}

impl TileBehaviorRegistry {
    pub fn new() -> Self { Self { behaviors: HashMap::new() } }

    pub fn register(
        &mut self,
        tile_type: &str,
        plugin_id: &str,
        behavior: TileBehavior,
    ) -> Result<(), String> { /* ... */ }

    pub fn unregister_plugin(&mut self, plugin_id: &str) { /* ... */ }

    pub fn execute(
        &self,
        tile_type: &str,
        state: &mut GameState,
        tile_id: &str,
        rng: &mut dyn RngService,
        bus: &mut EventBus,
    ) -> bool {
        if let Some((behavior, _)) = self.behaviors.get(tile_type) {
            behavior(state, tile_id, rng, bus);
            true
        } else {
            false
        }
    }
}
```

### 5.3 核心格子行为注册

```rust
// 在引擎初始化时注册核心行为
fn register_core_tile_behaviors(registry: &mut TileBehaviorRegistry) {
    registry.register(tile_types::START, "core", Box::new(|state, _tile_id, _rng, bus| {
        bus.publish_typed(&core_events::LandedOnStart { player_id: state.active_player().unwrap().id.clone() }, state);
    })).unwrap();

    registry.register(tile_types::ORDINARY_PROPERTY, "core", Box::new(|state, tile_id, _rng, bus| {
        // ... 原有的 OrdinaryProperty 逻辑 ...
    })).unwrap();

    // ... 注册其他核心行为 ...
}
```

---

## 6. 新 EventBus 实现

### 6.1 完整 EventBus

```rust
// crates/application/src/event_bus.rs (重写)
pub struct EventBus {
    /// 中间件链
    middlewares: Vec<Box<dyn EventMiddleware>>,
    /// 事件订阅者
    subscribers: Vec<SubscriberEntry>,
    /// 命令处理器
    command_handlers: CommandHandlerRegistry,
    /// 格子行为处理器
    tile_behaviors: TileBehaviorRegistry,
    /// 是否已排序
    sorted: bool,
    /// 本轮收集的自定义事件（供 BridgeResponse 使用）
    custom_events: Vec<AnyEvent>,
}

impl EventBus {
    pub fn new() -> Self { /* ... */ }

    // ─── 核心游戏循环入口 ───

    /// 处理一个命令事件（代替旧的 GameEngine::execute）
    pub fn execute_command(
        &mut self,
        command: AnyEvent,
        state: &mut GameState,
        rng: &mut dyn RngService,
    ) {
        let command_type = command.event_type().to_string();
        let dispatched = self.command_handlers.dispatch(
            &command_type, state, command, rng, self,
        );
        if !dispatched {
            self.publish_error(&format!("unknown command: {command_type}"), state);
        }
    }

    /// 玩家落在格子上时调用（代替旧的 EffectResolver）
    pub fn resolve_tile(
        &mut self,
        tile_type: &str,
        state: &mut GameState,
        tile_id: &str,
        rng: &mut dyn RngService,
    ) {
        let executed = self.tile_behaviors.execute(tile_type, state, tile_id, rng, self);
        if !executed {
            log::warn!("No behavior registered for tile type: {tile_type}");
        }
    }

    // ─── 事件发布 ───

    pub fn publish_typed<E: GameEvent + Serialize>(&mut self, event: &E, state: &GameState) {
        let any_event = AnyEvent::from_typed(event).unwrap();
        self.publish_any(any_event, state);
    }

    pub fn publish_custom(&mut self, event_type: &str, source: &str,
                          payload: serde_json::Value, state: &GameState) {
        let event = AnyEvent::Custom {
            event_type: event_type.to_string(),
            source: source.to_string(),
            payload,
            timestamp: timestamp_now(),
        };
        self.publish_any(event, state);
    }

    pub fn publish_error(&mut self, reason: &str, state: &GameState) {
        self.publish_custom("core:error", "core",
            serde_json::json!({ "reason": reason }), state);
    }

    fn publish_any(&mut self, event: AnyEvent, state: &GameState) {
        // 1. 中间件链
        let mut event = Some(event);
        for m in &mut self.middlewares {
            if let Some(e) = event.take() { event = m.process(e); }
            else { return; }
        }
        let Some(event) = event else { return };

        // 2. 收集自定义事件
        if matches!(&event, AnyEvent::Custom { .. }) {
            self.custom_events.push(event.clone());
        }

        // 3. 排序订阅者
        if !self.sorted {
            self.subscribers.sort_by_key(|e| (e.priority, e.registered_at));
            self.sorted = true;
        }

        // 4. 分发
        for entry in &mut self.subscribers {
            let types = entry.subscriber.interested_types();
            if !types.is_empty() && !types.contains(&event.event_type()) {
                continue;
            }
            match entry.subscriber.on_event(&event, state) {
                EventAction::Continue => {}
                EventAction::Consume => break,
                EventAction::Modify(_) => break,
            }
        }
    }

    /// 收集并清空本轮的自定义事件
    pub fn drain_custom_events(&mut self) -> Vec<AnyEvent> {
        std::mem::take(&mut self.custom_events)
    }
}
```

---

## 7. 引擎初始化

```rust
// crates/application/src/startup.rs (重写)
use crate::event_bus::EventBus;
use crate::command_handler::CommandHandlerRegistry;
use crate::tile_behavior::TileBehaviorRegistry;

/// 构建一个完全初始化的 EventBus，包含所有核心行为
pub fn build_core_engine() -> EventBus {
    let mut bus = EventBus::new();

    // 1. 注册核心命令处理器
    register_core_commands(&mut bus.command_handlers);

    // 2. 注册核心格子行为
    register_core_tile_behaviors(&mut bus.tile_behaviors);

    // 3. 注册内置订阅者
    bus.subscribe(Box::new(EventLogger));
    bus.subscribe(Box::new(SchedulerBridge::new(VecScheduler::default())));

    // 4. 添加核心中间件
    bus.add_middleware(Box::new(LoggingMiddleware));

    bus
}

// 然后插件加载时：
pub fn load_plugin(plugin: Box<dyn Plugin>, bus: &mut EventBus) {
    plugin.register_subscribers(bus);
    plugin.register_commands(&mut bus.command_handlers);
    plugin.register_tile_behaviors(&mut bus.tile_behaviors);
    // 插件的命令处理器和格子行为自动集成到 EventBus 中
}
```

---

## 8. 插件示例

```rust
// 一个添加 "传送门" 格子的插件
struct PortalPlugin {
    plugin_id: String,
}

impl Plugin for PortalPlugin {
    fn id(&self) -> &str { &self.plugin_id }

    fn register_tile_behaviors(&mut self, registry: &mut TileBehaviorRegistry) {
        registry.register("my_mod:portal", &self.plugin_id, Box::new(
            |state, tile_id, rng, bus| {
                let player = state.active_player().unwrap();
                let portal = state.board.tile(tile_id).unwrap();
                // 从格子元数据中读取目标
                let target = portal.name_key.clone();
                if let Some(p) = state.active_player_mut() {
                    p.position = target;
                }
                bus.publish_custom("my_mod:teleported", "my_mod",
                    serde_json::json!({
                        "player_id": player.id,
                        "from": tile_id,
                        "to": target,
                    }),
                    state,
                );
            }
        )).unwrap();
    }

    fn register_commands(&mut self, registry: &mut CommandHandlerRegistry) {
        registry.register("my_mod:activate_portal", &self.plugin_id, Box::new(
            |state, event, rng, bus| {
                // 处理自定义命令
                let target = "some_tile";
                if let Some(p) = state.active_player_mut() {
                    p.position = target.to_string();
                }
            }
        )).unwrap();
    }

    fn register_subscribers(&mut self, bus: &mut EventBus) {
        // 监听骰子事件
        struct PortalListener;
        impl EventSubscriber for PortalListener {
            fn id(&self) -> &str { "my_mod:portal_listener" }
            fn interested_types(&self) -> Vec<&'static str> { vec!["core:dice_rolled"] }
            fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction {
                log::info!("[PortalMod] Dice rolled on turn {}", state.current_turn);
                EventAction::Continue
            }
        }
        bus.subscribe(Box::new(PortalListener));
    }
}
```

---

## 9. Bridge 适配

```rust
// crates/application/src/bridge.rs (简化)

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeRequest {
    /// 命令类型（如 "core:command:roll"）
    pub command_type: String,
    /// 命令来源
    pub source: String,
    /// 命令参数
    pub payload: serde_json::Value,
    /// 游戏状态
    pub state: GameState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeResponse {
    /// 此命令产生的所有事件
    pub events: Vec<AnyEvent>,
    /// 命令执行后的游戏状态
    pub state: GameState,
}

impl EngineBridge {
    pub fn execute(
        request: BridgeRequest,
        bus: &mut EventBus,
    ) -> BridgeResponse {
        let mut state = request.state;
        let mut rng = BridgeRng::new(state.seed);

        // 构造命令事件
        let command = AnyEvent::Custom {
            event_type: request.command_type,
            source: request.source,
            payload: request.payload,
            timestamp: 0,
        };

        // 通过 EventBus 执行命令
        bus.execute_command(command, &mut state, &mut rng);

        // 收集所有事件
        let mut events = Vec::new();
        // 核心事件通过 BridgeBroadcaster 收集
        // 自定义事件通过 drain_custom_events
        events.extend(bus.drain_custom_events());

        state.seed = rng.current_state();
        BridgeResponse { events, state }
    }
}
```

---

## 10. 文件变更总清单

| 操作 | 文件 | 说明 |
|------|------|------|
| **删除** | `crates/application/src/engine.rs` | `GameEngine` struct 被 EventBus 替代 |
| **删除** | `crates/application/src/commands.rs` | `GameCommand` 枚举删除 |
| **删除** | `crates/application/src/effects.rs` | `EffectResolver` 被 TileBehaviorRegistry 替代 |
| **删除** | `crates/application/src/special.rs` | `SpecialRulesService` 无存在必要 |
| **删除** | `crates/application/src/events.rs` | `GameEvent` 枚举删除 |
| **重写** | `crates/application/src/event_bus.rs` | 新的完全体 EventBus |
| **重写** | `crates/application/src/bridge.rs` | 适配 AnyEvent 驱动的 Bridge |
| **重写** | `crates/application/src/startup.rs` | 引擎初始化流程 |
| **重写** | `crates/domain/src/tile.rs` | `TileKind` 枚举 → `TileTypeId` 字符串 |
| **重写** | `crates/application/src/turn_processor.rs` | 适配新的 EventBus API |
| **新增** | `crates/domain/src/event.rs` | `GameEvent` trait |
| **新增** | `crates/domain/src/events/core_events.rs` | 所有核心事件的结构体定义 |
| **新增** | `crates/application/src/command_handler.rs` | `CommandHandlerRegistry` |
| **新增** | `crates/application/src/tile_behavior.rs` | `TileBehaviorRegistry` |
| **新增** | `crates/application/src/builtin/commands.rs` | 核心命令处理器实现 |
| **新增** | `crates/application/src/builtin/tiles.rs` | 核心格子行为实现 |
| **修改** | `crates/infra/src/plugins.rs` | 适配新的注册表系统 |
| **修改** | `crates/application/src/subscribers.rs` | 适配 AnyEvent |
| **修改** | `crates/domain/src/lib.rs` | 导出新类型 |
| **修改** | `crates/application/src/lib.rs` | 更新模块声明 |

### 代码量变化

| 指标 | 旧 | 新 | 变化 |
|------|----|----|------|
| `GameEngine::execute()` | ~850 行 match | 分散到 ~20 个独立处理器 | 更可维护 |
| `GameEvent` 枚举 | 60 行 | 0 | 删除 |
| `GameCommand` 枚举 | 42 行 | 0 | 删除 |
| `TileKind` 枚举 | 28 行 | 0 | 删除 |
| 总新增代码 | — | ~1200 行 | 新架构 |

---

## 11. 插件能力清单

改造后，插件可以：

| 能力 | 通过什么 API | 示例 |
|------|-------------|------|
| **监听事件** | `EventSubscriber` + `bus.subscribe()` | 监听骰子结果、回合变更 |
| **发布事件** | `bus.publish_custom()` | 通知 UI 显示自定义动画 |
| **注册命令** | `CommandHandlerRegistry::register()` | 添加 "/votekick" 命令 |
| **注册格子** | `TileBehaviorRegistry::register()` | 添加 "传送门" 格子 |
| **注入中间件** | `bus.add_middleware()` | 添加自定义过滤规则 |
| **修改状态** | 命令/格子处理器的 `&mut GameState` | 完全访问状态 |
| **UI 通信** | `AnyEvent::Custom` → `BridgeResponse` | 向 Flutter 发送自定义消息 |
| **脚本化规则** | `ScriptEventSubscriber` | 用 JS/WASM 编写规则 |

插件注册的自定义命令和格子与核心的内置命令**完全平等**，都在同一个 EventBus 上以相同的机制运行。
