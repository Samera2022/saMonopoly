# 仿真层 vs Rust 后端差异分析报告

> 基于 commit `1c62e2c1a08c5b8b5b02fc52a24b0015ac8b8758`（仿真层删除前最后一个版本）

## 一、概述

仿真层（`_simulateEngineResponse` in `flutter/lib/bridge_client.dart`）是一个 **390 行的完整游戏引擎**，实现了所有 17 个命令的处理逻辑。Rust 后端（`crates/application/src/builtin/`）目前只实现了 3 个命令处理器和 4 个 tile behavior。

仿真层从未被真正替换为 Rust 调用——旧代码尝试调 Rust 失败后永远回退到仿真层。

---

## 二、命令处理器差距分析

### 2.1 Rust 已实现（3个）

| 命令 | Rust 注册名 | 事件发布 | 说明 |
|------|------------|---------|------|
| Roll | `core:command:roll` | `core:dice_rolled`, `core:player_moved`, `core:player_sent_to_jail`, `core:command_accepted/rejected` | 需要 `RollCommand { player_id }` |
| BuyProperty | `core:command:buy_property` | `core:property_bought`, `core:command_rejected` | 需要 `BuyPropertyCommand { player_id, tile_id }` |
| EndTurn | `core:command:end_turn` | `core:turn_advanced`, `core:player_bankrupt/eliminated` | 需要 `EndTurnCommand { player_id }` |

### 2.2 仿真层实现但 Rust 缺失（14个）

#### UpgradeProperty
- **仿真层行为**：查找 property，计算升级费用（`base_price * (1 + level) / 3`），扣款，递增 `upgrade_level`，返回 `CommandAccepted`
- **Flutter 期望事件**：`event_type == 'CommandAccepted'` 或默认
- **Rust 状态**：需要 `UpgradePropertyCommand { player_id, tile_id }`
- **注册名**：`core:command:upgrade_property`
- **事件名**：`core:property_upgraded`

#### PayRent
- **仿真层行为**：返回事件包含 `tile_id` 和固定 `amount: 50`（简化版）
- **Flutter 期望事件**：`event` 含 `tile_id`、`amount`
- **Rust 状态**：需要 `PayRentCommand { player_id, tile_id }`
- **注意**：Rust 的 `handle_ordinary_property` 已自动处理租金。此命令可能用于手动支付。

#### PayBail
- **仿真层行为**：读取 `jail_turns`，计算 `paidAmount = jailTurns * 50`，扣款，清空 `jail_turns`，递增 `bail_abuse_count`，返回 `BailPaid`
- **Flutter 期望事件**：`event_type == 'BailPaid'`，含 `player_id`、`amount`
- **Rust 状态**：需要 `{ player_id }` 或简单 `{}`
- **注册名**：`core:command:pay_bail`
- **事件名**：`core:bail_paid`

#### BuyCard
- **仿真层行为**：接收 `card_id`、`price`，扣款，添加 `card_id` 到 `owned_cards`
- **Flutter 期望事件**：`event_type == 'CardBought'` 或默认，含 `card_id`、`price`
- **Rust 状态**：需要 `{ player_id, card_id, price }`
- **注册名**：`core:command:buy_card`
- **事件名**：`core:card_bought`

#### UseCard
- **仿真层行为**：接收 `card_id`，从 `owned_cards` 移除
- **Flutter 期望事件**：`event_type == 'CardUsed'`，含 `player_id`、`card_id`
- **Rust 状态**：需要 `{ player_id, card_id }`
- **注册名**：`core:command:use_card`
- **事件名**：`core:card_used`

#### BuyLotteryTicket
- **仿真层行为**：接收 `number`，扣款 $50，返回 `LotteryTicketBought`
- **Flutter 期望事件**：`event_type == 'LotteryTicketBought'`，含 `player_id`、`number`、`ticket_price`
- **Rust 状态**：需要 `{ player_id, number }`
- **注意**：彩票系统需要 `GameState.lottery_state` 字段

#### Mortgage
- **仿真层行为**：返回事件含 `tile_id`、`amount: 100`
- **Flutter 期望事件**：含 `tile_id`、`amount`
- **Rust 状态**：需要 `{ player_id, tile_id }`，设置 `property.is_mortgaged = true`
- **注册名**：`core:command:mortgage`

