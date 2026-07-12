# Flutter 非 UI 功能审计与迁移方案

## 一、核心问题

Flutter 当前承担了大量本应由 Rust 引擎处理的游戏逻辑。Rust `crates/application/src/builtin/tiles.rs` 中已注册完整的 `TileBehavior` 系统（覆盖 Start、Chance、CardShop、Lottery、Bank、Jail、Hospital、GoToJail、SpecialProperty、OrdinaryProperty、ExtensionProperty 共 11 种地块类型），但 **这些行为从未被触发**。

每次掷骰后，Rust `handle_roll` 仅负责：
1. 生成骰子点数
2. 移动玩家位置
3. 发布移动事件

**它没有调用 `bus.resolve_tile()` 来触发目标地块的行为。**

与此同时，Flutter 的 `_resolveTileEffect()` 方法实现了全部这 11 种地块效果的**本地模拟**，包括现金扣除/增加、随机卡牌抽取、入狱逻辑等——这些都是 Rust 引擎已具备、但未被执行的重复逻辑。

---

## 二、Flutter 当前非 UI 职责详细清单

### 2.1 已通过 Rust 引擎正确处理的功能 ✅

这些功能通过 `BridgeCommand` → Rust `CommandHandler` → 状态返回，Flutter 只负责展示结果：

| 功能 | Flutter 入口 | Rust 处理器 |
|---|---|---|
| Roll 掷骰 | `_onRoll()` | `handle_roll()` |
| 购买地产 | `_onBuyProperty()` | `handle_buy_property()` |
| 升级地产 | `_onUpgradeProperty()` | `handle_upgrade_property()` |
| 支付租金 | `_autoPayRent()` | `handle_pay_rent()` |
| 交保释金 | `_onPayBail()` | `handle_pay_bail()` |
| 购买卡牌 | `_onBuyCard()` | `handle_buy_card()` |
| 使用卡牌 | `_onUseCard()` | `handle_use_card()` |
| 购买彩票 | `_onBuyLotteryTicket()` | `handle_buy_lottery_ticket()` |
| 抵押/赎回 | `_onMortgage()`/`_onRedeem()` | `handle_mortgage()`/`_handle_redeem()` |
| 结束回合 | `_onEndTurn()` | `handle_end_turn()` |

### 2.2 由 Flutter 本地模拟、应由 Rust 处理的功能 ❌

| 功能 | 位置 | 问题 |
|---|---|---|
| **Income Tax / Luxury Tax 扣除** | `_resolveTileEffect()` → `_deductCash()` | Rust `handle_special_property` 已正确实现 |
| **Free Parking 奖励** | `_resolveTileEffect()` → `_addCash()` | Rust `handle_bank` / `handle_special_property` 已实现 |
| **Chance 卡牌随机抽取** | `_showChanceCardDialog()` | Rust `handle_chance` 已实现：从 deck 抽卡、发布 `core:card_drawn` 事件 |
| **GoToJail 入狱** | `_sendToJail()` | Rust `handle_go_to_jail` 已实现 |
| **Jail 访问** | `_resolveTileEffect()` | Rust `handle_jail` 已实现 |
| **Start 经过** | `_resolveTileEffect()` | Rust `handle_start` 已实现（pass-start bonus 由 `handle_roll` 处理） |
| **CardShop/Lottery 通知** | `_resolveTileEffect()` | Rust `handle_card_shop`/`handle_lottery` 已发布正确事件 |

### 2.3 应该保留在 Flutter 的功能（UI 交互层）✅

- 界面渲染（Board、PlayerPanel、Dice 等）
- 棋子移动动画
- 骰子动画
- 对话框显示（购买确认、升级确认、Chance 卡片、卡牌商店、彩票选号）
- 事件日志展示
- 设置界面
- 联网消息同步

---

## 三、Rust 引擎现状分析

### 3.1 TileBehavior 系统已就绪

文件：`crates/application/src/builtin/tiles.rs`

已注册的行为及其职责：

