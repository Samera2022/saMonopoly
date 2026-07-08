# Forge 模式事件系统设计方案

## 设计目标

仿照 Minecraft Forge 的事件架构，让插件能够：

1. **取消操作** — 插件 `set_canceled(true)` 后，原版逻辑跳过执行
2. **覆盖结果** — 插件 `set_result(ALLOW/DENY)` 强制决定结果
3. **修改参数** — 插件在 Pre-Event 中修改金额、目标等
4. **注册新命令/地块行为** — 插件可以覆盖或替换原版行为
5. **声明式注册** — 简化插件开发

---

## 核心类型

### 1. CancellableEvent — 可取消事件

```rust
/// 可取消事件的通用结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventResult {
    /// 未设置（由原版逻辑决定）
    Default,
    /// 强制允许
    Allow,
    /// 强制拒绝
    Deny,
}

/// 可取消事件的基类。
#[derive(Debug, Clone)]
pub struct CancellableEvent {
    /// 唯一事件类型标识
    pub event_type: String,
    /// 发送来源
    pub source: String,
    /// 事件载荷
    pub payload: serde_json::Value,
    /// 是否被取消
    canceled: bool,
    /// 结果覆盖
    result: EventResult,
}

impl CancellableEvent {
    pub fn new(event_type: &str, source: &str, payload: serde_json::Value) -> Self { ... }

    /// 取消此事件（原版逻辑将跳过执行）
    pub fn set_canceled(&mut self, canceled: bool) { self.canceled = canceled; }
    pub fn is_canceled(&self) -> bool { self.canceled }

    /// 覆盖事件结果
    pub fn set_result(&mut self, result: EventResult) { self.result = result; }
    pub fn get_result(&self) -> EventResult { self.result }
}
```

### 2. PreEventHook — 命令执行前钩子

```rust
/// Pre-Event 钩子：在命令执行前同步调用。
/// 所有钩子按优先级排序。任何钩子返回 `Cancel` 则命令不执行。
pub enum PreEventAction {
    /// 继续执行命令
    Continue,
    /// 取消命令
    Cancel(String),  // String = 取消原因
    /// 修改事件 payload 后继续
    Modify(serde_json::Value),
}

pub trait PreEventHook: Send + Sync {
    fn id(&self) -> &str;
    fn priority(&self) -> SubscriberPriority { SubscriberPriority::Normal }
    /// 在命令执行前调用。返回 `Cancel` 可阻止命令。
    fn on_pre_command(
        &mut self,
        command_type: &str,
        payload: &serde_json::Value,
        state: &GameState,
    ) -> PreEventAction;
}
```

### 3. PostEventHook — 命令执行后通知

```rust
/// Post-Event 钩子：在命令执行后调用（不可取消，仅通知）
pub trait PostEventHook: Send + Sync {
    fn id(&self) -> &str;
    fn priority(&self) -> SubscriberPriority { SubscriberPriority::Normal }
    fn on_post_command(
        &mut self,
        command_type: &str,
        state: &GameState,
        events: &[AnyEvent],
    );
}
```

---

## EventBus 扩展

```rust
pub struct EventBus {
    pub middlewares: Vec<Box<dyn EventMiddleware>>,
    pub(crate) subscribers: Vec<SubscriberEntry>,
    pub(crate) async_subscribers: Vec<AsyncSubscriberEntry>,
    pub command_handlers: CommandHandlerRegistry,
    pub tile_behaviors: TileBehaviorRegistry,

    // ─── 新增 ───
    /// Pre-Event 钩子：在命令执行前调用
    pre_hooks: Vec<PreHookEntry>,
    /// Post-Event 钩子：在命令执行后调用
    post_hooks: Vec<PostHookEntry>,
    /// 当前命令的 Pre-Event 缓存（用于 Forge 风格的 Pre/Post 配对）
    current_pre_event: Option<CancellableEvent>,

    sorted: bool,
    custom_events: Vec<AnyEvent>,
}

impl EventBus {
    // ─── 新增注册方法 ───

    pub fn register_pre_hook(&mut self, hook: Box<dyn PreEventHook>) {
        let priority = hook.priority();
        self.pre_hooks.push(PreHookEntry { hook, priority, registered_at: self.pre_hooks.len() });
        self.sorted = false;
    }

    pub fn register_post_hook(&mut self, hook: Box<dyn PostEventHook>) {
        let priority = hook.priority();
        self.post_hooks.push(PostHookEntry { hook, priority, registered_at: self.post_hooks.len() });
        self.sorted = false;
    }

    pub fn unregister_pre_hook(&mut self, id: &str) {
        self.pre_hooks.retain(|e| e.hook.id() != id);
    }

    pub fn unregister_post_hook(&mut self, id: &str) {
        self.post_hooks.retain(|e| e.hook.id() != id);
    }
}
```

