# Event Bus 针对性分析与改造方案

## 1. 当前实现诊断

### 1.1 现状总结

经过全面代码审查，发现当前 Event Bus 相关代码存在**严重断层**：

| 组件 | 位置 | 状态 |
|------|------|------|
| [`EventBus<E>` trait](crates/application/src/events.rs:62) | `crates/application/src/events.rs` | **死代码** — 从未被任何模块导入或使用 |
| [`VecEventBus<E>`](crates/application/src/events.rs:67) | `crates/application/src/events.rs` | **死代码** — 从未被实例化或引用 |
| [`EventSink<E>` trait](crates/application/src/ports.rs:5) | `crates/application/src/ports.rs` | **死代码** — 从未被任何模块使用 |

### 1.2 实际事件流

系统实际通过**直接返回值**传递事件，而非通过总线：

```
┌──────────────┐    GameEvent (single)    ┌──────────────┐
│ GameEngine   │ ───────────────────────► │ BridgeResponse│
│ ::execute()  │                          │ {event,state}│
└──────────────┘                          └──────┬───────┘
                                                 │
                                         ┌──────▼───────┐
                                         │  JSON serial │──► Flutter
                                         │  + broadcast │──► Network peers
                                         └──────────────┘
```

多个事件通过 [`TurnProcessor::process_turn()`](crates/application/src/turn_processor.rs:44) 手动收集：

```rust
let mut events = Vec::new();
let roll_event = GameEngine::execute(GameCommand::Roll, state, rng);
events.push(roll_event);
// ...
let buy_event = GameEngine::execute(GameCommand::BuyProperty{..}, state, rng);
events.push(buy_event);
// ...
```

### 1.3 核心缺陷

1. **无订阅/发布模型** — 没有任何组件可以订阅事件流
2. **插件无事件钩子** — [`Plugin`](crates/infra/src/plugins.rs:178) trait 没有 `on_event()` 方法
3. **无事件过滤/转换** — 没有中间件管道
4. **单事件返回值** — `GameEngine::execute()` 只能返回一个事件，无法产生复合事件序列
5. **全局广播器侵入式设计** — [`BROADCASTER`](crates/application/src/bridge.rs:59) 使用 `OnceLock<Box<dyn Fn>>`，不够灵活

---

## 2. 改造目标

### 2.1 原则

| 原则 | 说明 |
|------|------|
| **渐进式迁移** | 现有代码不破坏，逐步替换返回值模式 |
| **零成本抽象** | 无订阅者时事件传递零开销 |
| **类型安全** | 核心事件仍用 Rust 枚举，模组事件用 `serde_json::Value` 兜底 |
| **插件优先** | 事件总线是插件系统的第一公民 |
| **异步友好** | 支持同步和异步订阅者 |

### 2.2 核心需求

- **多订阅者**：核心引擎、插件、网络层、日志、UI 都能订阅事件
- **事件过滤**：按事件类型、来源、条件过滤
- **事件转换**：中间件可拦截和修改事件
- **自定义事件**：模组可发布和订阅自定义事件
- **优先级**：订阅者可指定优先级顺序
- **生命周期**：订阅者可在运行时注册/注销

---

## 3. 详细改造方案

### 3.1 新 EventBus 架构

```
                  ┌──────────────────────────┐
                  │     EventBus (核心总线)      │
                  │                          │
                  │  ┌────────────────────┐  │
                  │  │  Middleware Chain   │  │
                  │  │  (过滤/转换/日志)    │  │
                  │  └────────┬───────────┘  │
                  │           │               │
                  │  ┌────────▼───────────┐  │
                  │  │  Subscriber Table  │  │
                  │  │  (按优先级排序)     │  │
                  │  └────────┬───────────┘  │
                  └───────────┼──────────────┘
                              │
         ┌────────────────────┼────────────────────┐
         ▼                    ▼                    ▼
   ┌────────────┐    ┌──────────────┐    ┌──────────────┐
   │ Core Engine│    │   Plugins   │    │ Network Sync │
   │ (同步监听)  │    │ (通过trait)  │    │ (异步推送)    │
   └────────────┘    └──────────────┘    └──────────────┘
```

### 3.2 新类型定义

#### 3.2.1 事件包装器（支持自定义事件）

