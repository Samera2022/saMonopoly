# 事件管线重构方案

## 现状问题

1. Flutter 只读取 `response.event[0]`，其余 30+ 事件被丢弃
2. EventBus 的 subscribers 在 FFI 路径下未注册
3. 状态变更和数据变更展示混在一起 —— `response.state` 直接替代了事件的作用
4. 事件发布后没有任何消费者

## 新架构目标

1. Flutter 遍历并处理 `response.allEvents` 中的每一个事件
2. 事件成为 Flutter 端知道"刚刚发生了什么"的主要手段
3. 注册 EventBus subscribers 并确保在 FFI 路径下也生效
4. 按事件类型划分职责，分离 UI 反应和状态更新

---

## 架构设计

### 整体数据流

```
Flutter
  │  发送 command + state
  ▼
Rust execute_json
  │
  ├─ 创建 EventBus + 注册 handlers
  ├─ bus.execute_command → handle_xxx
  │   ├─ 修改 state（位置、现金等）
  │   └─ publish_custom events（dice_rolled, player_moved, ...）
  │
  ├─ bus.drain_custom_events() → events[]
  ├─ flatten + collect → BridgeResponse { events[], state }
  │
  ▼
Flutter onResponse(response)
  │
  ├─ response.state → _currentState（最终状态快照，作为 ground truth）
  │
  └─ response.allEvents → EventDispatcher
       ├─ core:dice_rolled          → 显示骰子动画
       ├─ core:player_moved         → 棋子移动动画
       ├─ core:property_bought      → 日志 + UI 刷新
       ├─ core:rent_paid            → 扣钱动画 + 日志
       ├─ core:player_sent_to_jail  → 送监狱动画 + 日志
       ├─ core:card_drawn           → 弹出机会卡对话框
       ├─ core:card_shop_landed     → 弹出卡牌商店对话框
       ├─ core:lottery_landed       → 弹出彩票对话框
       ├─ core:command_rejected     → 日志 + 错误提示
       ├─ core:error                → 日志 + 错误提示
       ├─ core:command_accepted     → 日志确认
       ├─ core:game_won             → 胜利画面 + 游戏结束
       └─ ...其余事件               → 日志记录
```

---

### 模块划分

#### 1. Rust 侧：EventBus 正确配置 subscribers

**改动文件**: [`crates/application/src/bridge.rs`](crates/application/src/bridge.rs:154)

在 `execute_json()` 中不仅要注册命令处理器和 tile behaviors，还要注册 subscribers：

```rust
pub fn execute_json(input: &str) -> Result<String, String> {
    let request: BridgeRequest = serde_json::from_str(input).map_err(|err| err.to_string())?;
    let mut bus = EventBus::new();
    register_core_commands(&mut bus.command_handlers);
    register_core_tile_behaviors(&mut bus.tile_behaviors);
    register_core_subscribers(&mut bus);  // ← 新增：注册订阅者
    let response = Self::execute(request, &mut bus);
    serde_json::to_string_pretty(&response).map_err(|err| err.to_string())
}
```

新增 `register_core_subscribers()`，注册：
- `EventLogger` — 记录所有事件日志
- `DiceStats` — 骰子统计插件
- `TreasureHunt` — 宝藏插件

#### 2. Rust 侧：events 中附加 `_state_diff` 字段

**改动文件**: [`crates/application/src/builtin/commands.rs`](crates/application/src/builtin/commands.rs)

在每个 `publish_custom` 事件的 payload 中添加 `_state_diff` 字段，描述此事件导致的状态变更。例如：

```json
{
  "event_type": "core:dice_rolled",
  "dice1": 3,
  "dice2": 4,
  "is_seven": false,
  "consecutive": 0,
  "_state_diff": {
    "player_id": "player_0",
    "position": "prop_3",
    "cash": -200,
    "passed_start": true
  }
}
```

```json
{
  "event_type": "core:rent_paid",
  "player_id": "player_1",
  "tile_id": "prop_3",
  "amount": 20,
  "_state_diff": {
    "from_player": "player_1",
    "from_player_cash": -20,
    "to_player": "player_0",
    "to_player_cash": 20
  }
}
```

