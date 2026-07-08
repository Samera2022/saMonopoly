# Roll 按钮闪烁问题修复方案

## 问题描述

联机模式下，玩家 Roll 后（Roll按钮被禁用），等到骰子显示值之后，Roll 按钮会短暂显示可用，然后才被禁用。

## 根因分析

经过代码追踪，问题涉及以下文件：

[`flutter/lib/main.dart`](flutter/lib/main.dart)

### 按钮状态逻辑

Roll 按钮的可用性由 [`_buildActionButtons`](flutter/lib/main.dart:2434) 中的 `canRoll` 决定：

```dart
final canAct = _isLocalPlayersTurn && !_isAnimating;
final canRoll = canAct && _rollsRemainingThisTurn > 0;
```

即：按钮可用 ↔ 是本地玩家的回合 **且** 没有动画正在播放 **且** 还有剩余 Roll 次数。

### 联机消息流程

在联机模式下，Roll 事件通过两阶段协议同步：

```
掷骰方                      接收方（其他客户端）
  │                            │
  ├─ _broadcastRollStart() ───►  _handleRemoteRollStart()
  │                            │    _isAnimating = true     ✅ 按钮禁用
  │                            │    _runRemoteDiceAnimation()
  │                            │
  ├─ _broadcastRollEnd() ─────►  _handleRemoteRollEnd()
  │                            │    _isAnimating = false    ❌ 按钮误启用
  │                            │
  ├─ _broadcastMoveStart() ───►  _handleRemoteMoveStart()
  │                            │    (未设置 _isAnimating)    ❌ 按钮保持启用
  │                            │    循环播放移动动画...
  │                            │
  ├─ _broadcastMoveEnd() ─────►  _handleRemoteMoveEnd()
  │                            │    _isAnimating = false    ✅
```

### 两个 Bug

**Bug 1**：[`_handleRemoteRollEnd`](flutter/lib/main.dart:648) 无条件设置了 `_isAnimating = false`，导致骰子显示后按钮短暂可用。但此时移动动画可能还未开始。

**Bug 2**：[`_handleRemoteMoveStart`](flutter/lib/main.dart:679) 没有设置 `_isAnimating = true`，导致移动动画期间按钮保持可用状态。

### 额外问题：消息回环

当客户端是掷骰方时：

1. 客户端执行 `_onRoll()` → `_broadcastRollEnd()` → 发送给主机
2. 主机接收到 → [`_onNetworkMessage`](flutter/lib/main.dart:469) 中 `isHost` 分支 → 调用 `_handleRemoteRollEnd` → **然后 `_networkService?.sendMessage(message)` 转发给所有客户端**
3. [**`sendMessage`**](flutter/lib/network_service.dart:196) 在主机模式下会广播给 **所有** 已连接的客户端（包括原始发送方）
4. 原始客户端收到自己发出的 `roll_end` 的回环 → 再次调用 `_handleRemoteRollEnd` → 覆盖 `_isAnimating`

这导致即使在掷骰方设备上，`_isAnimating` 也可能在 Roll 处理过程中被意外重置。

## 修复方案

### 修改 1：[`_handleRemoteRollEnd`](flutter/lib/main.dart:622)

**问题**：无条件设置 `_isAnimating = false`。

**修复**：根据是否有后续移动动画来决定是否清除 `_isAnimating`：
- 如果玩家在监狱中（掷骰试图出狱）→ 无移动动画 → `_isAnimating = false`
- 如果掷骰被拒绝（错误/驳回）→ 无移动动画 → `_isAnimating = false`
- 否则（正常掷骰）→ 有移动动画 → **不修改 `_isAnimating`**（保持 `true`）

检测逻辑：
```dart
// 检查玩家是否在监狱中（无移动动画）
final activeIdx = (state['active_player_index'] as num?)?.toInt() ?? 0;
final playersList = state['players'] as List<dynamic>? ?? [];
final isInJail = activeIdx < playersList.length
    ? ((playersList[activeIdx] as Map<String, dynamic>)['jail_turns'] as num?)?.toInt() ?? 0 > 0
    : false;

// 检查是否被拒绝（无移动动画）
final eventType = event?['event_type'] as String? ?? '';
final isRejected = eventType == 'core:command_rejected';

final hasMovement = !isRejected && !isInJail;
// 只在无移动动画时清除 _isAnimating
```

### 修改 2：[`_handleRemoteMoveStart`](flutter/lib/main.dart:679)

**问题**：没有设置 `_isAnimating = true`。

