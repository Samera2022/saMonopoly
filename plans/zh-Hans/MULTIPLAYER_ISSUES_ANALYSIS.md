# 多人联机回合同步问题分析

## 概述

本文档分析 saMonopoly 在多人联机模式下，游戏回合过程中存在的同步问题。当前网络架构分为**两个完全独立的 WebSocket 系统**：Flutter（Dart）层的纯 HTTP WebSocket，和 Rust 后端的 tokio-tungstenite WebSocket 服务。两者互不通信，且 Flutter 层的同步方案存在诸多架构性问题。

---

## 问题 1：双网络协议栈完全割裂

当前存在**两套完全独立、互不兼容**的 WebSocket 实现：

### 1a. Flutter 层网络服务
[`flutter/lib/network_service.dart`](flutter/lib/network_service.dart) 使用 Dart 内置的 `HttpServer` + `WebSocketTransformer`。消息格式为简单的 JSON Map：

```json
{"type": "state_sync", "state": {...}}
{"type": "game_start", "state": {...}}
{"type": "join", "player_id": "...", "player_name": "..."}
```

### 1b. Rust 层网络服务
[`crates/infra/src/network.rs`](crates/infra/src/network.rs) 使用 `tokio-tungstenite`。消息格式为 serde 标签枚举：

```json
{"StateSync": {"payload": "..."}}
{"Command": {"payload": "..."}}
{"Session": {"kind": "Join", "data": "..."}}
```

### 1c. 割裂的后果
- **Rust 的 `WebSocketServer` 从未被启动**——Flutter UI 完全通过 Dart 层的 `NetworkService` 做点对点通信
- Flutter 的网络消息**不经过 Rust 引擎**，完全绕过了服务器端的命令验证
- Rust 层的 `NetworkTransport` trait 只有 `DisabledNetworkTransport` 实现，没有实际作用
- 所有游戏逻辑在**每个客户端本地通过 FFI 执行**，没有中心权威

---

## 问题 2：客户端自行执行 Tile 效果，状态不同步

### 核心问题
在 [`_onRoll`](flutter/lib/main.dart:821) 中，掷骰子后，`_resolveTileEffect` 在**每个客户端本地独立执行**：

```dart
// 执行特殊地块效果（在 Dart 侧直接修改状态）
await _resolveTileEffect(playerPos);
```

### 具体风险

#### 2a. Chance 卡用本地随机
[`_resolveTileEffect`](flutter/lib/main.dart:969) 中的 Chance 卡效果使用 `DateTime.now().millisecondsSinceEpoch % messages.length` 作为随机源，**不是 Rust 引擎的确定性 RNG**。主机和客户端的时间戳可能不同，导致抽到不同的 Chance 卡。

#### 2b. 直接修改现金和状态
方法 [`_deductCash`](flutter/lib/main.dart:1120)、[`_addCash`](flutter/lib/main.dart:1134)、[`_sendToJail`](flutter/lib/main.dart:1148) **直接在 Dart 侧修改 `_currentState`**，不经过 Rust 引擎：
- 主机扣款/加款后，通过 `_broadcastState` 发送全量状态
- 但客户端也在**本地执行相同逻辑**，状态本应一致但可能因随机差异而分叉

#### 2c. 两次状态修改导致不一致窗口期
在一次 Roll 操作中，状态被修改两次：
1. Roll 动作 → Rust 引擎返回新状态 → 应用状态
2. `_resolveTileEffect` → Dart 侧直接修改状态（可能包含现金变更、进监狱等）
3. `_broadcastState` 发送第二步修改后的状态

这期间如果网络延迟，客户端可能在收到第二步状态前就已经开始执行自己的 `_resolveTileEffect`，造成中间状态不一致。

---

## 问题 3：无中心命令验证架构

### 3a. 所有命令都在本地执行
[`BridgeClient.executeCommand`](flutter/lib/bridge_client.dart) 通过 FFI 在本地调用 Rust 引擎：

```dart
final response = await _bridgeClient.executeCommand(
  command: BridgeCommand.roll(),
  currentState: _currentState,
);
```

主机和客户端都**各自执行相同的命令**，主机仅负责在命令执行后广播最终状态。这意味着：
- **没有服务器端的命令验证**——客户端可以构造任意命令
- **没有防作弊机制**——恶意客户端可以修改本地状态后直接广播假的 `state_sync`