#### 3. Flutter 侧：EventDispatcher

**新增文件**: [`flutter/lib/event_dispatcher.dart`](flutter/lib/event_dispatcher.dart)

```dart
class EventDispatcher {
  /// 处理 BridgeResponse 中的所有事件
  /// 返回聚合的日志消息列表
  static List<String> dispatch({
    required BridgeResponse response,
    required GameStateRef stateRef,    // 可读写 currentState
    required EventLog log,             // 添加日志
    required Navigation nav,           // 弹出对话框
    required AnimationCtrl anim,       // 控制动画
  }) {
    final logs = <String>[];
    for (final event in response.allEvents) {
      final type = event['event_type'] as String? ?? '';
      final handler = _handlers[type];
      if (handler != null) {
        final logMsg = handler(event, stateRef, nav, anim);
        if (logMsg != null) logs.add(logMsg);
      }
    }
    return logs;
  }
}
```

事件处理器示例：

```dart
static final Map<String, EventHandler> _handlers = {
  'core:dice_rolled': (e, s, n, a) {
    final d1 = e['dice1'] as int? ?? 0;
    final d2 = e['dice2'] as int? ?? 0;
    a.showDiceAnimation(d1, d2);
    return 'Rolled $d1 + $d2 = ${d1 + d2}${_jailMsg(e)}';
  },

  'core:player_moved': (e, s, n, a) {
    final pid = e['player_id'] as String? ?? '';
    final toTile = e['to_tile'] as String? ?? '';
    a.moveToken(pid, toTile);
    return null;
  },

  'core:rent_paid': (e, s, n, a) {
    final amount = e['amount'] as int? ?? 0;
    return 'Paid rent: \$$amount';
  },

  'core:property_bought': (e, s, n, a) {
    final tileId = e['tile_id'] as String? ?? '';
    return 'Bought $tileId';
  },

  'core:player_sent_to_jail': (e, s, n, a) {
    return 'Go to Jail!';
  },

  'core:card_drawn': (e, s, n, a) {
    final cardId = e['card_id'] as String? ?? '';
    n.showCardDialog(cardId);
    return 'Drew card: $cardId';
  },

  'core:card_shop_landed': (e, s, n, a) {
    n.showCardShopDialog();
    return 'Landed on Card Shop';
  },

  'core:lottery_landed': (e, s, n, a) {
    n.showLotteryDialog();
    return 'Landed on Lottery';
  },

  'core:game_won': (e, s, n, a) {
    final winner = e['winner_id'] as String? ?? '';
    n.showVictoryScreen(winner);
    return 'Game won by $winner!';
  },

  'core:command_rejected': (e, s, n, a) {
    final reason = e['reason'] as String? ?? 'unknown';
    return 'Rejected: $reason';
  },

  'core:error': (e, s, n, a) {
    final reason = e['reason'] as String? ?? 'unknown';
    return 'Error: $reason';
  },

  'core:command_accepted': (e, s, n, a) {
    return null;  // 不需要日志，其他事件已经包含了足够信息
  },
};
```

**事件全覆盖清单**：

