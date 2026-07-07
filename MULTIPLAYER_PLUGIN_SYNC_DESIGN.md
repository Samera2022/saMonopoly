# 联机插件同步方案

## 1. 概述

当前 `WebSocketServer` 已经持有 `Arc<Mutex<EventBus>>` 并支持通过网络执行命令。但是**没有插件同步机制**：主机选择的插件不会广播给客户端，客户端也不会验证自己是否有所需插件。

本方案在现有架构上新增插件同步协议层，使联机游戏时所有参与者的插件状态保持一致。

---

## 2. 网络协议扩展

### 2.1 Rust 侧：新增 `NetworkMessage` 变体

```rust
// crates/infra/src/network.rs (扩展)

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum NetworkMessage {
    Ping,
    StateSync { payload: String },
    Command { payload: String },
    Session { kind: SessionMessageKind, data: String },
    Error { code: u32, message: String },

    // ── 新增：插件同步 ──

    /// 主机广播当前插件清单及启停状态
    PluginSync {
        /// 插件清单 (JSON 序列化)
        plugins: String, // Vec<PluginSyncEntry> 的 JSON
    },

    /// 客户端回复插件检查结果
    PluginAck {
        /// 客户端 ID
        client_id: String,
        /// 是否就绪（所有必选插件已安装且版本匹配）
        ready: bool,
        /// 如果未就绪，列出缺失的插件 ID
        missing_plugins: Vec<String>,
    },

    /// 客户端请求主机重新发送插件清单（例如刚加入时）
    PluginListRequest,
}
```

### 2.2 插件同步条目

```rust
// crates/infra/src/plugins.rs (扩展)

/// 用于网络传输的插件同步条目
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PluginSyncEntry {
    /// 插件 ID
    pub id: String,
    /// 显示名称
    pub name: String,
    /// 最低版本要求
    pub min_version: String,
    /// 是否必选
    pub mandatory: bool,
    /// 来源类型（bundled 或 external）
    pub source: String, // "bundled" | "external"
    /// 是否已启用
    pub enabled: bool,
    /// 如果是 bundled 插件，附上插件数据
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundled_data: Option<String>, // base64 编码的插件二进制数据
}
```

### 2.3 主机侧：WebSocketServer 集成 PluginManager

```rust
// crates/infra/src/network.rs (扩展)

pub struct WebSocketServer {
    pub ws_config: WebSocketConfig,
    pub session_manager: Arc<Mutex<SessionManager>>,
    pub connected_peers: Arc<Mutex<HashMap<SessionEndpoint, mpsc::UnboundedSender<String>>>>,
    pub event_bus: Arc<Mutex<EventBus>>,
    // ── 新增 ──
    /// 插件管理器（主机持有，客户端无）
    pub plugin_manager: Arc<Mutex<PluginManager>>,
}

impl WebSocketServer {
    pub fn new(
        config: WebSocketConfig,
        session_manager: Arc<Mutex<SessionManager>>,
        plugin_manager: Arc<Mutex<PluginManager>>,  // 新增参数
    ) -> Self {
        Self {
            ws_config: config,
            session_manager,
            connected_peers: Arc::new(Mutex::new(HashMap::new())),
            event_bus: Arc::new(Mutex::new(EventBus::new())),
            plugin_manager,
        }
    }

    /// 当主机切换地图或调整插件状态时调用
    pub async fn broadcast_plugin_list(&self) {
        let pm = self.plugin_manager.lock().await;
        let entries: Vec<PluginSyncEntry> = pm.build_sync_entries();
        let json = serde_json::to_string(&entries).unwrap_or_default();
        let msg = NetworkMessage::PluginSync { plugins: json };
        self.broadcast(&msg).await;
    }
}
```

### 2.4 PluginManager 新增方法