| 行为 | 类型 ID | 效果 | 需用户交互 |
|---|---|---|---|
| `handle_start` | `core:start` | 仅记录 | 否 |
| `handle_chance` | `core:chance` | 从 deck 抽卡，加入 inventory，发布 `core:card_drawn` | 是（需显示卡牌） |
| `handle_card_shop` | `core:card_shop` | 发布 `core:card_shop_landed` | 是（需显示商店） |
| `handle_lottery` | `core:lottery` | 发布 `core:lottery_landed` | 是（需选号） |
| `handle_bank` | `core:bank` | 加 $200 | 否 |
| `handle_jail` | `core:jail` | 处理访问/减刑期 | 否 |
| `handle_hospital` | `core:hospital` | 处理访问/减刑期 | 否 |
| `handle_go_to_jail` | `core:go_to_jail` | 送玩家入狱 | 否 |
| `handle_special_property` | `core:special_property` | 按 tile_id 扣税/奖励 | 否 |
| `handle_ordinary_property` | `core:ordinary_property` | 自动购买/收租 | 是（应由 Flutter 决定） |
| `handle_extension_property` | `core:extension_property` | 发布 `core:extension_property_landed` | 否 |

### 3.2 触发方法已存在

`EventBus` 已有 `resolve_tile()` 方法：

```rust
pub fn resolve_tile(
    &mut self,
    tile_type: &str,     // 如 "core:chance"
    state: &mut GameState,
    tile_id: &str,       // 如 "chance_1"
    rng: &mut dyn RngService,
)
```

### 3.3 唯一缺失

在 `handle_roll()` 中，移动玩家后（第 291-293 行）**没有调用** `bus.resolve_tile()`。

---

## 四、迁移方案

### 阶段 1：Rust 侧——补充 tile behavior 触发

**目标**：在 `handle_roll()` 移动玩家后，调用 `bus.resolve_tile()` 触发目标地块行为。

**修改文件**：`crates/application/src/builtin/commands.rs`

```rust
// 在 handle_roll() 中，移动玩家并处理 passing start 之后：
// 获取目标地块的类型
let to_tile = &state.board.tiles[to_index];
let tile_kind = &to_tile.kind;
let tile_id = to_tile.id.clone();

// 触发 tile behavior（跳过 ordinary/extension/special property，由 Flutter 端处理购买/升级）
const PROPERTY_TYPES: [&str; 3] = [
    tile_types::ORDINARY_PROPERTY,
    tile_types::EXTENSION_PROPERTY,
    tile_types::SPECIAL_PROPERTY,
];
if !PROPERTY_TYPES.contains(&tile_kind.as_str()) {
    bus.resolve_tile(tile_kind, state, &tile_id, rng);
}
```

**为什么跳过 property 类型**：
- `handle_ordinary_property` 会自动购买可负担的地产，与 Flutter 的购买对话框流程冲突
- Property 购买/升级/租金已由 Flutter `_onRoll()` 中的独立流程处理（检查 owner → 显示购买/升级/支付对话框）

**影响**：
- `core:chance` → `handle_chance` 触发：抽卡、`core:card_drawn` 事件发布
- `core:bank` → `handle_bank` / `handle_special_property` 触发：税款扣除/奖励
- `core:jail` / `core:go_to_jail` → 自动处理入狱
- `core:lottery` → `core:lottery_landed` 事件
- `core:card_shop` → `core:card_shop_landed` 事件

### 阶段 2：Flutter 侧——移除本地模拟代码

**修改文件**：`flutter/lib/main.dart`

#### 2a：删除 `_resolveTileEffect()`

移除整个方法（约 100 行）。所有特殊地块效果改由 Rust 引擎处理。

#### 2b：删除 `_sendToJail()`

移除整个方法。GoToJail 效果由 Rust `handle_go_to_jail` 自动处理。

#### 2c：删除 `_deductCash()` 和 `_addCash()`

这两个方法目前用于：
- Tile 效果模拟（将被 Rust 替代）❌ → 删除
- 支付租金（已通过 Rust `pay_rent` 命令）✅ → 保留
- 支付保释金（已通过 Rust `pay_bail` 命令）✅ → 保留
- 卡牌效果（Chance 卡片的本地模拟）❌ → 删除