```rust
/// 统一事件包装器，支持核心事件和模组自定义事件
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum AnyEvent {
    /// 核心类型安全事件
    Core(GameEvent),
    /// 模组自定义事件 (event_type 作为标识)
    Custom {
        event_type: String,
        source: String,       // 来源模组 ID
        payload: serde_json::Value,
        timestamp: u64,
    },
}

impl AnyEvent {
    pub fn event_type(&self) -> &str {
        match self {
            AnyEvent::Core(e) => e.event_type_str(),
            AnyEvent::Custom { event_type, .. } => event_type,
        }
    }

    pub fn source(&self) -> &str {
        match self {
            AnyEvent::Core(_) => "core",
            AnyEvent::Custom { source, .. } => source,
        }
    }
}

// 在 GameEvent 上添加类型标签方法
impl GameEvent {
    pub fn event_type_str(&self) -> &'static str {
        match self {
            GameEvent::GameStarted => "game.started",
            GameEvent::CommandAccepted { .. } => "command.accepted",
            // ... 所有变体对应字符串
            GameEvent::BailPaid { .. } => "bail.paid",
        }
    }
}
```

#### 3.2.2 订阅者 trait

```rust
/// 事件订阅优先级
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum SubscriberPriority {
    First = 0,    // 最先收到
    Early = 1,
    Normal = 2,
    Late = 3,
    Last = 4,     // 最后收到（默认）
}

/// 事件处理结果
#[derive(Debug, Clone)]
pub enum EventAction {
    /// 继续传播给下一个订阅者
    Continue,
    /// 消费事件，停止传播
    Consume,
    /// 修改事件后继续传播
    Modify(AnyEvent),
}

/// 事件订阅者 trait
pub trait EventSubscriber: Send + Sync {
    /// 订阅者唯一标识
    fn id(&self) -> &str;

    /// 希望收到的事件类型（返回空 = 所有事件）
    fn interested_types(&self) -> Vec<&'static str> {
        Vec::new() // 默认全部接收
    }

    /// 优先级
    fn priority(&self) -> SubscriberPriority {
        SubscriberPriority::Last
    }

    /// 处理事件
    fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction;
}

/// 异步版本（用于网络层等）
#[async_trait]
pub trait AsyncEventSubscriber: Send + Sync {
    fn id(&self) -> &str;
    fn interested_types(&self) -> Vec<&'static str> { Vec::new() }
    fn priority(&self) -> SubscriberPriority { SubscriberPriority::Last }

    async fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction;
}
```

#### 3.2.3 中间件 trait

```rust
/// 事件中间件 — 在事件传递给订阅者之前执行
pub trait EventMiddleware: Send + Sync {
    fn id(&self) -> &str;

    /// 处理事件，返回 None = 丢弃事件，Some = 继续传递（可能是修改后的）
    fn process(&mut self, event: AnyEvent) -> Option<AnyEvent>;
}

/// 内置中间件示例
pub struct LoggingMiddleware;
impl EventMiddleware for LoggingMiddleware {
    fn id(&self) -> &str { "core.logger" }
    fn process(&mut self, event: AnyEvent) -> Option<AnyEvent> {
        log::info!("[EVENT] {} from {}", event.event_type(), event.source());
        Some(event)
    }
}

pub struct FilterMiddleware {
    allowed_types: HashSet<String>,
}
impl EventMiddleware for FilterMiddleware {
    fn id(&self) -> &str { "filter" }
    fn process(&mut self, event: AnyEvent) -> Option<AnyEvent> {
        if self.allowed_types.contains(event.event_type()) {
            Some(event)
        } else {
            None // 丢弃
        }
    }
}
```

#### 3.2.4 主 EventBus 实现