### 3b. 回合控制仅靠 UI 约束
[`_isLocalPlayersTurn`](flutter/lib/main.dart:194) 只控制按钮是否可点击：

```dart
bool get _isLocalPlayersTurn {
    if (_networkService == null) return true;
    if (_networkService!.isHost) {
      return _gameState.activePlayerIndex == 0;
    } else {
      return _gameState.activePlayerIndex > 0;
    }
}
```

这不是安全边界——客户端可以直接调用 `_onRoll` 或直接修改 `_currentState` 来绕过检查。

---

## 问题 4：状态同步为单向、无验证的全量广播

### 4a. 缺乏版本号/序列号
[`_broadcastState`](flutter/lib/main.dart:472) 发送的状态没有序列号或修订号：

```dart
void _broadcastState(BridgeResponse response) {
    final net = widget.networkService;
    if (net != null && net.isHost && mounted) {
      net.sendMessage({
        'type': 'state_sync',
        'state': response.state,
      });
    }
}
```

### 4b. 客户端无条件覆盖
[`_onNetworkMessage`](flutter/lib/main.dart:441) 中，客户端收到 `state_sync` 后无条件覆盖：

```dart
case 'state_sync':
    final state = message['state'] as Map<String, dynamic>?;
    if (state != null) {
      setState(() {
        _currentState = state;  // 直接覆盖，无版本检查
        _gameState = _buildGameState(state, lastEvent: 'State synced');
      });
    }
```

### 4c. 缺乏确认机制
- 主机发送 `state_sync` 后**不等待客户端确认**
- 如果消息丢失，客户端**永远无法恢复**正确的状态
- 没有重传机制
- 没有增量更新（diff）——每次都发送全量状态

### 4d. 时序问题
如果在一次回合中有多个动作（Roll → Tile Effect → End Turn），每个动作都会触发一次 `state_sync`：
1. `state_sync` (Roll 后)
2. `state_sync` (Tile Effect 后)
3. `state_sync` (End Turn 后)

如果消息 2 比消息 3 晚到达（网络乱序），客户端的状态将被**旧状态覆盖**。

---

## 问题 5：客户端的 Rust 引擎未用于验证

[`flutter/lib/bridge_client.dart`](flutter/lib/bridge_client.dart) 虽然在主机和客户端都有，但在客户端模式下：

- 客户端收到 `state_sync` 后**直接覆盖本地状态**，不经过引擎验证
- 客户端的 `_onRoll`、`_onEndTurn` 等动作调用 `BridgeClient.executeCommand` 执行命令，但产生的状态**永远不会被主机认可**——主机只认自己产生的状态
- 这意味着客户端在 Roll 按钮点击后会产生一个本地状态，但下一秒就会被主机的 `state_sync` 覆盖

**客户端实际上在重复计算主机已经算好的结果**，浪费 CPU 资源。

---

## 问题 6：Rust WebSocket 服务器的 `EngineBridge` 存在安全隐患

[`WebSocketServer::process_message`](crates/infra/src/network.rs:464) 中对命令的处理直接调用 `EngineBridge::execute_with_broadcast`：

```rust
NetworkMessage::Command { payload } => {
    let request: BridgeRequest = serde_json::from_str(payload)?;
    let response = EngineBridge::execute_with_broadcast(request);
    let state_json = serde_json::to_string(&response.state)?;
    let state_sync = NetworkMessage::StateSync { payload: state_json };
    self.broadcast(&state_sync).await;
}
```

这里：
- **没有身份验证**——任何连接的客户端都可以发送 `Command` 消息
- **没有回合控制**——不检查发送者是否是活跃玩家
- **`EngineBridge::execute_with_broadcast`** 调用静态的 `BROADCASTER`，但**没有任何代码设置过这个 broadcaster**
- 如果 Rust 服务器真的被启用，但没有回合验证，任何连接的客户端都能发送任意命令操控游戏

---

## 问题 7：`SessionSyncService` 为存根实现

[`crates/application/src/session_sync.rs`](crates/application/src/session_sync.rs) 中的 `SessionSyncService` 几乎为空：

```rust
pub struct SessionSyncService;

impl SessionSyncService {
    pub fn snapshot(state: GameState, revision: u64) -> SessionSyncSnapshot {
        SessionSyncSnapshot { state, revision }
    }
    pub fn restore(snapshot: SessionSyncSnapshot) -> GameState {
        snapshot.state
    }
}
```

