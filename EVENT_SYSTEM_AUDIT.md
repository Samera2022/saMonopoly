# Event System Audit: Complexity, Extensibility & Mod Support

## 1. 当前事件实现概览

当前事件系统以 [`GameEvent`](crates/application/src/events.rs:5) 枚举为核心，定义于 [`crates/application/src/events.rs`](crates/application/src/events.rs)，包含约 30 个变体。事件由 [`GameEngine::execute()`](crates/application/src/engine.rs:30) 产生，通过 [`VecEventBus`](crates/application/src/events.rs:67) 收集，通过 [`EngineBridge`](crates/application/src/bridge.rs:57) 序列化为 JSON 传递给 Flutter 前端。

### 核心架构

```
GameCommand → GameEngine::execute() → GameEvent → VecEventBus → BridgeResponse(JSON) → Flutter
```

### 事件变体分类

| 类别 | 变体数 | 示例 |
|------|--------|------|
| 流程控制 | 6 | `GameStarted`, `TurnAdvanced`, `GameWon` |
| 玩家行动 | 3 | `PlayerMoved`, `DiceRolled`, `ExtraTurn` |
| 地产 | 6 | `PropertyBought`, `RentPaid`, `PropertyMortgaged` |
| 卡片/牌组 | 4 | `CardDrawn`, `CardBought`, `CardConsumed`, `CardUsed` |
| 监狱/医院 | 4 | `PlayerSentToJail`, `PlayerReleasedFromHospital` |
| 拍卖 | 4 | `AuctionStarted`, `AuctionBid`, `AuctionWon`, `AuctionEnded` |
| 股票市场 | 2 | `StockMarketTick`, `SharesBought/Sold` |
| 彩票 | 3 | `LotteryAvailable`, `LotteryTicketBought`, `LotteryDrawResult` |
| 命令响应 | 2 | `CommandAccepted`, `CommandRejected` |
| 配置 | 2 | `ConfigLoaded`, `ConfigUpdated` |
| 破产/淘汰 | 2 | `PlayerBankrupt`, `PlayerEliminated` |
| 保释 | 1 | `BailPaid` |

---

## 2. 对复杂性的支持分析

### ✅ 已支持的复杂性

1. **时序调度（Scheduler）**： [`crates/application/src/scheduler.rs`](crates/application/src/scheduler.rs) 实现了 `TimedEffect` 系统，支持：
   - 延迟触发（`trigger_turn`）
   - 循环触发（`recurring` + `interval_turns`）
   - 按 ID 取消（`cancel`）
   - 效果类型：监狱释放、医院释放、股票Tick、卡牌过期、利息累积、彩票开奖、自定义

2. **条件分支**： [`GameEngine::execute()`](crates/application/src/engine.rs:30) 的 `match` 包含复杂的条件逻辑：
   - 监狱/医院的停留判断
   - 连续 sum-7 三次进监狱
   - 经过起点奖励 $200
   - 破产检查链
   - Bonus Card 自动消耗

3. **效果链（Effect Chains）**： [`EffectResolver::resolve_special_tile()`](crates/application/src/effects.rs:11) 处理多种格子类型的差异化效果，并产生对应事件。

4. **状态机驱动**： [`TurnProcessor`](crates/application/src/turn_processor.rs:39) 将一回合处理分解为多个阶段（Phase 1: 掷骰→移动→格子效果, Phase 2: 购买/升级决策, Phase 3: 结束回合）。

### ❌ 不支持/待改进的复杂性

1. **事件嵌套/复合事件**： 每个 `GameCommand` 只能返回**一个** `GameEvent`。无法在一个命令中触发多个事件序列（例如：移动→触发效果→检查破产→触发下一个效果）。目前通过 `TurnProcessor` 在外部组合多个命令调用来解决。

2. **事件过滤/转换管道**： 没有中间件或过滤器机制来拦截、修改、丢弃或转换事件流。

3. **事件优先级/顺序控制**： 事件产生后按顺序追加到 `VecEventBus`，无法指定优先级或条件顺序。

4. **条件事件订阅**： `EventBus` trait 仅定义了 `publish()`，没有注册回调或订阅者模式的接口。

5. **事件溯源（Event Sourcing）**： 没有持久化的事件日志，无法回滚到历史状态或重放事件序列。

---

## 3. 对模组（Mod）支持的评估

### ✅ 已支持的模组机制

1. **插件系统**： [`crates/infra/src/plugins.rs`](crates/infra/src/plugins.rs) 实现了完整的插件框架：
   - `Plugin` trait（`init`, `shutdown`, `info`）
   - `PluginRegistry`（`register`, `unregister`, `enable`, `disable`）
   - 权限系统（`Permission` 枚举：`ReadState`, `WriteState`, `EventInjection`, `ExecuteScript` 等）
   - 动态加载配置（`DynamicLoadConfig`：支持 `.so`/`.dll`/`.dylib`, `.wasm`, `.lua`/`.js` 脚本）

