# 收租功能异常修复方案

## 问题描述

玩家掷骰后落在其他玩家拥有的地产上时，租金未被扣除。收租功能完全失效。

## 根因分析

收租功能涉及 Rust 引擎和 Flutter UI 两层，但两层都未处理"落在他人拥有的地产上"的情况：

### Rust 引擎端

[`handle_roll`](crates/application/src/builtin/commands.rs:133) 处理掷骰命令时：
1. 生成骰子值 ✓
2. 移动玩家位置 ✓
3. 处理通过起点 ✓
4. **未调用 `resolve_tile`** ❌

[Rust 已注册的 tile behavior](crates/application/src/builtin/tiles.rs:14) `handle_ordinary_property` 包含收租逻辑（检查地产所有者 → 扣除租金 → 发布 `core:rent_paid` 事件），但因为 `resolve_tile` 从未被调用，这段代码完全未被执行。

### Flutter UI 端

[`_onRoll`](flutter/lib/main.dart:1096) 处理掷骰后：
1. `_resolveTileEffect` → 处理 Start/Chance/Bank/Jail/CardShop/Lottery ✓
2. `_findPropertyAtTile` → 检查地产状态：
   - `owner == null` → 显示购买对话框 ✓
   - `owner == playerId` → 显示升级对话框 ✓
   - `owner != null && owner != playerId` → **什么都不做** ❌

### 事件流总结

```
Roll 命令 → Rust handle_roll (移动玩家)
  → resolve_tile? ❌ 未调用 → handle_ordinary_property 不执行
  → 返回 state 给 Flutter
  → Flutter _resolveTileEffect (只处理特殊格子)
  → Flutter _findPropertyAtTile
    → 他人地产? → 什么都不做 ❌ 租金未收取
```

## 修复方案

在 [`_onRoll`](flutter/lib/main.dart:1096) 中，检测到玩家落在他人拥有的地产上时，自动调用 `core:command:pay_rent` 命令让 Rust 引擎处理租金扣除。

### 修改位置

[`flutter/lib/main.dart`](flutter/lib/main.dart:1262) — `_onRoll` 方法末尾，在 `_findPropertyAtTile` 判断中增加对"他人地产"的处理分支。

### 修改内容

```dart
// Check if player landed on a purchasable or own upgradable property
final property = _findPropertyAtTile(playerPos);
if (property != null) {
  final owner = property['owner'] as String?;
  final playerId = _gameState.players[_gameState.activePlayerIndex].id;
  if (owner == null) {
    _showBuyPropertyDialog(playerPos, property);
  } else if (owner == playerId) {
    // 现有：升级对话框逻辑（不变）
    ...
  } else {
    // ← 新增：自动支付租金
    _autoPayRent(playerPos);
  }
}
```

新增 `_autoPayRent` 方法：

```dart
/// Automatically pay rent for a tile owned by another player.
Future<void> _autoPayRent(String tileId) async {
  final response = await _bridgeClient.executeCommand(
    command: BridgeCommand.payRent(tileId),
    currentState: _currentState,
  );
  final r = EventDispatcher.dispatch(
    response: response,
    callbacks: _defaultCallbacks(),
  );
  setState(() {
    _currentState = response.state;
    _gameState = _buildGameState(
      response.state,
      lastEvent: r.lastLog,
    );
  });
  _syncAfterAction(response, actionLog: r.lastLog);
}
```

### 时序图（修复后）

```
Roll 命令 → Rust handle_roll (移动玩家)
  → 返回 state 给 Flutter
  → Flutter _resolveTileEffect
  → Flutter _findPropertyAtTile
    → 他人地产? → _autoPayRent(tileId)
      → bridgeClient.executeCommand(payRent)
      → Rust handle_pay_rent: 扣款 + 添加给 owner
      → 返回新 state（已扣除租金）
      → Flutter setState + sync
```

### 边界情况

1. **玩家现金不足**：Rust 的 `pay_rent` 命令会检测 `can_afford`，不足时返回 `core:command_rejected`，Flutter 的 EventDispatcher 会显示日志
2. **自地产**：`pay_rent` 命令会检测 `owner_id == cmd.player_id` 并拒绝（但我们的 `else` 分支已排除此情况）
3. **无主地产**：`pay_rent` 命令会检测 `property.owner == None` 并拒绝（但我们的分支已排除此情况）
4. **抵押地产**：`Property::current_rent()` 在 `is_mortgaged = true` 时返回 0，`pay_rent` 命令会正常执行但租金为 0
5. **组租金**：`pay_rent` 命令使用 `property.current_rent()`，不支持组租金增强。但组租金增强的逻辑在 `economy.rs` 中，`pay_rent` 命令暂未使用该服务——这是一个已知限制，但不在本修复范围内
