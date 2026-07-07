# EventBus 模组化改造 — 完整设计方案

## 0. 设计目标

让 EventBus 成为**模组的核心通信中枢**，模组可以：

1. **监听事件** — 对特定事件作出反应
2. **发布事件** — 注入自定义事件到游戏循环
3. **注册命令** — 添加自定义可执行命令
4. **注册格子类型** — 添加自定义格子行为
5. **注册效果处理器** — 扩展格子效果逻辑
6. **通过脚本定义规则** — Lua/JS/WASM 编写游戏逻辑
7. **与 UI 通信** — 自定义事件传递到 Flutter 前端

---

## 1. 整体架构

```
┌──────────────────────────────────────────────────────────────────┐
│                        GameEngine                               │
│  ┌────────────┐   ┌──────────────┐   ┌──────────────────────┐   │
│  │ Core       │   │ Dynamic      │   │ Custom Command       │   │
│  │ Commands   │──►│ Command      │──►│ Handlers (Plugin)    │   │
│  │ (built-in) │   │ Dispatcher   │   │                      │   │
│  └────────────┘   └──────────────┘   └──────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
                           │
                    publish event
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│                        EventBus                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Middleware Chain                                         │   │
│  │  [PermissionCheck] → [Logging] → [Transform] → [Filter]  │   │
│  └──────────────────────────┬───────────────────────────────┘   │
│                             ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Subscriber Table (priority-ordered)                     │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │   │
│  │  │Scheduler │ │Bridge    │ │Plugins  │ │Network  │   │   │
│  │  │Bridge    │ │Broadcast │ │(WASM/JS)│ │Sync     │   │   │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘   │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
                           │
                    custom event
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│                     Flutter Frontend                             │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  EventRenderer: Core(GameEvent) → native widgets         │   │
│  │  EventRenderer: Custom{event_type} → plugin-provided UI  │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. 核心类型扩展

### 2.1 `GameCommand` — 开放自定义命令

```rust
// crates/application/src/commands.rs
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum GameCommand {
    // ... 现有变体保持不变 ...
    Roll,
    BuyProperty { tile_id: String },
    UpgradeProperty { tile_id: String },
    PayRent { tile_id: String },
    EndTurn,
    BuyCard { card_id: String, price: i64 },
    Trade { /* ... */ },
    Auction { tile_id: String, starting_bid: i64 },
    Bid { player_id: String, amount: i64 },
    Mortgage { tile_id: String },
    Redeem { tile_id: String },
    SellShares { player_id: String, shares: u32 },
    ConfigGet,
    ConfigSet { section: String, value: serde_json::Value },
    BuyLotteryTicket { number: u32 },
    UseCard { card_id: String },
    PayBail,

    // ── 新增：模组自定义命令 ──
    Custom {
        command_type: String,
        plugin_id: String,
        payload: serde_json::Value,
    },
}
```

### 2.2 `TileKind` — 开放自定义格子类型

```rust
// crates/domain/src/tile.rs
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TileKind {
    // ... 现有变体 ...
    Start,
    OrdinaryProperty,
    SpecialProperty(SpecialTileKind),
    ExtensionProperty,
    Chance,
    CardShop,
    Lottery,
    Bank,
    Jail,
    Hospital,

    // ── 新增：模组自定义格子类型 ──
    Custom(String),  // "my_mod:magic_portal"
}
```

### 2.3 `BridgeResponse` — 支持自定义事件传递

```rust
// crates/application/src/bridge.rs
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeResponse {
    pub event: GameEvent,
    pub state: GameState,
    // ── 新增：同时携带 AnyEvent 信息供 Flutter 侧处理自定义事件 ──
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_events: Option<Vec<AnyEvent>>,
}
```

---

## 3. 新模块：命令处理器注册表

### 3.1 `CommandHandler` trait

```rust
// crates/application/src/command_registry.rs (新文件)
use sa_monopoly_domain::GameState;
use crate::commands::GameCommand;
use crate::events::GameEvent;
use crate::ports::RngService;

/// 命令处理器签名：接收当前状态和 RNG，返回事件
pub type CommandFn = Box<
    dyn FnMut(&mut GameState, &mut dyn RngService, serde_json::Value) -> GameEvent
        + Send + Sync
>;