- `snapshot` 只是包装状态 + 修订号，不做任何序列化或差异计算
- `restore` 只是解包，不做任何验证
- `revision` 字段虽然存在但**从未被使用**——没有版本冲突检测
- 没有增量同步（diff/patch）能力
- 这个服务的 `revision` 字段理论上可以用于版本控制，但 Flutter 侧的 `state_sync` 消息根本没有传递 revision

---

## 问题 8：`BridgeClient` 的 RNG 状态同步存在隐患

[`EngineBridge::execute`](crates/application/src/bridge.rs:62) 中：

```rust
pub fn execute(request: BridgeRequest) -> BridgeResponse {
    let mut state = request.state;
    let mut rng = BridgeRng::new(state.seed);
    let event = GameEngine::execute(request.command, &mut state, &mut rng);
    state.seed = rng.current_state(); // 持久化 RNG 状态
    BridgeResponse { event, state }
}
```

RNG 状态通过 `state.seed` 持久化回 GameState。但由于每个客户端都独立执行命令：
- **主机**的 RNG 状态正确推进
- **客户端**收到 `state_sync` 后覆盖本地状态，所以客户端的 RNG 状态与主机同步
- 但如果客户端在收到 `state_sync` **之前**就执行了自己的命令（如客户端自己调用了 `_onRoll`），RNG 序列会分叉，客户端的状态将永久与主机不一致

---

## 问题 9：缺乏断线重连机制

- 没有心跳检测或连接健康监控（Flutter 的 `NetworkService` 没有 ping/pong 循环）
- 客户端断线后**无法重新加入游戏**——`SessionManager` 没有重新连接逻辑
- 没有状态校验和（checksum）来验证同步是否正确
- 没有状态快照存档——如果连接中断，所有客户端都会丢失游戏进度

---

## 问题 10：动画与状态同步的时序耦合

[`_onRoll`](flutter/lib/main.dart:859) 中的动画逻辑与状态更新耦合：

```dart
// 动画循环
for (var i = 0; i < path.length; i++) {
    await Future.delayed(const Duration(milliseconds: 150));
    setState(() {
        _animatedPositions[activeIdx] = path[i];
        _gameState = _buildGameState(
            _currentState,
            positionOverrides: Map.of(_animatedPositions),
        );
    });
}
// 最终状态
setState(() {
    _currentState = response.state;
    _gameState = _buildGameState(response.state, ...);
});
_broadcastState(response);
```

- 主机在动画**结束前**不会发送 `state_sync`（被动画循环阻塞）
- 客户端在动画期间无法获取最新状态
- 如果动画期间有网络消息到达，可能被忽略或延迟处理
- `_broadcastState` 在动画完成后才发送，导致客户端状态更新有显著的视觉延迟

---

## 总结与建议

### 当前架构的本质
当前所谓的"多人联机"实际上是**状态广播模式**：
1. 主机执行所有游戏逻辑
2. 主机将最终状态广播到所有客户端
3. 客户端覆盖本地状态并刷新 UI

这种模式在**诚实玩家、低延迟 LAN** 环境下勉强可用，但存在根本性的架构缺陷。

### 推荐修复优先级

1. **高优先级（数据一致性）**
   - 统一使用主机的 Rust 引擎作为唯一状态权威，客户端发送命令到主机，由主机执行后广播结果
   - 为 `state_sync` 添加单调递增的序列号，客户端按序列号应用状态更新
   - 将所有 Tile 效果（Chance 卡、税费、进监狱等）移到 Rust 引擎中执行，不在 Dart 侧直接修改状态
   - 添加客户端确认机制（ACK），确保状态已送达

2. **中优先级（安全与可靠性）**
   - 在主机侧添加回合验证：只有当前活跃玩家可以发送命令
   - 移除客户端本地执行命令的逻辑，客户端只接收和展示状态
   - 添加断线重连机制和状态快照
   - 实现心跳检测和连接健康监控

3. **低优先级（性能与架构）**
   - 实现增量状态同步（diff）替代全量广播
   - 统一 Flutter 和 Rust 的网络消息格式
   - 启用 Rust 的 `WebSocketServer` 替代 Flutter 的 `NetworkService`
   - 实现状态校验和（checksum）一致性验证