#### Redeem
- **仿真层行为**：返回事件含 `tile_id`、`amount: 110`
- **Flutter 期望事件**：含 `tile_id`、`amount`
- **Rust 状态**：需要 `{ player_id, tile_id }`，设置 `property.is_mortgaged = false`
- **注册名**：`core:command:redeem`

#### Auction / Bid
- **仿真层行为**：Auction 记录 `tile_id`、`starting_bid`；Bid 记录 `player_id`、`amount`
- **Flutter 期望事件**：Auction 含 `tile_id`、`starting_bid`；Bid 含 `player_id`、`amount`
- **Rust 状态**：需要 `GameState.active_auction` 字段
- **注册名**：`core:command:auction`、`core:command:bid`

#### Trade
- **仿真层行为**：记录 `from_player_id`、`to_player_id`
- **Flutter 期望事件**：含双方 player_id
- **Rust 状态**：需要完整的交易逻辑

#### SellShares
- **仿真层行为**：记录 `player_id`、`shares`
- **Flutter 期望事件**：含 `player_id`、`shares`
- **Rust 状态**：需要 `GameState.stock_market`

#### ConfigGet / ConfigSet
- **仿真层行为**：返回 `ConfigLoaded` 或 `ConfigUpdated`
- **Flutter 期望事件**：对应 event_type
- **Rust 状态**：配置系统

---

## 三、Tile Behavior 差距分析

### 3.1 Rust 已实现（4个）

| Tile 类型 | Rust 注册名 | 行为 |
|-----------|------------|------|
| Start | `core:start` | 发布 `core:command_accepted` |
| OrdinaryProperty | `core:ordinary_property` | 自动购买（如可负担）、租金支付、发布 `core:property_bought`、`core:rent_paid` |
| Chance | `core:chance` | 从牌堆抽卡，添加至玩家库存，发布 `core:card_drawn` |
| Jail | `core:jail` | 递减 jail_turns，释放时发布 `core:player_released_from_jail` |

### 3.2 仿真层实现但 Rust 缺失（7个）

#### SpecialProperty（Income Tax / Luxury Tax / Free Parking）
- **仿真层行为（`_resolveTileEffect`）**：
  - `tax_1`（Income Tax）：扣 $200
  - `tax_2`（Luxury Tax）：扣 $100
  - `park`（Free Parking）：加 $200
- **Flutter 期望**：直接修改 `_currentState` 中的 player cash
- **Rust 方案**：添加 `core:special_property` tile behavior，根据 tile_id 发布不同事件

#### GoToJail
- **仿真层行为（`_resolveTileEffect`）**：设置 `position = 'jail'`、`jail_turns = 3`
- **Flutter 期望**：state 中 player 的 position 和 jail_turns 被修改
- **Rust 方案**：添加 `core:go_to_jail` tile behavior

#### CardShop
- **仿真层行为（`_resolveTileEffect`）**：弹出 CardShop 对话框
- **Flutter 期望**：`_showCardShopDialog()` 被调用
- **注意**：这是纯 UI 行为，Rust 只需发布事件通知 Flutter 弹窗

#### Lottery
- **仿真层行为（`_resolveTileEffect`）**：弹出 Lottery 对话框
- **Flutter 期望**：`_showLotteryPickerDialog()` 被调用
- **注意**：同上，Rust 只需发布事件

#### Hospital
- **仿真层行为（`_onRoll` 中的 CommandRejected）**：如果 `hospital_turns > 0`，跳过回合
- **Rust 状态**：`handle_roll` 中已有 jail/hospital 检查逻辑
- **注意**：Rust 的 `handle_roll` 检查 `is_in_jail() || is_in_hospital()` 并发布 `core:command_accepted`，但 Flutter 期望 `CommandRejected` + `reason: 'player_in_hospital'`

#### ExtensionProperty（Utilities）
- **仿真层行为**：无特殊处理（通过 `_buildInitialState` 创建）
- **Rust 状态**：未注册 `core:extension_property` tile behavior

#### Bank（Free Parking 等）
- **仿真层行为**：在 `_resolveTileEffect` 中处理
- **Rust 状态**：未注册 `core:bank` tile behavior

---

## 四、事件格式差距

### 4.1 Roll 事件流对比