/// 命令处理器注册表
pub struct CommandRegistry {
    /// 命令类型 → 处理器映射
    handlers: HashMap<String, CommandFn>,
    /// 来源插件 ID → 注册的命令列表 (用于清理)
    plugin_commands: HashMap<String, Vec<String>>,
}

impl CommandRegistry {
    pub fn new() -> Self { /* ... */ }

    /// 注册一个自定义命令处理器
    pub fn register(
        &mut self,
        command_type: &str,
        plugin_id: &str,
        handler: CommandFn,
    ) -> Result<(), String> {
        if self.handlers.contains_key(command_type) {
            return Err(format!("command '{command_type}' already registered"));
        }
        self.handlers.insert(command_type.to_string(), handler);
        self.plugin_commands
            .entry(plugin_id.to_string())
            .or_default()
            .push(command_type.to_string());
        Ok(())
    }

    /// 注销某个插件的所有命令
    pub fn unregister_plugin(&mut self, plugin_id: &str) {
        if let Some(commands) = self.plugin_commands.remove(plugin_id) {
            for cmd in commands {
                self.handlers.remove(&cmd);
            }
        }
    }

    /// 分发自定义命令
    pub fn dispatch(
        &mut self,
        command_type: &str,
        state: &mut GameState,
        rng: &mut dyn RngService,
        payload: serde_json::Value,
    ) -> Option<GameEvent> {
        self.handlers.get_mut(command_type).map(|handler| {
            handler(state, rng, payload)
        })
    }
}
```

### 3.2 `GameEngine::execute()` 中新增自定义命令分支

```rust
// crates/application/src/engine.rs
use crate::command_registry::CommandRegistry;

pub struct GameEngine {
    /// 自定义命令处理器注册表
    pub command_registry: CommandRegistry,
}

impl GameEngine {
    pub fn new() -> Self {
        Self {
            command_registry: CommandRegistry::new(),
        }
    }

    pub fn execute(
        &mut self,  // 改为 &mut self
        command: GameCommand,
        state: &mut GameState,
        rng: &mut dyn RngService,
    ) -> GameEvent {
        // ... 现有 match 逻辑 ...
        // 在 match 末尾添加：
        GameCommand::Custom { command_type, plugin_id: _, payload } => {
            match self.command_registry.dispatch(&command_type, state, rng, payload) {
                Some(event) => event,
                None => GameEvent::CommandRejected {
                    reason: format!("unknown custom command: {command_type}"),
                },
            }
        }
    }
}
```

---

## 4. 新模块：格子效果处理器注册表

### 4.1 `TileEffectHandler` trait

```rust
// crates/application/src/effect_registry.rs (新文件)
use sa_monopoly_domain::GameState;
use crate::events::GameEvent;
use crate::ports::RngService;

/// 格子效果处理器：当玩家落在自定义格子上时调用
pub type TileEffectFn = Box<
    dyn Fn(&mut GameState, &str, &mut dyn RngService) -> Option<GameEvent>
        + Send + Sync
>;

/// 格子效果处理器注册表
pub struct EffectRegistry {
    /// 格子类型 (Custom 的 String 值) → 处理器
    handlers: HashMap<String, TileEffectFn>,
    /// 来源插件 ID → 注册的格子类型列表
    plugin_effects: HashMap<String, Vec<String>>,
}

impl EffectRegistry {
    pub fn new() -> Self { /* ... */ }

    /// 注册一个自定义格子效果处理器
    pub fn register_tile_effect(
        &mut self,
        tile_kind: &str,       // "my_mod:magic_portal"
        plugin_id: &str,
        handler: TileEffectFn,
    ) -> Result<(), String> {
        // ...
    }

    /// 注销某个插件的所有格子效果
    pub fn unregister_plugin(&mut self, plugin_id: &str) { /* ... */ }