```rust
pub struct EventBus {
    /// 中间件链（按注册顺序执行）
    middlewares: Vec<Box<dyn EventMiddleware>>,
    /// 同步订阅者（按优先级 + 注册顺序排序）
    sync_subscribers: Vec<SubscriberEntry>,
    /// 异步订阅者
    async_subscribers: Vec<AsyncSubscriberEntry>,
    /// 是否已排序（dirty flag）
    sorted: bool,
}

struct SubscriberEntry {
    subscriber: Box<dyn EventSubscriber>,
    priority: SubscriberPriority,
    registered_at: usize, // 注册序号，用于同优先级内稳定性
}

struct AsyncSubscriberEntry {
    subscriber: Box<dyn AsyncEventSubscriber>,
    priority: SubscriberPriority,
    registered_at: usize,
}

impl EventBus {
    pub fn new() -> Self {
        Self {
            middlewares: Vec::new(),
            sync_subscribers: Vec::new(),
            async_subscribers: Vec::new(),
            sorted: true,
        }
    }

    // ─── 注册 ─────────────────────────────────────────────

    pub fn add_middleware(&mut self, m: Box<dyn EventMiddleware>) {
        self.middlewares.push(m);
    }

    pub fn subscribe(&mut self, sub: Box<dyn EventSubscriber>) {
        let priority = sub.priority();
        self.sync_subscribers.push(SubscriberEntry {
            subscriber: sub,
            priority,
            registered_at: self.sync_subscribers.len(),
        });
        self.sorted = false;
    }

    pub fn subscribe_async(&mut self, sub: Box<dyn AsyncEventSubscriber>) {
        let priority = sub.priority();
        self.async_subscribers.push(AsyncSubscriberEntry {
            subscriber: sub,
            priority,
            registered_at: self.async_subscribers.len(),
        });
        self.sorted = false;
    }

    pub fn unsubscribe(&mut self, id: &str) {
        self.sync_subscribers.retain(|e| e.subscriber.id() != id);
        self.async_subscribers.retain(|e| e.subscriber.id() != id);
    }

    // ─── 发布 ────────────────────────────────────────────

    /// 发布一个核心事件
    pub fn publish(&mut self, event: GameEvent, state: &GameState) {
        self.publish_any(AnyEvent::Core(event), state);
    }

    /// 发布一个自定义事件（供模组使用）
    pub fn publish_custom(&mut self, event_type: &str, source: &str,
                          payload: serde_json::Value, state: &GameState) {
        self.publish_any(AnyEvent::Custom {
            event_type: event_type.to_string(),
            source: source.to_string(),
            payload,
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0),
        }, state);
    }

    /// 内部统一的发布方法
    fn publish_any(&mut self, event: AnyEvent, state: &GameState) {
        // 1. 运行中间件链
        let mut event = event;
        for middleware in &mut self.middlewares {
            match middleware.process(event) {
                Some(e) => event = e,
                None => return, // 事件被丢弃
            }
        }

        // 2. 排序订阅者（如有变更）
        if !self.sorted {
            self.sync_subscribers.sort_by_key(|e| (e.priority, e.registered_at));
            self.async_subscribers.sort_by_key(|e| (e.priority, e.registered_at));
            self.sorted = true;
        }

        // 3. 分发到同步订阅者
        for entry in &mut self.sync_subscribers {
            let should_skip = !entry.subscriber.interested_types().is_empty()
                && !entry.subscriber.interested_types().contains(&event.event_type());

            if should_skip { continue; }

            match entry.subscriber.on_event(&event, state) {
                EventAction::Continue => {},
                EventAction::Consume => return,
                EventAction::Modify(e) => event = e,
            }
        }

        // 4. 分发到异步订阅者（fire-and-forget）
        for entry in &mut self.async_subscribers {
            let should_skip = !entry.subscriber.interested_types().is_empty()
                && !entry.subscriber.interested_types().contains(&event.event_type());

            if should_skip { continue; }

            let event_clone = event.clone();
            let state_clone = state.clone();
            let sub_id = entry.subscriber.id().to_string();
            tokio::spawn(async move {
                // 异步处理
                if let Some(entry_inner) = /* ... need Arc<Mutex<>> ... */ {
                    // 实际实现需要使用 Arc<Mutex<>> 共享总线
                }
            });
        }
    }
}
```

> **注意**：异步分发需要 `Arc<Mutex<EventBus>>` 或独立的通道机制。实际实现时，同步和异步订阅者应分离到不同的总线实例或使用 channel。

### 3.3 与 Plugin 系统集成

```rust
/// 扩展 Plugin trait，添加事件钩子
pub trait Plugin: Send + Sync {
    // ... 现有方法 ...

    /// 可选：插件可以在注册时向总线添加订阅者
    fn register_subscribers(&mut self, bus: &mut EventBus) {
        // 默认不注册
    }
}
```

在 `PluginRegistry::register()` 中自动调用：

```rust
impl PluginRegistry for InMemoryPluginRegistry {
    fn register(&mut self, plugin: Box<dyn Plugin>) -> Result<(), PluginError> {
        let id = plugin.id().to_string();
        // ... 现有逻辑 ...

        // 新：让插件向总线注册订阅者
        plugin.register_subscribers(&mut self.event_bus);
        Ok(())
    }
}
```

### 3.4 集成到 GameEngine