| 步骤 | 仿真层（一个扁平事件） | Rust（多个事件） |
|------|---------------------|----------------|
| 掷骰 | `{event_type: DiceRolled, dice1: 3, dice2: 4, is_seven: false, consecutive: 0, player_id: "player_0", to_tile: "prop_1"}` | `core:dice_rolled` + `core:player_moved` + `core:command_accepted` |
| 医院 | `{event_type: CommandRejected, reason: "player_in_hospital"}` | `core:command_accepted`（无特殊 reason） |
| 监禁释放 | `{event_type: PlayerReleasedFromJail, player_id: "player_0"}` | `core:player_released_from_jail` |
| 三次 doubles | 无 | `core:player_sent_to_jail` |

### 4.2 Flutter 代码期望的事件格式

Flutter 的 `_onRoll` 期望一个**扁平事件**：
```dart
final eventType = response.event['event_type'];  // "DiceRolled" / "CommandRejected" / "PlayerReleasedFromJail"
final dice1 = response.event['dice1'];
final dice2 = response.event['dice2'];
final reason = response.event['reason'];  // "player_in_hospital"
final pluginMsg = response.event['_plugin_msg'];
final treasureMsg = response.event['_plugin_msg_treasure'];
```

但 Rust 返回的是 `{events: [{Custom: {event_type, source, payload: {...}, timestamp}]}`，payload 是嵌套的。

---

## 五、插件兼容性

### DiceStats 插件
- **仿真层**：在 `Roll` 事件中添加 `_plugin_msg` 字段
- **Rust 端**：`example_plugins.rs` 中 `register_dice_stats` 通过 EventBus subscriber 实现
- **兼容性**：Rust 端发布的事件需要通过 `executeCommand` 响应传递回 Flutter，确保 `_plugin_msg` 在扁平化后的 event 中

### TreasureHunt 插件
- **仿真层**：在 `Roll` 事件中添加 `_plugin_msg_treasure` 字段
- **Rust 端**：`example_plugins.rs` 中 `register_treasure_hunt`
- **兼容性**：同上

关键点：`PluginState().diceStatsEnabled` / `treasureHuntEnabled` 需要在 Rust 端也有对应的启用/禁用机制。

---

## 六、联机功能兼容性

### 当前网络同步流程
1. `_onRoll` → `_broadcastRollStart()`（通知所有客户端骰子动画开始）
2. Flutter 执行 `executeCommand`（仿真层 / Rust）
3. `_broadcastRollEnd(dice1, dice2, response)`（广播结果和 state）
4. `_broadcastMoveStart(activeIdx, movementPath)`（广播移动路径）
5. 每个客户端执行动画
6. `_broadcastMoveEnd()`（同步最终 state）

### 替换为 Rust 后的影响
- `executeCommand` 返回的 state 需要包含所有游戏逻辑变更
- Rust 返回的 `state`（GameState JSON）直接作为新 state 使用
- 事件格式需要保持 Flutter side 的兼容性（扁平 event_type、dice1/dice2 等）
- 或修改 Flutter 的 `_onRoll` 适配 Rust 的多事件格式

---

## 七、差距总结

| 类别 | 仿真层 | Rust 已实现 | 差距 |
|------|--------|------------|------|
| 命令处理器 | 17个 | 3个 | 14个缺失 |
| Tile Behavior | 通过 `_resolveTileEffect` 处理 8种 | 4种 | 7种缺失 |
| 事件格式 | 扁平单事件 | 嵌套多事件 | 格式完全不同 |
| 状态管理 | 直接修改 JSON | 通过 Rust 类型系统 | 需要格式转换 |
| 插件 | 仿真层内嵌 | EventBus subscriber | 需要桥接 plugin_msg |
| 联机 | 基于 JSON state 同步 | 需要保持一致 | 兼容 |

---

## 八、建议实施顺序

1. **优先**：添加缺失的命令处理器（UpgradeProperty、PayBail、BuyCard、UseCard、Mortgage、Redeem）
2. **优先**：添加缺失的 Tile Behavior（GoToJail、CardShop、Lottery、Hospital、SpecialProperty）
3. **核心**：修复 BridgeRequest/BridgeResponse 格式对齐（command_type 映射、payload 展开）
4. **插件**：确保 DiceStats/TreasureHunt 的事件通过 Bridge 传递到 Flutter
5. **优化**：实现 Auction/Bid/Trade/SellShares（需要完整的状态机）