**修复**：在方法开始时设置 `_isAnimating = true`，确保移动动画期间按钮禁用。

```dart
Future<void> _handleRemoteMoveStart(int playerIndex, List<dynamic> tilePath) async {
    if (!mounted || tilePath.isEmpty) return;
    setState(() {
      _isAnimating = true;  // ← 新增：确保移动期间按钮禁用
    });
    // ... 后续动画代码不变
}
```

### 修改 3：防止消息回环

**问题**：主机转发 `roll_end` 时回环到原始发送方。

**修复方案 A（推荐，改动最小）**：在 [`_handleRemoteRollEnd`](flutter/lib/main.dart:622) 开头添加守卫，如果当前正在执行本地 Roll（`_isRollingDice` 为 `true`），则忽略远程的 `roll_end`。

```dart
void _handleRemoteRollEnd(...) {
  if (!mounted) return;
  // 如果正在执行本地 Roll，忽略远程回环消息
  if (_isRollingDice) return;
  // ...
}
```

**修复方案 B（更彻底）**：修改 [`_onNetworkMessage`](flutter/lib/main.dart:469) 中 `roll_end` 的处理逻辑，主机转发时不回环给原始发送方。需要在 `sendMessage` 或 `_onNetworkMessage` 中追踪消息来源。

**选择方案 A**，因为它简单、安全，且与现有架构一致。

### 修改 4：[`_handleRemoteRollEnd`](flutter/lib/main.dart:622) 中移除对自身 `roll_end` 的处理

结合修改 3，如果 `_isRollingDice` 守卫生效，那么即使在掷骰过程中收到回环消息也会被忽略，`_isAnimating` 不会被意外覆盖。

---

## 修改列表

| # | 文件 | 行号 | 修改内容 |
|---|------|------|---------|
| 1 | [`flutter/lib/main.dart`](flutter/lib/main.dart:622) | ~622-651 | `_handleRemoteRollEnd`：根据移动动画是否存在来决定是否设置 `_isAnimating = false` |
| 2 | [`flutter/lib/main.dart`](flutter/lib/main.dart:679) | ~679 | `_handleRemoteMoveStart`：开头添加 `_isAnimating = true` |
| 3 | [`flutter/lib/main.dart`](flutter/lib/main.dart:622) | ~623 | `_handleRemoteRollEnd`：开头添加 `if (_isRollingDice) return;` 守卫 |

## 时序图（修复后）

```
掷骰方                      接收方（其他客户端）
  │                            │
  ├─ _onRoll()                 │
  │  _isAnimating = true       │
  │  _isRollingDice = true     │
  │                            │
  ├─ _broadcastRollStart() ───►  _handleRemoteRollStart()
  │                            │    _isAnimating = true     ✅
  │                            │
  ├─ [掷骰动画...]             │  [骰子动画...]
  │                            │
  ├─ _broadcastRollEnd() ─────►  _handleRemoteRollEnd()
  │                            │    _isRollingDice 为 false (非掷骰方)
  │                            │    hasMovement = true (非监狱/非拒绝)
  │                            │    不修改 _isAnimating     ✅ 仍为 true
  │                            │
  │  [收到自己的回环]          │
  │  _handleRemoteRollEnd      │
  │  _isRollingDice 为 true    │
  │  return (忽略)             ✅ 不干扰本地状态
  │                            │
  ├─ _broadcastMoveStart() ───►  _handleRemoteMoveStart()
  │                            │    _isAnimating = true     ✅
  │                            │    循环播放移动动画...
  │                            │
  ├─ _broadcastMoveEnd() ─────►  _handleRemoteMoveEnd()
  │                            │    _isAnimating = false    ✅
```

## 边界情况验证

### 1. 监狱掷骰（无移动）
- 接收方收到 `roll_end` → `hasMovement = false`（`isInJail = true`）→ `_isAnimating = false` ✅
- 无 `move_start`/`move_end` → 按钮正确禁用 ✅

### 2. 掷骰被拒绝（医院中/已掷过）
- 接收方收到 `roll_end` → `hasMovement = false`（`isRejected = true`）→ `_isAnimating = false` ✅
- 无 `move_start`/`move_end` → 按钮正确禁用 ✅

### 3. 离线模式
- 不涉及网络消息 → 不受影响 ✅

### 4. 多人（3+玩家）
- 仅非掷骰方接收 `roll_end`/`move_start`/`move_end`
- 非掷骰方的 `_isLocalPlayersTurn` 为 `false` → 按钮本就禁用
- 但修复后 `_isAnimating` 正确同步 → 状态一致 ✅
