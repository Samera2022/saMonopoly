# 事件系统改进方案

## 设计目标

让插件能够：

1. **取消操作** — 插件标记取消后，原版逻辑跳过执行
2. **覆盖结果** — 插件强制决定操作结果（允许/拒绝）
3. **修改参数** — 插件在操作执行前修改金额、目标等
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
    pub event_type: String,
    pub source: String,
    pub payload: serde_json::Value,
    canceled: bool,
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
/// 按优先级排序。任何钩子返回 `Cancel` 则命令不执行。
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
    // ... 现有字段 ...
    
    // ─── 新增 ───
    /// Pre-Event 钩子：在命令执行前调用
    pre_hooks: Vec<PreHookEntry>,
    /// Post-Event 钩子：在命令执行后调用
    post_hooks: Vec<PostHookEntry>,

    sorted: bool,
    custom_events: Vec<AnyEvent>,
}

impl EventBus {
    // ─── 新增注册方法 ───
    pub fn register_pre_hook(&mut self, hook: Box<dyn PreEventHook>) { ... }
    pub fn register_post_hook(&mut self, hook: Box<dyn PostEventHook>) { ... }
    pub fn unregister_pre_hook(&mut self, id: &str) { ... }
    pub fn unregister_post_hook(&mut self, id: &str) { ... }
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
            let modified_command = rebuild_command(&command, modified_payload);
            self.execute_handler(&command_type, modified_command, state, rng);
        }
        PreEventAction::Continue => {
            self.execute_handler(&command_type, command, state, rng);
        }
    }

    // ★ 阶段 2: Post-Event — 通知插件命令已执行
    let events = self.drain_custom_events();
    self.fire_post_hooks(&command_type, state, &events);
    for e in events { self.custom_events.push(e); }
}
```

### handle_pay_rent 改造示例

```rust
fn handle_pay_rent(state: &mut GameState, event: AnyEvent, rng: &mut dyn RngService, bus: &mut EventBus) {
    // ... 验证 ...

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

    bus.publish_custom("core:rent_paid", "core", serde_json::json!({ ... }), state);
}
```

---

## 插件 API

```rust
/// 插件开发者看到的接口
pub trait EventSystemPlugin: Send + Sync {
    fn id(&self) -> &str;

    /// 注册 Pre-Event 钩子
    fn register_pre_hooks(&mut self, bus: &mut EventBus) {}
    /// 注册 Post-Event 钩子
    fn register_post_hooks(&mut self, bus: &mut EventBus) {}
    /// 注册事件订阅者
    fn register_subscribers(&mut self, bus: &mut EventBus) {}
    /// 注册命令处理器
    fn register_commands(&mut self, registry: &mut CommandHandlerRegistry) {}
    /// 注册地块行为
    fn register_tile_behaviors(&mut self, registry: &mut TileBehaviorRegistry) {}
}
```

### 插件示例：免租插件

```rust
struct RentFreePlugin;

impl PreEventHook for RentFreePlugin {
    fn id(&self) -> &str { "rent_free_plugin" }
    fn priority(&self) -> SubscriberPriority { SubscriberPriority::First }

    fn on_pre_command(&mut self, command_type: &str, payload: &serde_json::Value, _state: &GameState) -> PreEventAction {
        if command_type == "core:rent_due" {
            log::info!("[RentFreePlugin] 取消租金支付!");
            return PreEventAction::Cancel("free_rent".to_string());
        }
        PreEventAction::Continue
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
        if let Some(amount) = payload.get("amount").and_then(|v| v.as_i64()) {
            let mut modified = payload.clone();
            modified["amount"] = serde_json::json!(amount * 2);
            return PreEventAction::Modify(modified);
        }
        PreEventAction::Continue
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

## 优先级系统

```
First    = 0   → 系统核心逻辑（如安全校验）
Early    = 1   → 插件高优先级钩子
Normal   = 2   → 插件普通钩子
Late     = 3   → 插件低优先级钩子
Last     = 4   → 日志/统计等非功能性订阅者
```

改造后，`fire_pre_hooks()` 按照 `(priority, registered_at)` 排序执行。

---

## 迁移策略（6 阶段）

| 阶段 | 内容 | 核心文件 | 影响 |
|------|------|---------|------|
| **A** | 新增 `CancellableEvent` + `EventResult` 类型 | 新增 `cancellable_event.rs` | 无破坏性 |
| **B** | EventBus 新增 `pre_hooks` / `post_hooks` + 注册/注销方法 | `event_bus.rs` | 向后兼容 |
| **C** | 改造 `execute_command` 加入 Pre/Post 事件流 | `event_bus.rs` | 核心变更，需测试 |
| **D** | 逐个改造命令处理器（先 `pay_rent`、`buy_property`） | `commands.rs` | 每个 handler 插入 pre-hook |
| **E** | `TileBehaviorRegistry` 添加 `register_override` | `tile_behavior.rs` | 微小改动 |
| **F** | 更新 `PluginManager` 以支持新的注册路径 | `plugin_manager.rs` | 向后兼容 |

---

## 不变原则

1. **事后事件保留** — 现有的 `core:rent_paid`、`core:property_bought` 等通知事件继续存在
2. **Pre-Event 仅作用于当前 EventBus 实例** — FFI 路径每次创建新 bus，不影响全局
3. **插件取消不改变 state** — Pre-Event 钩子返回 `Cancel` 时，state 未被修改
4. **向后兼容** — 不注册 pre_hooks 的旧插件完全不受影响