```rust
impl GameEngine {
    /// 新的 execute 签名：接受 EventBus 引用
    pub fn execute_with_bus(
        command: GameCommand,
        state: &mut GameState,
        rng: &mut dyn RngService,
        bus: &mut EventBus,
    ) {
        // ... 执行逻辑不变 ...
        // 但改为通过总线发布事件：
        bus.publish(GameEvent::DiceRolled { ... }, state);
        bus.publish(GameEvent::PlayerMoved { ... }, state);

        // 可选检查总线是否已 consume
    }
}
```

但为了**渐进式迁移**，保留旧的 `execute()` 的同时添加新方法：

```rust
impl GameEngine {
    /// 旧接口：保持向后兼容
    pub fn execute(
        command: GameCommand,
        state: &mut GameState,
        rng: &mut dyn RngService,
    ) -> GameEvent { ... }

    /// 新接口：通过 EventBus 发出事件
    pub fn execute_and_emit(
        command: GameCommand,
        state: &mut GameState,
        rng: &mut dyn RngService,
        bus: &mut EventBus,
    ) {
        // 核心执行逻辑复用
        let event = Self::execute(command, state, rng);
        bus.publish(event, state);
    }
}
```

### 3.5 TurnProcessor 使用新总线

```rust
impl TurnProcessor {
    pub fn process_turn_with_bus(
        state: &mut GameState,
        rng: &mut dyn RngService,
        decision_maker: &mut dyn DecisionMaker,
        bus: &mut EventBus,
    ) {
        // Phase 1: Roll
        GameEngine::execute_and_emit(GameCommand::Roll, state, rng, bus);

        // Phase 2: Buy/Upgrade
        if let Some(player) = state.active_player() {
            let tile_id = &player.position;
            if let Some(property) = state.board.property(tile_id) {
                // ... 决策逻辑 ...
                GameEngine::execute_and_emit(GameCommand::BuyProperty{..}, state, rng, bus);
            }
        }

        // Phase 3: End turn
        GameEngine::execute_and_emit(GameCommand::EndTurn, state, rng, bus);
    }
}
```

### 3.6 内置订阅者实现

```rust
// ─── BridgeBroadcaster：将事件发送到 Flutter ──────────────

pub struct BridgeBroadcaster {
    bridge_tx: mpsc::Sender<BridgeResponse>,
}

impl EventSubscriber for BridgeBroadcaster {
    fn id(&self) -> &str { "core.bridge" }

    fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction {
        if let AnyEvent::Core(core_event) = event {
            let response = BridgeResponse {
                event: core_event.clone(),
                state: state.clone(),
            };
            let _ = self.bridge_tx.try_send(response);
        }
        EventAction::Continue // 不消费，其他订阅者也收到
    }
}

// ─── Logger：事件日志 ─────────────────────────────────────

pub struct EventLogger;

impl EventSubscriber for EventLogger {
    fn id(&self) -> &str { "core.logger" }
    fn priority(&self) -> SubscriberPriority { SubscriberPriority::Last }

    fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction {
        log::info!("[TURN {}] {:?} (players: {})",
            state.current_turn, event, state.players.len());
        EventAction::Continue
    }
}

// ─── SchedulerBridge：将事件与调度器关联 ──────────────────

pub struct SchedulerBridge {
    scheduler: VecScheduler,
}

impl EventSubscriber for SchedulerBridge {
    fn id(&self) -> &str { "core.scheduler" }
    fn interested_types(&self) -> Vec<&'static str> {
        vec!["turn.advanced", "turn.ended"]
    }

    fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction {
        if let AnyEvent::Core(GameEvent::TurnAdvanced { turn, .. }) = event {
            let effects = self.scheduler.tick(*turn);
            for effect in effects {
                // 执行调度器效果并发布新事件
                self.execute_effect(effect, state);
            }
        }
        EventAction::Continue
    }
}
```

### 3.7 Plugin 事件注入支持

配合现有的 `Permission::EventInjection` 权限：

```rust
/// 插件可通过 EventBus 注入自定义事件
pub struct PluginEventInjector {
    bus: Arc<Mutex<EventBus>>,
    plugin_id: String,
}

impl PluginEventInjector {
    pub fn inject(&self, event_type: &str, payload: serde_json::Value, state: &GameState) {
        let mut bus = self.bus.lock().unwrap();
        bus.publish_custom(event_type, &self.plugin_id, payload, state);
    }
}
```

---

## 4. 实施计划

### Phase 1 — 基础设施（不破坏现有代码）