```rust
// crates/infra/src/plugin_manager.rs (扩展)

impl PluginManager {
    /// 构建用于网络同步的插件条目列表
    pub fn build_sync_entries(&self) -> Vec<PluginSyncEntry> {
        let mut entries = Vec::new();
        // 1. 地图捆绑插件
        for (id, managed) in &self.bundled_plugins {
            let bundled_data = match &managed.info.origin {
                PluginOrigin::Bundled { bundle_path, .. } => {
                    // 尝试从插件文件读取二进制数据
                    // 实际实现中从 bundled_data 字段获取
                    None
                }
                _ => None,
            };
            entries.push(PluginSyncEntry {
                id: id.clone(),
                name: managed.info.name.clone(),
                min_version: managed.info.version.clone(),
                mandatory: self.mandatory_plugins.contains(id),
                source: "bundled".to_string(),
                enabled: self.active_plugins.contains(id),
                bundled_data: None,
            });
        }
        // 2. 用户启用的本地插件
        for (id, managed) in &self.local_plugins {
            if self.active_plugins.contains(id) {
                entries.push(PluginSyncEntry {
                    id: id.clone(),
                    name: managed.info.name.clone(),
                    min_version: managed.info.version.clone(),
                    mandatory: false,
                    source: "external".to_string(),
                    enabled: true,
                    bundled_data: None,
                });
            }
        }
        entries
    }

    /// 验证客户端提交的插件 ACK
    pub fn validate_client_plugins(&self, ack: &PluginAck) -> Result<(), Vec<String>> {
        let mut missing = Vec::new();
        for mandatory_id in &self.mandatory_plugins {
            if ack.missing_plugins.contains(mandatory_id) {
                missing.push(mandatory_id.clone());
            }
        }
        if missing.is_empty() { Ok(()) } else { Err(missing) }
    }
}
```

### 2.5 process_message 处理插件消息

```rust
// crates/infra/src/network.rs (process_message 扩展)

// 在 match network_msg 中添加：

NetworkMessage::PluginSync { plugins } => {
    // 客户端收到主机广播的插件清单
    // 解析清单，检查本地是否有所需插件
    let entries: Vec<PluginSyncEntry> = serde_json::from_str(plugins)
        .map_err(|e| format!("Invalid PluginSync: {e}"))?;

    let mut missing = Vec::new();
    for entry in &entries {
        if entry.mandatory && entry.source == "external" {
            // 检查本地是否已安装此插件
            let pm = self.plugin_manager.lock().await;
            if !pm.local_plugins.contains_key(&entry.id) {
                missing.push(entry.id.clone());
            }
        }
    }

    // 回复 ACK
    let ack = NetworkMessage::PluginAck {
        client_id: "local_client".to_string(),
        ready: missing.is_empty(),
        missing_plugins: missing,
    };
    self.send_to(endpoint, &ack).await;
}

NetworkMessage::PluginAck { client_id, ready, missing_plugins } => {
    // 主机收到客户端的插件检查结果
    log::info!(
        "[PluginSync] Client {client_id} ready: {ready}, missing: {missing_plugins:?}"
    );
    // 可以存入待确认的客户端列表
    if let Ok(mut pending) = self.pending_acks.lock() {
        pending.insert(client_id, (ready, missing_plugins));
    }
}

NetworkMessage::PluginListRequest => {
    // 客户端请求插件清单 → 主机重新广播
    self.broadcast_plugin_list().await;
}
```

---

## 3. Flutter 侧方案

### 3.1 PluginSyncMessage Dart 模型

```dart
// flutter/lib/plugin_models.dart (新文件)

class PluginSyncEntry {
  final String id;
  final String name;
  final String minVersion;
  final bool mandatory;
  final String source; // "bundled" | "external"
  final bool enabled;
  final String? bundledData; // base64

  PluginSyncEntry({required this.id, required this.name, ...});

  factory PluginSyncEntry.fromJson(Map<String, dynamic> json) => ...;
}

class PluginAckMessage {
  final String clientId;
  final bool ready;
  final List<String> missingPlugins;

  Map<String, dynamic> toJson() => {
    'type': 'plugin_ack',
    'client_id': clientId,
    'ready': ready,
    'missing_plugins': missingPlugins,
  };
}
```

