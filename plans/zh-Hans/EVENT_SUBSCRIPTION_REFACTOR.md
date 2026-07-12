# EventDispatcher 事件订阅重构方案

## 当前问题

[`_onRoll()`](flutter/lib/main.dart:1176) 当前使用两个不同的 `EventCallbacks`：

1. `_rollAnimationCallbacks()` — 首次分发事件（仅日志，无对话框）
2. 动画后的重分派 hack — 用无操作日志重新分发全部事件以触发对话框

这种"重分派全部事件"的方式是 hack，不是干净的订阅模式。

## 目标

改为**原版事件订阅模式**：`EventDispatcher` 将每个事件分发给已订阅的处理器，订阅者在初始化时注册，对事件类型做出反应。对话框是事件的效果，而不是回调参数。

---

## 设计方案

### 核心变更：`EventDispatcher` 改为全局单例订阅器

```
┌─────────────────────────────────────────────────────────────────────┐
│   EventDispatcher (全局单例)                                        │
│                                                                     │
│   subscribe('core:card_shop_landed', handler)  ← 在 initState 注册  │
│   subscribe('core:lottery_landed', handler)                         │
│   subscribe('core:auction_started', handler)                        │
│                                                                     │
│   dispatch(response, options?) → DispatchResult                     │
│     ├── 遍历 events                                                 │
│     ├── 对每个 event → 调用所有已订阅的 handler                      │
│     └── 同时收集日志、骰子值等                                       │
└─────────────────────────────────────────────────────────────────────┘
```

### 文件改动

#### 1. [`flutter/lib/event_dispatcher.dart`](flutter/lib/event_dispatcher.dart)

```dart
/// 全局事件订阅器
class EventDispatcher {
  static final Map<String, List<EventSubscriber>> _subscribers = {};

  /// 订阅一个事件类型。handler 接收事件 payload。
  static void subscribe(String eventType, EventSubscriber subscriber) {
    _subscribers.putIfAbsent(eventType, () => []).add(subscriber);
  }

  /// 取消订阅
  static void unsubscribe(String eventType, EventSubscriber subscriber) {
    _subscribers[eventType]?.remove(subscriber);
  }

  /// 分发事件。返回 DispatchResult（仅含日志、骰子值等元信息）。
  /// UI 效果由已注册的订阅者自动触发。
  static DispatchResult dispatch({
    required BridgeResponse response,
    bool deferUiActions = false,
  }) {
    final logs = <String>[];
    bool hadError = false;
    int dice1 = 0, dice2 = 0;
    bool isJailRoll = false;
    final pendingUi = <UiAction>[];

    for (final event in response.allEvents) {
      final type = event['event_type'] as String? ?? '';
      
      // 1. 生成日志消息（内联 handler）
      final log = _handleLog(type, event);
      if (log != null) {
        logs.add(log);
      }

      // 2. 调用已订阅的 handler
      final handlers = _subscribers[type];
      if (handlers != null) {
        for (final sub in handlers) {
          if (deferUiActions && sub.isUiAction) {
            pendingUi.add(UiAction(sub, event));
          } else {
            sub.handler(event);
          }
        }
      }

      // 3. 提取元信息
      if (type == 'core:dice_rolled') {
        dice1 = (event['dice1'] as num?)?.toInt() ?? 0;
        dice2 = (event['dice2'] as num?)?.toInt() ?? 0;
        isJailRoll = event['consecutive'] == null;
      }
      if (type == 'core:player_released_from_jail') {
        isJailRoll = true;
      }
    }

    return DispatchResult(
      logs: logs, hadError: hadError,
      dice1: dice1, dice2: dice2, isJailRoll: isJailRoll,
      pendingUiActions: pendingUi,
    );
  }
}

/// 事件订阅者：一个 handler + 标记是否为 UI 动作（需要 defer）
class EventSubscriber {
  final void Function(Map<String, dynamic> event) handler;
  final bool isUiAction; // true = 对话框触发的动作，滚动动画时可 defer
  
  const EventSubscriber(this.handler, {this.isUiAction = false});
}

/// Deferred UI 动作
class UiAction {
  final EventSubscriber subscriber;
  final Map<String, dynamic> event;
  const UiAction(this.subscriber, this.event);
  
  void execute() => subscriber.handler(event);
}
```