1. **新增** `AnyEvent` 包装枚举
2. **新增** `EventBus` 结构体（基于 `Vec` 的订阅者列表）
3. **新增** `EventSubscriber` / `EventMiddleware` / `AsyncEventSubscriber` traits
4. **新增** `EventAction` 结果枚举
5. 在 `GameEvent` 上添加 `event_type_str()` 方法

### Phase 2 — 集成核心

6. `GameEngine::execute_and_emit()` — 通过总线发布事件的新方法
7. `TurnProcessor::process_turn_with_bus()` — 使用总线的新回合处理器
8. `EngineBridge` 改用总线模式（逐步替换 `BROADCASTER` 全局变量）
9. 内置订阅者：`BridgeBroadcaster`, `EventLogger`

### Phase 3 — Plugin 集成

10. `Plugin::register_subscribers()` — 插件向总线注册钩子
11. `PluginEventInjector` — 插件注入自定义事件
12. 权限检查集成：`EventInjection` + `WriteState` 权限验证

### Phase 4 — 高级功能

13. 事件溯源日志（可选持久化）
14. 网络同步的事件订阅（按事件类型过滤同步）
15. 条件事件调度（`if event.x > 5 then trigger y`）

---

## 5. 向后兼容策略

| 旧接口 | 新接口 | 保留周期 |
|--------|--------|----------|
| `GameEngine::execute() -> GameEvent` | `GameEngine::execute_and_emit(..., bus)` | 长期保留 |
| `TurnProcessor::process_turn() -> Vec<GameEvent>` | `TurnProcessor::process_turn_with_bus(..., bus)` | 2 个版本 |
| `EngineBridge::execute() -> BridgeResponse` | `EngineBridge::execute_with_bus(..., bus)` | 2 个版本 |
| `BROADCASTER` 全局变量 | `BridgeBroadcaster` 订阅者 | 1 个版本后弃用 |
| `VecEventBus<E>` | `EventBus` | 立即标记弃用 |
| `EventSink<E>` | `EventBus` | 立即标记弃用 |

---

## 6. 文件变更清单

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| [`crates/application/src/events.rs`](crates/application/src/events.rs) | **重写** | 新增 `AnyEvent`, `EventBus`, `EventSubscriber`, `EventMiddleware` |
| [`crates/application/src/ports.rs`](crates/application/src/ports.rs) | 删除 | 移除未使用的 `EventSink<E>` |
| [`crates/application/src/engine.rs`](crates/application/src/engine.rs) | 修改 | 添加 `execute_and_emit()` |
| [`crates/application/src/turn_processor.rs`](crates/application/src/turn_processor.rs) | 修改 | 添加 `process_turn_with_bus()` |
| [`crates/application/src/bridge.rs`](crates/application/src/bridge.rs) | 修改 | 移除 `BROADCASTER`，改用 `BridgeBroadcaster` |
| [`crates/infra/src/plugins.rs`](crates/infra/src/plugins.rs) | 修改 | `Plugin` trait 添加 `register_subscribers()` |
| [`crates/infra/src/network.rs`](crates/infra/src/network.rs) | 修改 | 改用事件驱动广播 |
| **新文件**: `crates/application/src/event_bus.rs` | **新增** | 主 EventBus 实现和所有订阅者 trait |
| **新文件**: `crates/application/src/subscribers/` | **新增** | 内置订阅者模块 |

---

## 7. 改造后的事件流示意图

```
                   ┌─────────────────────────────────────┐
                   │            EventBus                  │
                   │                                     │
GameCommand ──────►│  Middleware Chain                    │
                   │  ┌─────────────────────────────┐    │
                   │  │ ① LoggingMiddleware (日志)    │    │
                   │  │ ② FilterMiddleware (过滤)     │    │
                   │  │ ③ TransformMiddleware (转换)  │    │
                   │  └──────────┬──────────────────┘    │
                   │             ▼                       │
                   │  Subscribers (优先级排序)            │
                   │  ┌─────────────────────────────┐    │
                   │  │ [First] SchedulerBridge     │    │
                   │  │ [Early] PluginSubscribers   │    │
                   │  │ [Normal] BridgeBroadcaster  ├───►│ Flutter
                   │  │ [Late]  EventLogger         │    │
                   │  │ [Last]  NetworkSync         ├───►│ Network
                   │  └─────────────────────────────┘    │
                   └─────────────────────────────────────┘

模组自定义事件流:
Plugin ──► PluginEventInjector ──► EventBus.publish_custom()
                                        │
                                   (经过相同管道)
                                        ▼
                                   BridgeBroadcaster
                                   (作为 GenericEvent 发送到 Flutter)
```