### 3.2 GameLobbyScreen 插件管理 UI

```
┌─────────────────────────────────────────────────┐
│  比赛设置                                        │
│  ┌─ 地图预览 ─────────────────────────────────┐ │
│  │ portal_world · 5 tiles · v1.0              │ │
│  └────────────────────────────────────────────┘ │
│                                                  │
│  ┌─ 插件管理 ───────────── 联机: ☑ 已同步 ────┐ │
│  │ 📦 地图自带 (必选)                          │ │
│  │  ▸ portal_system  ● 已激活 [不可禁用]      │ │
│  │                                              │ │
│  │ 📂 本地                                     │ │
│  │  ▸ dice_animation  ☑  [启用] [禁用]         │ │
│  │  ▸ sound_pack      ☐  [启用] [禁用]         │ │
│  │                                              │ │
│  │ 客户端状态:                                   │ │
│  │  ● 玩家 2: 已就绪 ✓                         │ │
│  │  ○ 玩家 3: 缺少插件 [weather_system] ✗     │ │
│  └──────────────────────────────────────────────┘ │
│                                                  │
│  [        开始游戏 (等待所有客户端就绪...)      ] │
└──────────────────────────────────────────────────┘
```

### 3.3 主机流程

```dart
// flutter/lib/game_lobby_screen.dart (扩展)

class _GameLobbyScreenState extends State<GameLobbyScreen> {
  // ── 插件状态 ──
  List<PluginSyncEntry> _activePlugins = [];
  Map<String, bool> _clientReadyStates = {};  // client_id → ready

  void _onPluginToggled(String pluginId, bool enabled) {
    // 1. 更新本地插件状态
    // 2. 如果是主机，广播 PluginSync
    if (_networkService != null && _isHosting) {
      _networkService!.sendMessage({
        'type': 'plugin_sync',
        'plugins': _activePlugins.map((p) => {
          'id': p.id, 'name': p.name, 'min_version': p.minVersion,
          'mandatory': p.mandatory, 'source': p.source,
          'enabled': p.id == pluginId ? enabled : p.enabled,
        }).toList(),
      });
    }
  }

  bool get _canStartMultiplayerGame {
    // 所有客户端就绪 + 本地所有必选插件已启用
    if (!_allRemotePlayersReady) return false;
    if (_activePlugins.any((p) => p.mandatory && !p.enabled)) return false;
    return true;
  }
}
```

### 3.4 客户端流程

```dart
// flutter/lib/game_lobby_screen.dart (客户端消息处理扩展)

// 在 _netSub 的 message listener 中新增：
if (type == 'plugin_sync') {
  final pluginList = message['plugins'] as List<dynamic>;
  final entries = pluginList.map((p) => PluginSyncEntry.fromJson(p)).toList();

  // 检查缺失插件
  final missingPlugins = <String>[];
  for (final entry in entries) {
    if (entry.mandatory && entry.source == 'external') {
      if (!_localPluginIds.contains(entry.id)) {
        missingPlugins.add(entry.id);
      }
    }
  }

  setState(() {
    _activePlugins = entries;
  });

  // 回复 ACK
  _networkService!.sendMessage({
    'type': 'plugin_ack',
    'client_id': 'local_client',
    'ready': missingPlugins.isEmpty,
    'missing_plugins': missingPlugins,
  });
}
```

---

## 4. 完整消息序列

### 4.1 主机选择地图 → 建立大厅