---

## 命令执行流程（重构）

```rust
pub fn execute_command(&mut self, command: DomainAnyEvent, state: &mut GameState, rng: &mut dyn RngService) {
    let command_type = command.event_type().to_string();
    let payload = extract_payload(&command);

    // ★ 阶段 1: Pre-Event — 让插件决定是否执行
    let pre_result = self.fire_pre_hooks(&command_type, &payload, state);
    match pre_result {
        PreEventAction::Cancel(reason) => {
            self.publish_custom("core:command_rejected", "core",
                serde_json::json!({ "reason": reason, "cancelled_by_plugin": true }), state);
            return;
        }
        PreEventAction::Modify(modified_payload) => {
            // 重建命令，使用插件修改后的 payload
            let modified_command = rebuild_command(&command, modified_payload);
            self.execute_handler(&command_type, modified_command, state, rng);
        }
        PreEventAction::Continue => {
            self.execute_handler(&command_type, command, state, rng);
        }
    }

    // ★ 阶段 2: Post-Event — 通知插件命令已执行
    let events = self.drain_custom_events();  // 收集刚发布的 events
    self.fire_post_hooks(&command_type, state, &events);
    // 把 events 重新放回去，让桥接层能拿到
    for e in events { self.custom_events.push(e); }
}
```

### handle_pay_rent 改造示例

```rust
fn handle_pay_rent(state: &mut GameState, event: AnyEvent, rng: &mut dyn RngService, bus: &mut EventBus) {
    let cmd: PayRentCommand = match event.into_typed() { Ok(c) => c, Err(e) => { ... return; } };
    // ... 验证 ...

    // 计算租金
    let rent_amount = property.current_rent();

    // ★ Pre-Event: 让插件决定是否/如何收租
    let pre = bus.fire_command_pre_hook("core:rent_due", serde_json::json!({
        "player_id": cmd.player_id,
        "owner_id": owner_id,
        "amount": rent_amount,
        "tile_id": cmd.tile_id,
    }), state);

    if pre.is_canceled() {
        bus.publish_custom("core:command_rejected", "core",
            serde_json::json!({ "reason": "cancelled_by_plugin", "plugin": pre.cancelled_by() }), state);
        return;
    }

    // 插件可能修改了金额
    let final_amount = pre.get_modified("amount")
        .and_then(|v| v.as_i64())
        .unwrap_or(rent_amount);

    // 执行租金转移
    if let Some(player) = state.players.get_mut(active_idx) { player.cash -= final_amount; }
    if let Some(owner) = state.players.get_mut(owner_idx) { owner.cash += final_amount; }

    // 正常发布事件
    bus.publish_custom("core:rent_paid", "core", serde_json::json!({ ... }), state);
}
```

---

## 插件 API

```rust
/// 插件开发者看到的接口
pub trait ForgeStylePlugin: Send + Sync {
    fn id(&self) -> &str;

    /// 注册 Pre-Event 钩子
    fn register_pre_hooks(&mut self, bus: &mut EventBus) {
        // 默认无钩子
    }

    /// 注册 Post-Event 钩子
    fn register_post_hooks(&mut self, bus: &mut EventBus) {
        // 默认无钩子
    }

    /// 注册事件订阅者
    fn register_subscribers(&mut self, bus: &mut EventBus) {
        // 默认无订阅者
    }

    /// 注册命令处理器
    fn register_commands(&mut self, registry: &mut CommandHandlerRegistry) {
        // 默认无命令
    }

    /// 注册地块行为
    fn register_tile_behaviors(&mut self, registry: &mut TileBehaviorRegistry) {
        // 默认无地块行为
    }
}
```

### 插件示例：免租插件