| 事件 | 行为 |
|------|------|
| `core:dice_rolled` | 骰子动画 + 日志 |
| `core:player_moved` | 棋子移动动画 |
| `core:player_sent_to_jail` | 动画 + 日志 |
| `core:player_released_from_jail` | 动画 + 日志 |
| `core:player_released_from_hospital` | 动画 + 日志 |
| `core:property_bought` | UI 刷新 + 日志 |
| `core:property_upgraded` | UI 刷新 + 日志 |
| `core:property_mortgaged` | UI 刷新 + 日志 |
| `core:property_redeemed` | UI 刷新 + 日志 |
| `core:rent_paid` | 扣款动画 + 日志 |
| `core:bail_paid` | 日志 |
| `core:card_drawn` | 弹出机会卡对话框 + 日志 |
| `core:card_bought` | 日志 |
| `core:card_used` | 日志 |
| `core:card_consumed` | 日志 |
| `core:card_shop_landed` | 弹出卡牌商店对话框 |
| `core:lottery_landed` | 弹出彩票对话框 |
| `core:lottery_ticket_bought` | 日志 |
| `core:lottery_draw_result` | 弹出开奖结果对话框 |
| `core:turn_advanced` | 回合切换 UI |
| `core:game_won` | 胜利画面 |
| `core:player_bankrupt` | 破产动画 + 日志 |
| `core:player_eliminated` | 玩家移除动画 |
| `core:auction_started` | 弹出拍卖对话框 |
| `core:bid_placed` | 日志 |
| `core:trade_proposed` | 日志 |
| `core:income_tax_paid` | 扣款动画 + 日志 |
| `core:luxury_tax_paid` | 扣款动画 + 日志 |
| `core:free_parking_bonus` | 奖励动画 + 日志 |
| `core:bank_bonus` | 奖励动画 + 日志 |
| `core:extension_property_landed` | 日志 |
| `core:config_loaded` | 日志 |
| `core:config_updated` | 日志 |
| `core:shares_bought` | 日志 |
| `core:shares_sold` | 日志 |
| `core:stock_market_tick` | 日志 |
| `core:command_accepted` | 忽略（冗余） |
| `core:command_rejected` | 错误日志 |
| `core:error` | 错误日志 |
| `core:landed_on_tile` | 日志 |

#### 4. Flutter 侧：移除 main.dart 中的内联事件处理

**改动文件**: [`flutter/lib/main.dart`](flutter/lib/main.dart)

将 `_onRoll()`、`_onBuyProperty()`、`_onEndTurn()` 等方法中的内联事件处理逻辑替换为统一的 EventDispatcher：

```dart
Future<void> _onRoll() async {
  _broadcastRollStart();
  setState(() {
    _isRollingDice = true;
    _isAnimating = true;
  });

  final response = await _bridgeClient.executeCommand(
    command: BridgeCommand.roll(),
    currentState: _currentState,
  );

  // 核心变更：使用 EventDispatcher 处理全部事件
  final logs = EventDispatcher.dispatch(
    response: response,
    stateRef: _currentStateRef(),
    log: _addLog,
    nav: _navActions(),
    anim: _animationCtrl(),
  );

  // 应用最终状态
  setState(() {
    _currentState = response.state;
    _gameState = _buildGameState(
      response.state,
      lastEvent: logs.isNotEmpty ? logs.last : '',
    );
    _isRollingDice = false;
    _isAnimating = false;
  });
}
```

---

### 迁移步骤

#### Phase 1：Flutter 侧 EventDispatcher（独立可测试）

1. 创建 [`flutter/lib/event_dispatcher.dart`](flutter/lib/event_dispatcher.dart)
2. 为前 10 个核心事件实现 handler
3. 在 `_onRoll` 中集成 EventDispatcher
4. 验证骰子、移动、监狱等核心流程正常

#### Phase 2：Rust 侧 Subscriber 注册

1. 在 [`crates/application/src/bridge.rs`](crates/application/src/bridge.rs) 的 `execute_json` 中注册 subscribers
2. 在 [`crates/application/src/startup.rs`](crates/application/src/startup.rs) 中提取 `register_core_subscribers()` 函数

#### Phase 3：全面覆盖

1. 为所有 30+ 事件添加 handler
2. 移除 main.dart 中冗余的内联事件判断
3. 测试所有命令路径

#### Phase 4（可选）：_state_diff 字段

1. 在 Rust 事件中添加 `_state_diff` 字段
2. Flutter 端可利用它做精细化的 UI 动画（如现金变动动画）

---

### 不变的原则

1. **`response.state` 仍然是 ground truth** — EventDispatcher 不使用 state diff 来构造状态，而是使用 `response.state` 做最终更新
2. **事件是"通知"而非"指令"** — 事件告诉 Flutter 刚刚发生了什么，Flutter 据此驱动 UI 反应
3. **向后兼容** — 所有现有逻辑在新架构下应继续工作
