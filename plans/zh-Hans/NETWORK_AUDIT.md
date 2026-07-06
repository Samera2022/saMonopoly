# 联网对决能力审计报告

## 一、现有架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│                        Flutter 前端                               │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │ GameLobby   │  │ BridgeClient │  │ RustEngineBinding      │ │
│  │ (UI 网络模式)│──│ (命令/响应)   │──│ (dart:ffi → .so)      │ │
│  └─────────────┘  └──────┬───────┘  └───────────┬────────────┘ │
│                          │                      │               │
│                   ConfigProvider                │ 本地进程内调用  │
│                   (NetworkConfig)               │               │
└──────────────────────────┼──────────────────────┼───────────────┘
                           │                      │
                    ┌──────▼──────────────────────▼──────────────┐
                    │           Rust 引擎 (同一进程)               │
                    │  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
                    │  │   ffi    │→│  bridge  │→│  engine  │ │
                    │  └──────────┘  └──────────┘  └──────────┘ │
                    │  ┌──────────┐  ┌──────────────────────┐   │
                    │  │ session_ │  │  infra::network      │   │
                    │  │ sync     │  │  (只存 stub, 无实现)  │   │
                    │  └──────────┘  └──────────────────────┘   │
                    └────────────────────────────────────────────┘
```

---

## 二、已实现的部分 ✅

### 2.1 抽象层完整

| 文件 | 内容 | 状态 |
|------|------|------|
| [`crates/infra/src/network.rs`](crates/infra/src/network.rs) | `WebSocketConfig`, `SessionEndpoint`, `NetworkMessage`, `NetworkTransport` trait, `SessionManager`, `SessionInfo` | ✅ 接口已定义 |
| [`crates/application/src/session_sync.rs`](crates/application/src/session_sync.rs) | `SessionSyncSnapshot` (state + revision), `SessionSyncService` | ✅ 同步模型已定义 |
| [`flutter/lib/config_provider.dart`](flutter/lib/config_provider.dart:284) | `NetworkConfig` (host, port, path, tls) | ✅ 配置类已定义 |
| [`flutter/lib/bridge_client.dart`](flutter/lib/bridge_client.dart) | `BridgeCommand`, `BridgeRequest`, `BridgeResponse`, Rust FFI 绑定 | ✅ 本地引擎通信已实现 |

### 2.2 Game Lobby UI 已就绪

| 功能 | 文件 | 状态 |
|------|------|------|
| 网络模式选择 (离线/主机/加入) | [`game_lobby_screen.dart`](flutter/lib/game_lobby_screen.dart:656) | ✅ UI 完成 |
| IP 输入框 + 连接按钮 | [`game_lobby_screen.dart`](flutter/lib/game_lobby_screen.dart:877) | ✅ UI 完成 |
| 托管状态栏 + 停止按钮 | [`game_lobby_screen.dart`](flutter/lib/game_lobby_screen.dart:804) | ✅ UI 完成 |
| 队伍颜色选择 (2×2) | [`game_lobby_screen.dart`](flutter/lib/game_lobby_screen.dart:1340) | ✅ UI 完成 |
| 保存 NetworkConfig | [`game_lobby_screen.dart`](flutter/lib/game_lobby_screen.dart:245) | ✅ 逻辑完成 |

---

## 三、缺失的关键环节 ❌

### 3.1 🚨 没有 WebSocket 服务器 (最关键)

```
当前:  DisabledNetworkTransport::send() → 返回 Err("network transport is disabled")
需要:  RealWebSocketTransport::send() → 实际通过 TCP/WS 发送消息
```

| 缺失项 | 说明 |
|--------|------|
| **WebSocket 库依赖** | `Cargo.toml` 中没有 `tokio-tungstenite`、`tokio` 或任何异步运行时 |
| **WS Server 实现** | `NetworkTransport` trait 有定义但没有真实实现 |
| **端口绑定** | 没有代码调用 `bind()` 监听端口 |
| **连接接受** | 没有 `accept()` 循环处理新连接 |

### 3.2 🚨 没有 WebSocket 客户端

```
当前:  Flutter 的 "连接" 按钮只是保存了 IP 到 ConfigProvider
需要:  实际建立 WebSocket 连接并开始消息收发
```

| 缺失项 | 说明 |
|--------|------|
| **Flutter WebSocket** | Flutter 有 `dart:io` 的 `WebSocket` 类，但没有使用 |
| **Rust WS Client** | Rust 侧没有客户端实现 |
| **重连逻辑** | 断线重连、心跳检测未实现 |

### 3.3 🚨 没有网络事件传播管道

```
客户端 A 操作          主机                 客户端 B
  Roll ───→ BridgeClient ──???──→ NetworkMessage::Command
                │                      │
          本地 Engine              主机 Engine
                │                      │
          更新 State             更新 State
                │                      │
          显示结果              NetworkMessage::StateSync
                                     │
                               客户端 B 收到 StateSync
                                     │
                               覆盖本地 State → 更新 UI