```rust
struct RentFreePlugin {
    plugin_id: String,
}

impl PreEventHook for RentFreePlugin {
    fn id(&self) -> &str { &self.plugin_id }
    fn priority(&self) -> SubscriberPriority { SubscriberPriority::First }

    fn on_pre_command(&mut self, command_type: &str, payload: &serde_json::Value, _state: &GameState) -> PreEventAction {
        if command_type == "core:rent_due" {
            log::info!("[RentFreePlugin] Cancelling rent payment!");
            return PreEventAction::Cancel("free_rent".to_string());
        }
        PreEventAction::Continue
    }
}

impl ForgeStylePlugin for RentFreePlugin {
    fn id(&self) -> &str { "rent_free_plugin" }

    fn register_pre_hooks(&mut self, bus: &mut EventBus) {
        bus.register_pre_hook(Box::new(RentFreeHook { plugin_id: self.id().to_string() }));
    }
}
```

### 插件示例：双倍租金插件

```rust
struct DoubleRentPlugin;

impl PreEventHook for DoubleRentPlugin {
    fn id(&self) -> &str { "double_rent" }
    fn priority(&self) -> SubscriberPriority { SubscriberPriority::Normal }

    fn on_pre_command(&mut self, _cmd: &str, payload: &serde_json::Value, _state: &GameState) -> PreEventAction {
        // 把租金翻倍
        if let Some(amount) = payload.get("amount").and_then(|v| v.as_i64()) {
            let mut modified = payload.clone();
            modified["amount"] = serde_json::json!(amount * 2);
            return PreEventAction::Modify(modified);
        }
        PreEventAction::Continue
    }
}
```

### 插件示例：自定义地块行为（覆盖原版）

```rust
struct MyCustomPropertyPlugin;

impl ForgeStylePlugin for MyCustomPropertyPlugin {
    fn id(&self) -> &str { "my_custom_property" }

    fn register_tile_behaviors(&mut self, registry: &mut TileBehaviorRegistry) {
        // 注意：原版 "core:ordinary_property" 已被 core 注册
        // 当前 system 不允许覆盖。新方案需要先 unregister 再 register
        // 或者改用 Pre-Event 钩子取消原版 + 注入自定义事件
    }
}
```

---

## TileBehaviorRegistry 扩展（支持覆盖）

```rust
impl TileBehaviorRegistry {
    /// 强制注册行为（会覆盖已有的）
    pub fn register_override(
        &mut self,
        tile_type: &str,
        plugin_id: &str,
        behavior: TileBehavior,
    ) {
        self.behaviors.insert(
            tile_type.to_string(),
            (behavior, plugin_id.to_string()),
        );
    }
}
```

---

## 优先级系统利用

目前 `SubscriberPriority` 已定义但未在 execute_command 中使用：

```
First    = 0   → 系统核心逻辑（如安全校验）
Early    = 1   → 插件高优先级钩子
Normal   = 2   → 插件普通钩子
Late     = 3   → 插件低优先级钩子
Last     = 4   → 日志/统计等非功能性订阅者
```

改造后，`fire_pre_hooks()` 按照 `(priority, registered_at)` 排序执行。

---

## 迁移策略

| 阶段 | 内容 | 影响 |
|------|------|------|
| **Phase A** | 新增 `CancellableEvent` + `EventResult` 类型 | 新增文件，无破坏性 |
| **Phase B** | EventBus 新增 `pre_hooks` / `post_hooks` + 注册/注销方法 | 向后兼容，新增字段 |
| **Phase C** | 改造 `execute_command` 加入 Pre/Post 事件流 | 核心变更，需要测试所有命令 |
| **Phase D** | 逐个改造命令处理器（先改 `pay_rent`、`buy_property` 等关键命令） | 在每个 handler 中插入 pre-hook 调用 |
| **Phase E** | `TileBehaviorRegistry` 添加 `register_override` | 微小改动 |
| **Phase F** | 更新 `PluginManager` 以支持新的注册路径 | 向后兼容 |

---

## 不变原则

1. **事后事件保留** — 现有的 `core:rent_paid`、`core:property_bought` 等 Post-Event 继续存在
2. **Pre-Event 仅作用于当前 EventBus 实例** — FFI 路径每次创建新 bus，不影响全局
3. **插件取消不改变 state** — Pre-Event 钩子返回 `Cancel` 时，state 未被修改
4. **向后兼容** — 不修改 pre_hooks 的旧插件完全不受影响