    /// 分发格子效果
    pub fn resolve(
        &self,
        tile_kind: &str,
        state: &mut GameState,
        tile_id: &str,
        rng: &mut dyn RngService,
    ) -> Option<GameEvent> {
        self.handlers.get(tile_kind).map(|handler| {
            handler(state, tile_id, rng)
        })?
    }
}
```

### 4.2 `EffectResolver` 中新增自定义格子分支

```rust
// crates/application/src/effects.rs
impl EffectResolver {
    pub fn resolve_special_tile(
        state: &mut GameState,
        tile_id: &str,
        rng: &mut dyn RngService,
        effect_registry: &EffectRegistry,  // 新增参数
    ) -> Option<GameEvent> {
        let tile = state.board.tile(tile_id)?;
        match &tile.kind {
            // ... 现有 match 分支 ...
            sa_monopoly_domain::TileKind::ExtensionProperty => None,

            // ── 新增：自定义格子类型 ──
            sa_monopoly_domain::TileKind::Custom(kind_name) => {
                effect_registry.resolve(kind_name, state, tile_id, rng)
            }
        }
    }
}
```

---

## 5. 新模块：事件订阅脚本支持

### 5.1 `ScriptEventSubscriber`

```rust
// crates/application/src/script_subscriber.rs (新文件)
use crate::event_bus::{AnyEvent, EventAction, EventSubscriber, SubscriberPriority};
use sa_monopoly_domain::GameState;
use crate::scripting::ScriptRuntime;

/// 用脚本实现的 EventSubscriber
///
/// 插件注册时可以提供一段脚本代码，当匹配的事件发生时执行。
/// 脚本可以：
///   - 读取事件 payload（通过 `${event_type}`, `${source}` 等变量）
///   - 读取 GameState 快照（通过 `${player_count}`, `${turn}` 等变量）
///   - 返回 action（"continue", "consume"）
pub struct ScriptEventSubscriber {
    id: String,
    script: String,
    runtime: ScriptRuntime,
    /// 感兴趣的 event_type 列表（空 = 全部）
    interested: Vec<String>,
    priority: SubscriberPriority,
}
```

### 5.2 WASM 运行时集成

```rust
// crates/infra/src/scripting.rs (扩展)
// 使用 wasmtime 实现 WasmScriptHost

#[cfg(feature = "wasm")]
pub struct WasmRuntime {
    engine: wasmtime::Engine,
    store: wasmtime::Store<()>,
}