```
主机                             客户端1             客户端2
  │                                │                  │
  │── PluginSync (广播) ──────────►│                  │
  │                                │── PluginAck ────►│
  │◄── PluginAck ──────────────────│                  │
  │                                │                  │── PluginAck ──►│
  │◄── PluginAck ────────────────────────────────────│                  │
  │                                │                  │
  │ [所有客户端就绪]                │                  │
  │── plugin_sync (更新) ─────────►│                  │
  │── plugin_sync ────────────────│─────────────────►│
  │                                │                  │
  │── game_start ─────────────────►│                  │
  │── game_start ──────── ────────│─────────────────►│
  │                                │                  │
```

### 4.2 主机切换插件状态

```
主机                             客户端1
  │                                │
  │ [禁用 dice_animation]          │
  │── PluginSync ─────────────────►│
  │                                │── PluginAck ────►│
  │◄───────────────────────────────│                  │
  │                                │
  │ [所有客户端就绪]                │
  │── game_start ─────────────────►│
```

### 4.3 客户端缺少必选插件时的拒绝

```
主机                             客户端1
  │                                │
  │── PluginSync ─────────────────►│
  │                                │ 检查: 缺少 weather_system
  │                                │── PluginAck (ready=false) ──►│
  │◄───────────────────────────────│
  │                                │
  │ [主机显示: 玩家1 缺少插件]      │
  │ [开始游戏按钮禁用]              │
```

---

## 5. 文件变更总清单

### Rust 侧

| 文件 | 变更 | 说明 |
|------|------|------|
| [`network.rs`](crates/infra/src/network.rs) | 修改 | 新增 `PluginSync`, `PluginAck`, `PluginListRequest` 消息变体 |
| [`network.rs`](crates/infra/src/network.rs) | 修改 | `WebSocketServer` 添加 `plugin_manager` 字段 |
| [`network.rs`](crates/infra/src/network.rs) | 修改 | `process_message` 添加 PluginSync/PluginAck 处理 |
| [`network.rs`](crates/infra/src/network.rs) | 修改 | 新增 `broadcast_plugin_list()`, `pending_acks` |
| [`plugins.rs`](crates/infra/src/plugins.rs) | 修改 | 新增 `PluginSyncEntry` 结构体 |
| [`plugin_manager.rs`](crates/infra/src/plugin_manager.rs) | 修改 | 新增 `build_sync_entries()`, `validate_client_plugins()` |

### Flutter 侧

| 文件 | 变更 | 说明 |
|------|------|------|
| **新文件** `flutter/lib/plugin_models.dart` | 新增 | `PluginSyncEntry`, `PluginAckMessage` |
| [`game_lobby_screen.dart`](flutter/lib/game_lobby_screen.dart) | 修改 | 插件管理 UI 分列 + 联机同步状态 |
| [`game_lobby_screen.dart`](flutter/lib/game_lobby_screen.dart) | 修改 | 主机: 插件状态变更时广播 PluginSync |
| [`game_lobby_screen.dart`](flutter/lib/game_lobby_screen.dart) | 修改 | 客户端: 收到 PluginSync 后检查并回复 PluginAck |
| [`network_service.dart`](flutter/lib/network_service.dart) | 不修改 | 现有 sendMessage 机制足够 |

---

## 6. 实施计划

| Step | 内容 | 文件 | 预估 |
|------|------|------|------|
| 1 | `PluginSyncEntry` 结构体 | `plugins.rs` | 0.5h |
| 2 | `NetworkMessage` 新增 3 个变体 | `network.rs` | 0.5h |
| 3 | `PluginManager::build_sync_entries()` + `validate_client_plugins()` | `plugin_manager.rs` | 1h |
| 4 | `WebSocketServer` 集成 `PluginManager` + `broadcast_plugin_list()` | `network.rs` | 1h |
| 5 | `process_message` 处理插件消息 | `network.rs` | 1h |
| 6 | Flutter `plugin_models.dart` | 新文件 | 0.5h |
| 7 | 大厅插件管理 UI + 联机同步状态显示 | `game_lobby_screen.dart` | 3h |
| 8 | 主机广播 + 客户端验证流程 | `game_lobby_screen.dart` | 2h |
| | **合计** | | **~9.5h** |
