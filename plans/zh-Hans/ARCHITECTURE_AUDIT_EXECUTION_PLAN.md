# 审计驱动开发执行计划

## 概述

本计划基于 [`plans/zh-Hans/ARCHITECTURE_AUDIT.md`](plans/zh-Hans/ARCHITECTURE_AUDIT.md) 文档，将 Flutter 端非UI游戏逻辑迁移到 Rust 引擎。所有子任务严格遵循 **审计驱动开发流程（ADDP）**。

---

## 子任务清单（按执行顺序）

### 子任务 1：Rust — 在 `handle_roll()` 中添加 `resolve_tile()` 调用

| 属性 | 内容 |
|------|------|
| **需求描述** | 在 [`crates/application/src/builtin/commands.rs`](crates/application/src/builtin/commands.rs:133) 的 `handle_roll()` 函数中，玩家移动完成且 `core:player_moved` 事件发布之后、`core:command_accepted` 发布之前，添加对 `bus.resolve_tile()` 的调用。跳过 `ordinary_property`、`extension_property`、`special_property` 三种地产类型（由 Flutter 端处理购买/升级/租金）。需要导入 `sa_monopoly_domain::tile::tile_types`。 |
| **修改文件** | `crates/application/src/builtin/commands.rs` |
| **审计标准** | 1. 导入 `tile_types` 模块 2. 代码位于 `core:player_moved` 之后、`core:command_accepted` 之前 3. 跳过三种 property 类型 4. 正确调用 `bus.resolve_tile(tile_kind, state, &tile_id, rng)` 5. 编译通过 `cargo build` |

### 子任务 2：Flutter — 删除 `_resolveTileEffect()` 并更新 `_onRoll()`

| 属性 | 内容 |
|------|------|
| **需求描述** | 从 [`flutter/lib/main.dart`](flutter/lib/main.dart:1396) 中删除整个 `_resolveTileEffect()` 方法（约 80 行）。在 `_onRoll()` 方法中（第 1323 行）移除调用 `_resolveTileEffect(playerPos)`。移除第 1329 行的 `_syncCurrentState(eventType: 'TileEffect')`。更新 `_rollAnimationCallbacks()`（第 1170-1176 行）的注释，移除"dialogs deferred to _resolveTileEffect"的描述。 |
| **修改文件** | `flutter/lib/main.dart` |
| **审计标准** | 1. `_resolveTileEffect()` 方法被完整删除 2. `_onRoll()` 中不再调用 `_resolveTileEffect()` 3. `_onRoll()` 中不再调用 `_syncCurrentState(eventType: 'TileEffect')` 4. 编译通过 `flutter analyze` |

### 子任务 3：Flutter — 删除 `_sendToJail()`、`_showChanceCardDialog()`、`_deductCash()`、`_addCash()`

| 属性 | 内容 |
|------|------|
| **需求描述** | 从 [`flutter/lib/main.dart`](flutter/lib/main.dart:1617) 中删除以下不再使用的本地模拟方法：`_sendToJail()`（第 1617-1634 行）、`_showChanceCardDialog()`（第 1636-1696 行）、`_deductCash()`（第 1589-1601 行）、`_addCash()`（第 1603-1615 行）。这些方法的全部功能已由 Rust 引擎的 TileBehavior 系统替代。Chance 卡牌通过 `core:card_drawn` 事件由 EventDispatcher 处理。 |
| **修改文件** | `flutter/lib/main.dart` |
| **审计标准** | 1. `_sendToJail()` 被删除 2. `_showChanceCardDialog()` 被删除 3. `_deductCash()` 被删除 4. `_addCash()` 被删除 5. 编译通过 `flutter analyze` |

### 子任务 4：Flutter — 更新 EventDispatcher 处理新的地块效果事件

| 属性 | 内容 |
|------|------|
| **需求描述** | 在 [`flutter/lib/event_dispatcher.dart`](flutter/lib/event_dispatcher.dart:267) 的 EventDispatcher 中，更新以下事件的日志消息，使其显示具体金额信息：`core:income_tax_paid`（显示 "$200 Income tax paid"）、`core:luxury_tax_paid`（显示 "$100 Luxury tax paid"）、`core:free_parking_bonus`（显示 "$200 Free parking bonus"）、`core:bank_bonus`（显示 "$200 Bank bonus received"）。这些事件现在由 Rust 引擎的 `resolve_tile()` 触发，不再由 Flutter 本地模拟。 |
| **修改文件** | `flutter/lib/event_dispatcher.dart` |
| **审计标准** | 1. `core:income_tax_paid` 显示具体金额 2. `core:luxury_tax_paid` 显示具体金额 3. `core:free_parking_bonus` 显示具体金额 4. `core:bank_bonus` 显示具体金额 5. 编译通过 `flutter analyze` |

### 子任务 5：整体回归验证

| 属性 | 内容 |
|------|------|
| **需求描述** | 验证整个项目在修改后仍然正确运行：1. Rust 端 `cargo build` 编译成功 2. Rust 端 `cargo test` 测试全部通过 3. Flutter 端 `flutter analyze` 无错误 4. 确认 `handle_roll()` 调用 `resolve_tile()` 后发布的事件能被 `EventDispatcher` 正确解析。 |
| **验证命令** | `cargo build && cargo test && cd flutter && flutter analyze` |

---

## 执行流程（ADDP）

对每个子任务，按以下循环执行：

```
┌─────────────────────────────────────────┐
│  Step A: 创建 Code 模式子任务           │
│  (new_task → code mode, 仅含需求描述)   │
└──────────────┬──────────────────────────┘
               ▼
┌─────────────────────────────────────────┐
│  Step B: 创建 Audit 模式子任务          │
│  (new_task → code mode, 仅含需求+代码)  │
└──────────────┬──────────────────────────┘
               ▼
          ┌──────────┐     否
          │ 通过?    ├──────→ 返回 Step A
          └────┬─────┘      (附修改意见)
               │ 是
               ▼
         标记完成 → 进入下一子任务
```

## 架构变更示意

```
┌─────────────────────────────────────────────────┐
│ 迁移前                                          │
│                                                 │
│ 掷骰 → Rust handle_roll() → 移动玩家 → 返回状态 │
│   → Flutter _resolveTileEffect() 本地模拟效果   │
│     → 直接操作 _currentState (deductCash等)     │
└─────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────┐
│ 迁移后                                          │
│                                                 │
│ 掷骰 → Rust handle_roll() → 移动玩家            │
│   → bus.resolve_tile() → TileBehavior 执行效果   │
│   → 状态已包含所有效果 → Flutter 直接应用       │
│   → EventDispatcher 显示日志                    │
└─────────────────────────────────────────────────┘
```