分离方案：创建仅用于 UI 同步的 `_updateState(state)` 方法替代 `_deductCash`/`_addCash`。

#### 2d：删除 `_showChanceCardDialog()`

Chance 卡牌由 Rust `handle_chance` 处理，Flutter 通过 `EventDispatcher` 收到 `core:card_drawn` 事件后显示卡牌内容。

需要更新 `EventDispatcher` 处理 `core:card_drawn`：
```dart
case 'core:card_drawn':
    final cardId = event['card_id'] as String? ?? '';
    final effectKey = event['effect_key'] as String? ?? '';
    cb.showChanceCard?.call();  // ✅ 现在可以在正确时机触发
    return 'Drew card: $cardId';
```

#### 2e：删除 `_buildInitialState()`

当 Rust 引擎可用时，全部初始化走 `_initGameFromRust()` 调用 Rust `create_game`。

### 阶段 3：Flutter 侧——更新事件处理

1. **更新 `EventCallbacks` / `EventDispatcher`**：
   - `core:income_tax_paid` → 显示 "已缴所得税 $200" 日志
   - `core:luxury_tax_paid` → 显示 "已缴奢侈品税 $100" 日志
   - `core:free_parking_bonus` → 显示 "免费停车奖励 $200" 日志
   - `core:player_sent_to_jail` → 显示 "入狱！" 日志
   - `core:card_drawn` → 显示卡牌对话框（从事件中提取卡牌名称/效果）
   - `core:card_shop_landed` → 显示卡牌商店对话框
   - `core:lottery_landed` → 显示彩票对话框

2. **更新 `_onRoll()`**：
   - 移除 `_resolveTileEffect()` 调用
   - 移除 `_syncCurrentState(eventType: 'TileEffect')`
   - 保留购买/升级对话框逻辑（基于 Rust 返回的 state 判断）
   - Rust 返回的 state 已包含所有 tile 效果（现金变化、位置变化等），Flutter 直接应用

### 阶段 4：清理与验证

1. 验证所有 tile 效果事件在 `EventDispatcher` 中有对应处理
2. 验证 `_onRoll()` 中 `_isAnimating` 控制流正确
3. 运行 `flutter analyze` 无错误
4. 运行 Rust 测试确保 `handle_roll` + `resolve_tile` 正确

---

## 五、迁移后架构

```
掷骰前: Flutter                           Rust
  ┌──────────┐   BridgeCommand.roll()    ┌──────────┐
  │ UI状态    │ ──────────────────────→  │handle_roll│
  │ 准备      │                          │   · 生成骰子│
  └──────────┘                          │   · 移动玩家│
                                         │   · passing│
                                         │     start  │
                                         │   · resolve│
                                         │     _tile()│ ← 新增
                                         │     ├─ 抽税 │
                                         │     ├─ 抽卡 │
                                         │     ├─ 入狱 │
                                         │     └─ 事件 │
                                         └─────┬─────┘
                                               │ BridgeResponse
                                               │ { events, state }
                                               ▼
掷骰后: Flutter                           Rust
  ┌──────────────────┐
  │ 骰子动画          │
  │ 棋子移动动画       │
  │ 应用 state        │ ← 直接使用 Rust 返回的状态，不再本地模拟
  │ EventDispatcher   │ ← 处理 events：显示 Chance/CardShop/Lottery 等
  │ 购买/升级对话框    │ ← 基于 state 中的 property.owner 判断
  │ 支付租金/保释金    │ ← 通过 BridgeCommand 发送
  └──────────────────┘
```

## 六、收益

| 指标 | 当前 | 迁移后 |
|---|---|---|
| Flutter `main.dart` 行数 | ~3166 行 | 预计减少 200-300 行 |
| 重复逻辑 | `_resolveTileEffect` 100+ 行 | 完全消除 |
| Rust 代码利用率 | TileBehavior 已注册但从未执行 | 全部执行 |
| 游戏规则一致性 | Flutter 和 Rust 两套实现，可能不一致 | 单一来源（Rust）|
| 新地图适配 | 需同步修改 Flutter 的 tile 类型判断 | 自动适配（Rust 引擎处理）|