#[cfg(feature = "wasm")]
impl ScriptHost for WasmRuntime {
    fn run(&self, _kind: ScriptEngineKind, source: &str) -> Result<(), String> {
        // 1. 编译 WASM 模块
        let module = wasmtime::Module::new(&self.engine, source)
            .map_err(|e| e.to_string())?;
        // 2. 创建实例（注入宿主函数）
        let instance = wasmtime::Instance::new(&mut self.store, &module, &[])
            .map_err(|e| e.to_string())?;
        // 3. 调用导出的 "on_event" 函数
        if let Ok(func) = instance.get_typed_func::<(), ()>(&mut self.store, "on_event") {
            func.call(&mut self.store, ()).map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}
```

---

## 6. EventBus 增强

### 6.1 新增：可观察的订阅者生命周期

```rust
// crates/application/src/event_bus.rs (扩展)

impl EventBus {
    /// 获取当前订阅者列表（用于调试/UI）
    pub fn list_subscribers(&self) -> Vec<SubscriberInfo> {
        self.sync_subscribers.iter()
            .map(|e| SubscriberInfo {
                id: e.subscriber.id().to_string(),
                priority: e.priority,
                is_async: false,
            })
            .chain(self.async_subscribers.iter().map(|e| {
                // 注意：异步订阅者的 id 需要 try_lock
                SubscriberInfo {
                    id: e.subscriber.try_lock()
                        .map(|g| g.id().to_string())
                        .unwrap_or_else(|_| "<locked>".to_string()),
                    priority: e.priority,
                    is_async: true,
                }
            }))
            .collect()
    }

    /// 按来源过滤的批量注销（插件卸载时调用）
    pub fn unregister_plugin(&mut self, plugin_id: &str) {
        let prefix = format!("plugin:{plugin_id}");
        self.sync_subscribers.retain(|e| !e.subscriber.id().starts_with(&prefix));
        self.async_subscribers.retain(|e| {
            e.subscriber.try_lock()
                .map(|guard| !guard.id().starts_with(&prefix))
                .unwrap_or(true)
        });
        self.sorted = false;
    }

    /// 清除所有中间件和订阅者（用于热重置）
    pub fn clear(&mut self) {
        self.middlewares.clear();
        self.sync_subscribers.clear();
        self.async_subscribers.clear();
        self.sorted = false;
    }
}

#[derive(Debug, Clone)]
pub struct SubscriberInfo {
    pub id: String,
    pub priority: SubscriberPriority,
    pub is_async: bool,
}
```

### 6.2 新增：权限校验中间件

```rust
// crates/application/src/event_bus.rs (扩展)

/// 权限校验中间件：检查事件来源是否有权限发布该类型的事件
pub struct PermissionMiddleware {
    /// 插件 ID → 允许发布的事件类型前缀
    plugin_permissions: HashMap<String, HashSet<String>>,
}

impl EventMiddleware for PermissionMiddleware {
    fn id(&self) -> &str { "core.permission" }

    fn process(&mut self, event: AnyEvent) -> Option<AnyEvent> {
        match &event {
            AnyEvent::Core(_) => Some(event), // 核心事件始终允许
            AnyEvent::Custom { source, event_type, .. } => {
                let allowed = self.plugin_permissions.get(source.as_str());
                match allowed {
                    Some(types) if types.is_empty() || types.contains(event_type) => {
                        Some(event) // 允许
                    }
                    _ => {
                        log::warn!("[Permission] Plugin '{source}' not allowed to publish '{event_type}'");
                        None // 丢弃
                    }
                }
            }
        }
    }
}
```

---

## 7. Bridge / Flutter 集成

### 7.1 Rust 侧：扩展 BridgeResponse

```rust
// crates/application/src/bridge.rs
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeResponse {
    pub event: GameEvent,
    pub state: GameState,
    /// 本轮产生的自定义事件列表
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub custom_events: Vec<AnyEvent>,
}

impl EngineBridge {
    pub fn execute_with_bus(
        request: BridgeRequest,
        bus: &mut EventBus,
    ) -> BridgeResponse {
        let mut state = request.state;
        let mut rng = BridgeRng::new(state.seed);
        let event = GameEngine::execute(request.command, &mut state, &mut rng);
        state.seed = rng.current_state();
        bus.publish(event.clone(), &state);
        // 从 EventBus 收集轮次内产生的自定义事件
        let custom_events = bus.drain_custom_events();
        BridgeResponse { event, state, custom_events }
    }
}
```

### 7.2 Flutter 侧：自定义事件渲染

```dart
// flutter/lib/bridge_client.dart (扩展)

class BridgeResponse {
  final GameEvent event;
  final GameState state;
  final List<AnyEvent>? customEvents;
}

class AnyEvent {
  final String eventType; // "core" 或 "my_mod:custom_event"
  final String source;    // 来源插件 ID
  final Map<String, dynamic>? payload;
  final int timestamp;
}

// Flutter 侧事件渲染器注册表
class EventRendererRegistry {
  static final Map<String, Widget Function(AnyEvent, GameState)> _renderers = {};

  static void register(String eventType, Widget Function(AnyEvent, GameState) builder) {
    _renderers[eventType] = builder;
  }

  static Widget? render(AnyEvent event, GameState state) {
    final builder = _renderers[event.eventType];
    return builder?.call(event, state);
  }
}

// 模组在初始化时注册自己的渲染器
void main() {
  // ... 加载模组 ...
  EventRendererRegistry.register("my_mod:magic_event", (event, state) {
    return Text("Magic happened: ${event.payload}");
  });
}
```

---

## 8. Plugin trait 扩展

```rust
// crates/infra/src/plugins.rs (扩展)

pub trait Plugin: Send + Sync {
    // ... 现有方法 ...

    /// 注册自定义命令处理器
    fn register_commands(&mut self, _registry: &mut CommandRegistry) {
        // 默认不注册
    }

    /// 注册自定义格子效果处理器
    fn register_tile_effects(&mut self, _registry: &mut EffectRegistry) {
        // 默认不注册
    }

    /// 获取插件的脚本源代码（用于脚本化插件）
    fn script_source(&self) -> Option<(&str, ScriptEngineKind)> {
        None // 默认不是脚本插件
    }

    /// 插件提供的 Flutter UI 组件注册信息
    fn ui_components(&self) -> Vec<UIComponent> {
        Vec::new()
    }
}

/// UI 组件描述：模组告诉引擎它需要哪些 UI 扩展
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UIComponent {
    /// 事件类型前缀，用于匹配需要渲染的自定义事件
    pub event_type: String,
    /// Flutter 侧组件 ID
    pub component_id: String,
    /// 是否需要全屏渲染
    pub fullscreen: bool,
}
```

---

## 9. PluginRegistry 集成

```rust
// crates/infra/src/plugins.rs (扩展)

#[derive(Default)]
pub struct InMemoryPluginRegistry {
    plugins: HashMap<String, PluginEntry>,
    pub event_bus: EventBus,
    pub command_registry: CommandRegistry,      // 新增
    pub effect_registry: EffectRegistry,         // 新增
}

impl PluginRegistry for InMemoryPluginRegistry {
    fn register(&mut self, plugin: Box<dyn Plugin>) -> Result<(), PluginError> {
        let id = plugin.id().to_string();
        if self.plugins.contains_key(&id) {
            return Err(PluginError::AlreadyRegistered(id));
        }

        let mut p = plugin;
        p.init().map_err(PluginError::InitFailed)?;

        // 1. 注册事件订阅者
        p.register_subscribers(&mut self.event_bus);

        // 2. 注册自定义命令
        p.register_commands(&mut self.command_registry);

        // 3. 注册自定义格子效果
        p.register_tile_effects(&mut self.effect_registry);

        // 4. 注册脚本化订阅者
        if let Some((source, kind)) = p.script_source() {
            let subscriber = ScriptEventSubscriber::new(&id, source, kind);
            self.event_bus.subscribe(Box::new(subscriber));
        }

        // 5. 添加权限中间件条目
        // ...

        self.plugins.insert(id, PluginEntry {
            plugin: p,
            enabled: true,
        });
        Ok(())
    }

    fn unregister(&mut self, id: &str) -> Result<Box<dyn Plugin>, PluginError> {
        // 清理该插件的所有注册
        self.event_bus.unregister_plugin(id);
        self.command_registry.unregister_plugin(id);
        self.effect_registry.unregister_plugin(id);
        // ...
    }
}
```

---

## 10. 完整数据流

```
用户操作 / AI 决策
       │
       ▼
GameCommand (含 Custom { command_type, payload })
       │
       ▼
GameEngine::execute()
       │
       ├─ 核心命令 → 内置逻辑 → GameEvent
       │
       └─ Custom     → CommandRegistry::dispatch()
                           │
                           ├─ 找到处理器 → 执行 → GameEvent
                           │
                           └─ 未找到 → CommandRejected
                               │
                               ▼
                          EventBus.publish(event, state)
                               │
                    ┌──────────┼──────────┐
                    ▼          ▼          ▼
              Middleware   Sync Subs  Async Subs
              (权限/日志)   (Bridge/   (Network)
                            Scheduler)
                    │          │
                    ▼          ▼
              BridgeResponse { event, state, custom_events }
                    │
                    ▼
              JSON → Flutter
                    │
                    ├─ Core GameEvent → 原生组件渲染
                    │
                    └─ Custom AnyEvent → EventRendererRegistry
                            │
                            ▼
                      模组提供的 Widget
```

---

## 11. 分阶段实施计划

### Phase 1: 命令扩展（~2 天）

| 步骤 | 文件 | 变更 |
|------|------|------|
| 1 | [`commands.rs`](crates/application/src/commands.rs) | 添加 `GameCommand::Custom` 变体 |
| 2 | **新文件**: `command_registry.rs` | `CommandRegistry`, `CommandFn` |
| 3 | [`engine.rs`](crates/application/src/engine.rs) | `GameEngine` 改为 struct，持有 `CommandRegistry`，处理 `Custom` 分支 |
| 4 | [`bridge.rs`](crates/application/src/bridge.rs) | 更新 `BridgeRng`/`EngineBridge` 适配新的 `GameEngine` 签名 |
| 5 | [`turn_processor.rs`](crates/application/src/turn_processor.rs) | 适配新的 `GameEngine` 签名 |

### Phase 2: 格子效果扩展（~1 天）

| 步骤 | 文件 | 变更 |
|------|------|------|
| 1 | [`tile.rs`](crates/domain/src/tile.rs) | 添加 `TileKind::Custom(String)` |
| 2 | **新文件**: `effect_registry.rs` | `EffectRegistry`, `TileEffectFn` |
| 3 | [`effects.rs`](crates/application/src/effects.rs) | `resolve_special_tile` 接受注册表参数，处理 `Custom` 分支 |
| 4 | [`engine.rs`](crates/application/src/engine.rs) | 传递 `EffectRegistry` 到 `EffectResolver` |

### Phase 3: 插件集成（~1 天）

| 步骤 | 文件 | 变更 |
|------|------|------|
| 1 | [`plugins.rs`](crates/infra/src/plugins.rs) | `Plugin` trait 添加 `register_commands()`, `register_tile_effects()`, `script_source()`, `ui_components()` |
| 2 | [`plugins.rs`](crates/infra/src/plugins.rs) | `InMemoryPluginRegistry` 持有 `CommandRegistry` + `EffectRegistry` |
| 3 | [`plugins.rs`](crates/infra/src/plugins.rs) | `register()` 流程注册命令+效果；`unregister()` 清理 |

### Phase 4: 脚本支持（~2 天）

| 步骤 | 文件 | 变更 |
|------|------|------|
| 1 | **新文件**: `script_subscriber.rs` | `ScriptEventSubscriber` — 用脚本代码实现 `EventSubscriber` |
| 2 | [`scripting.rs`](crates/infra/src/scripting.rs) | 扩展 `ScriptHost` trait 支持事件上下文参数 |
| 3 | [`scripting.rs`](crates/infra/src/scripting.rs) | `WasmScriptHost` 使用 `wasmtime` 运行时（feature gate） |

### Phase 5: Flutter 集成（~1 天）

| 步骤 | 文件 | 变更 |
|------|------|------|
| 1 | [`bridge.rs`](crates/application/src/bridge.rs) | `BridgeResponse` 添加 `custom_events: Vec<AnyEvent>` |
| 2 | `flutter/lib/bridge_client.dart` | 解析 `custom_events`，路由到 `EventRendererRegistry` |
| 3 | `flutter/lib/*.dart` | 新增 `EventRendererRegistry` 注册机制 |

### Phase 6: 权限执行（~0.5 天）

| 步骤 | 文件 | 变更 |
|------|------|------|
| 1 | [`event_bus.rs`](crates/application/src/event_bus.rs) | 实现 `PermissionMiddleware` |
| 2 | [`plugins.rs`](crates/infra/src/plugins.rs) | `register()` 时根据 `PermissionSet` 配置 `PermissionMiddleware` |
| 3 | 各处 | 添加运行时权限检查（`WriteState` 检查等） |

---

## 12. 向后兼容

| 旧接口 | 新接口 | 兼容性 |
|--------|--------|--------|
| `GameEngine::execute(cmd, state, rng)` | `GameEngine::new().execute(cmd, state, rng)` | 保持同签名，`GameEngine` 从 struct 变为 struct |
| `EffectResolver::resolve_special_tile(state, tile_id, rng)` | 添加 `effect_registry` 参数 | 默认参数或重载 |
| `Plugin` trait | 新增方法有默认实现 | ✅ 零破坏 |
| `BridgeResponse { event, state }` | 添加 `custom_events` 字段 | `#[serde(default)]` + `skip_serializing_if` |

---

## 13. 文件变更总览

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `crates/domain/src/tile.rs` | 修改 | `TileKind::Custom(String)` |
| `crates/application/src/commands.rs` | 修改 | `GameCommand::Custom{...}` |
| `crates/application/src/engine.rs` | 重写 | `GameEngine` 改为 struct，添加命令注册表 |
| `crates/application/src/effects.rs` | 修改 | 添加 `EffectRegistry` 参数 |
| `crates/application/src/bridge.rs` | 修改 | `BridgeResponse.custom_events` |
| `crates/application/src/event_bus.rs` | 扩展 | `PermissionMiddleware`, `unregister_plugin()`, `list_subscribers()` |
| `crates/application/src/command_registry.rs` | **新增** | `CommandRegistry` |
| `crates/application/src/effect_registry.rs` | **新增** | `EffectRegistry` |
| `crates/application/src/script_subscriber.rs` | **新增** | `ScriptEventSubscriber` |
| `crates/infra/src/plugins.rs` | 扩展 | `Plugin` 新增方法, `InMemoryPluginRegistry` 集成 |
| `crates/infra/src/scripting.rs` | 扩展 | WASM 运行时, `ScriptHost` 增强 |
| `flutter/lib/bridge_client.dart` | 扩展 | 自定义事件解析 |
| `flutter/lib/event_renderer.dart` | **新增** | `EventRendererRegistry` |