#### 2. [`flutter/lib/main.dart`](flutter/lib/main.dart)

**在 `initState()` 中注册订阅：**
```dart
@override
void initState() {
  super.initState();
  // ... 现有初始化代码 ...
  
  // ★ 注册事件订阅（一次性）
  _registerEventSubscriptions();
}

void _registerEventSubscriptions() {
  EventDispatcher.subscribe(
    'core:card_shop_landed',
    EventSubscriber((event) => _showCardShopDialog(), isUiAction: true),
  );
  EventDispatcher.subscribe(
    'core:lottery_landed',
    EventSubscriber((event) => _showLotteryPickerDialog(), isUiAction: true),
  );
  EventDispatcher.subscribe(
    'core:auction_started',
    EventSubscriber((event) {
      final tid = event['tile_id'] as String? ?? '';
      final bid = (event['starting_bid'] as num?)?.toInt() ?? 0;
      _showAuctionDialog(tid, bid);
    }, isUiAction: true),
  );
  EventDispatcher.subscribe(
    'core:card_drawn',
    EventSubscriber((event) {
      // Chance card drawn — log is handled by EventDispatcher
      final cardId = event['card_id'] as String? ?? '';
      _addLog('Drew card: $cardId');
      // Card content shown by dialog if needed
    }),
  );
}
```

**在 `_onRoll()` 中：**
```dart
Future<void> _onRoll() async {
  // ... 掷骰、获取 response ...
  
  // 分发事件：deferUiActions=true 表示延迟 UI 动作
  final dispatchResult = EventDispatcher.dispatch(
    response: response,
    deferUiActions: true,  // UI 对话框将在动画后触发
  );
  
  // ... 骰子动画、棋子移动动画 ...
  
  // 动画完成后，触发被 defer 的 UI 动作
  for (final uiAction in dispatchResult.pendingUiActions) {
    uiAction.execute();
  }
  
  // ... 购买/升级/租金逻辑 ...
}
```

**移除的内容：**
- 移除 `EventCallbacks` 类（不再需要回调参数模式）
- 移除 `_defaultCallbacks()` 方法
- 移除 `_rollAnimationCallbacks()` 方法
- 移除第 1316-1327 行的重分派 hack
- 所有非 roll 操作（buy, end_turn 等）直接调用 `EventDispatcher.dispatch(response)`，UI 动作立即触发

#### 3. 非 roll 操作调用方式简化

```dart
// 之前:
final r = EventDispatcher.dispatch(
  response: response,
  callbacks: _defaultCallbacks(),
);

// 之后:
final r = EventDispatcher.dispatch(response: response);
// UI 动作由已注册的订阅者自动触发
```

---

## 收益

| 对比 | 当前模式 | 订阅模式 |
|------|---------|---------|
| 对话框触发 | 通过 `EventCallbacks` 参数传递 | 事件订阅者自动触发 |
| 滚动动画处理 | 两套 callbacks + 重分派 hack | `deferUiActions` 标志控制 |
| 新增事件类型 | 修改 `EventCallbacks` + `_handle` + 调用处 | 只需 `subscribe()` |
| 代码复杂度 | 3 个类耦合（Dispatcher + Callbacks + main.dart） | 1 个单例 Dispatcher |
| 非 roll 操作 | 需传 `_defaultCallbacks()` | 自动触发，无需参数 |

---

## 迁移步骤

1. **修改 [`EventDispatcher`](flutter/lib/event_dispatcher.dart)** — 添加 `subscribe()`/`dispatch()` 新接口，保留旧 `EventCallbacks` 兼容（逐步迁移）
2. **在 [`_GameScreenState.initState()`](flutter/lib/main.dart:356) 注册订阅** — 一次性注册所有 UI 事件订阅
3. **修改 [`_onRoll()`](flutter/lib/main.dart:1176)** — 使用 `deferUiActions: true` 并移除重分派 hack
4. **简化非 roll 操作** — 去除 `_defaultCallbacks()` 参数传递
5. **清理** — 移除 `EventCallbacks` 类（或保留为仅日志回调的简单接口）