2. **脚本引擎**： [`crates/infra/src/scripting.rs`](crates/infra/src/scripting.rs) 提供了：
   - `SimpleExpressionEvaluator`：纯 Rust 表达式求值器（算术、比较、if-then-else、函数调用）
   - `JsExpressionEvaluator`：JS 风格表达式求值器（三元运算符、函数调用、变量引用）
   - `JsScriptHost`：支持注释剥离的 JS 脚本执行
   - `WasmScriptHost`：WASM 运行时占位

3. **内容包系统**： [`crates/infra/src/content.rs`](crates/infra/src/content.rs) 支持：
   - `ContentPack` 漫游发现
   - 地图定义（`MapDefinition`）和验证
   - `.smap` 打包格式

4. **权限模型**： [`PermissionSet`](crates/infra/src/plugins.rs:36) 提供：
   - 显式授权/拒绝
   - 默认安全（仅 `ReadState` + `EventInjection`）
   - `EventInjection` 权限明确指出模组可以监听和注入事件

### ❌ 模组支持的缺口

1. **`Plugin` trait 未集成事件总线**： 插件注册后没有标准方式订阅事件。虽然有 `EventInjection` 权限，但没有 `on_event()` 回调或 `subscribe()` API 暴露给 `Plugin` trait。

2. **自定义事件注册**： `GameEvent` 是 Rust 枚举，模组**无法**定义新的事件变体。要在枚举中添加新事件必须修改核心代码。这是最大的限制。

3. **自定义命令注册**： 同理，`GameCommand` 也是枚举，模组无法添加新的命令。

4. **自定义格子类型**： `TileKind` 枚举是固定的，模组无法注册新的格子类型。`ExtensionProperty` 是为预留扩展准备的，但并没有开放的注册机制。

5. **脚本上下文有限**： 脚本表达式只支持 `i64` 类型的变量和返回值，无法操作 `GameState`、`Player` 等复杂类型。

6. **动态加载尚未完成**： `WasmScriptHost::run()` 返回错误（"WASM script execution requires a WASM runtime"），`DynamicLoadConfig` 的加载路径是占位实现。

7. **无事件过滤沙箱**： 虽然有权限系统，但没有实现事件级别过滤——插件如果获得 `EventInjection` 权限，理论上可以监听**所有**事件，无法按类型或内容过滤。

---

## 4. 关键缺陷总结

| 维度 | 现状 | 问题 |
|------|------|------|
| **事件类型扩展** | Rust 枚举 | 模组无法定义新事件类型；需修改核心源码 |
| **命令类型扩展** | Rust 枚举 | 模组无法注册新命令 |
| **格子类型扩展** | Rust 枚举 + `ExtensionProperty` | `ExtensionProperty` 是占位，无开放注册 API |
| **事件订阅** | `VecEventBus` 仅存储事件 | 无回调/监听者模式暴露给插件 |
| **动态加载** | `PluginLoader` / `DynamicLoadConfig` | WASM 未实现，脚本引擎功能有限 |
| **自定义效果** | `EffectResolver` 硬编码 | 模组无法注册自定义格子效果处理函数 |
| **事件流控制** | 无中间件/过滤器 | 模组无法拦截或转换事件流 |
| **类型系统** | `i64` 仅为脚本变量 | 脚本无法交互 `GameState`、`Player` 等复杂对象 |
| **序列化** | `serde_json` + `#[serde(tag)]` | 事件通过 JSON 传递，模组自定义事件无法反序列化 |

## 5. 改进建议（按优先级）

### P0 — 必须解决
1. **开放事件/命令注册**： 引入 `Box<dyn Any>` 或 `serde_json::Value` 通行证机制，允许模组定义自定义事件和命令，通过 `event_type: "mod:custom_name"` 标识。
2. **插件事件钩子**： 在 `Plugin` trait 中添加 `fn on_event(&mut self, event: &GameEvent, state: &mut GameState)` 和 `fn on_command(&mut self, command: &GameCommand, state: &GameState) -> Option<GameCommand>`。

### P1 — 重要
3. **事件中间件管道**： 引入 `EventMiddleware` trait，允许模组拦截、修改、过滤事件流。
4. **开放格子类型注册**： 将 `TileKind` 从枚举改为 `TileKind::Custom(String)`，允许模组定义新的格子行为。

### P2 — 增强
5. **WASM 沙箱运行时**： 集成 wasmtime/wasmer 以实现安全的插件执行环境。
6. **脚本能力扩展**： 暴露有限的 `GameState` 处理能力给脚本上下文（通过宿主函数 `get_player_cash`, `set_player_cash` 等）。
7. **事件溯源存储**： 可选的事件日志，支持回放和调试。

---

## 6. 结论

当前事件系统是一个**单体枚举模式**的经典实现，适合单一代码库管理，对于**内置规则**的复杂度支持良好（时序调度、条件分支、效果链）。但在**模组支持**方面存在根本性限制：

- **类型封闭性**： `GameEvent`、`GameCommand`、`TileKind` 都是 Rust 枚举，模组无法扩展。
- **插件与事件总线未桥接**： 插件系统与事件系统是两个独立子系统，没有集成。
- **动态加载不完整**： WASM 和脚本引擎尚未可用于生产环境。

系统目前更适合**硬编码规则扩展**（通过修改核心代码添加新事件/命令），而非**真正的模组 API 和运行时扩展**。