```

当前完全缺失中间的网络传输层。`BridgeClient.executeCommand()` 只能调用本地引擎，不能发送到远端。

### 3.4 ⚠️ 底层引擎没有网络感知

```
crates/application/src/lib.rs 中没有:
  - 网络模块的依赖
  - GameSession 没有 session_id / connected_players 字段
  - EngineBridge::execute() 没有广播回调
```

### 3.5 ⚠️ 团队系统未进入领域模型

| 位置 | 状态 |
|------|------|
| [`game_lobby_screen.dart`](flutter/lib/game_lobby_screen.dart) `PlayerSlotData.teamColor` | ✅ UI 层已有 |
| `crates/domain/src/player.rs` `Player` struct | ❌ 没有 `team_id` 字段 |
| `crates/domain/src/state.rs` `GameState` | ❌ 没有团队相关逻辑 |
| 游戏规则 / 胜负条件 | ❌ 未考虑团队模式 |

### 3.6 ⚠️ 主机/客户端职责未区分

```
当前: 所有实例都运行完整的本地引擎
需要:
  主机 (Host): 权威引擎 + 消息转发
  客户端 (Client): 仅 UI + 命令发送 + 状态接收
```

---

## 四、数据流对比

### 当前 (单机/离线)
```
用户操作 → BridgeCommand → BridgeClient.executeCommand()
                              ↓
                        本地 EngineBridge.execute()
                              ↓
                        BridgeResponse (event + state)
                              ↓
                        更新 UI
```

### 未来 (联网)
```
主机:
  用户操作 → BridgeCommand → BridgeClient.executeCommand()
                                ↓
                          本地 EngineBridge.execute()
                                ↓
                          BridgeResponse
                                ↓
                          NetworkMessage::StateSync
                                ↓
                          WebSocket → 广播给所有客户端

客户端:
  用户操作 → BridgeCommand → NetworkMessage::Command → WebSocket → 主机
                                                                    ↓
                                                              主机 Engine
                                                                    ↓
                                           NetworkMessage::StateSync ←┘
                                                ↓
                                          客户端收到 → 覆盖 State → 更新 UI
```

---

## 五、实施路线图建议

### Phase 1: WebSocket 基础设施
1. 添加依赖：`tokio`、`tokio-tungstenite`、`futures-util` 到 `infra/Cargo.toml`
2. 实现 `RealWebSocketTransport`（实现 `NetworkTransport` trait）
3. 实现 `WebSocketServer`（绑定端口、接受连接、管理会话）
4. 实现 `WebSocketClient`（连接到主机、发送/接收消息）

### Phase 2: 事件传播
5. 在 `EngineBridge::execute()` 添加广播回调
6. 实现网络命令转发（客户端 → 主机 → 引擎 → 结果广播）
7. 实现状态同步接收（客户端收到 `StateSync` → 覆盖本地 `currentState`）

### Phase 3: 会话与大厅
8. 将 `SessionManager` 接入 Game Lobby 的实际流程
9. 实现主机等待/玩家加入/准备就绪的完整流程
10. 添加 Flutter 端 `dart:io` WebSocket 连接（替代当前的空 IP 保存）

### Phase 4: 团队系统深入
11. 在 `crates/domain/src/player.rs` 的 `Player` 结构体添加 `team_id: Option<String>`
12. 在 `GameState` 添加团队胜负判定逻辑
13. 将 Lobby 层的 `teamColor` 通过游戏配置传入引擎

---

## 六、总结

| 维度 | 完成度 | 说明 |
|------|--------|------|
| **API/接口设计** | ✅ 80% | NetworkTransport trait、SessionManager、NetworkMessage 均已定义 |
| **UI/用户体验** | ✅ 70% | Game Lobby 已有完整的网络模式 UI、IP 输入、托管控制 |
| **WebSocket 实现** | ❌ 0% | 没有任何真实的网络连接代码 |
| **事件传播** | ❌ 0% | 没有从引擎到网络的广播管道 |
| **团队系统** | ⚠️ 30% | UI 层可选队伍，但领域模型不支持 |
| **会话管理** | ⚠️ 40% | SessionManager 逻辑存在但未接入实际流程 |

**结论：当前代码完成了联网功能的"蓝图"（接口定义 + UI 设计），但缺少真正的网络传输层实现。** 核心缺失是 WebSocket 服务器/客户端以及事件传播管道。
