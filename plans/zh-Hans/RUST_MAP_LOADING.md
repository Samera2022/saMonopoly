# Rust 后端地图加载方案

## 目标

将地图数据加载和初始状态构建从 Flutter 移到 Rust，使 Rust 成为 GameState 的唯一创建者。

## 改动

### 1. 扩展 `MapDefinition`（`map.rs`）

新增字段以包含完整的地图数据：

```rust
pub struct MapDefinition {
    pub id: String,
    pub version: String,
    pub name_key: String,
    pub tiles: Vec<MapTile>,
    pub rules: MapRules,
    #[serde(default)]
    pub plugins: Vec<MapPluginRef>,
    // ─── 新增 ───
    pub properties: Vec<MapPropertyDef>,     // 地产定义（价格、颜色、预设 owner）
    pub special_tiles: Map<String, SpecialTileDef>,  // 特殊格子配置
    pub chance_tiles: Vec<String>,            // 机会卡 tile ID 列表
}

pub struct MapPropertyDef {
    pub tile_id: String,
    pub base_price: i64,
    pub color_group: String,
    pub owner: Option<String>,   // 预设所有者
    pub linked_targets: Vec<String>,  // 组链接
}
```

### 2. 新增 `map_to_game_state` 函数（`map.rs` 或新文件 `game_setup.rs`）

```rust
pub fn map_to_game_state(
    map: &MapDefinition,
    players: &[Player],
    rules: &RuleSetRef,
    seed: u64,
) -> GameState {
    // 1. 从 map.tiles 构建 Board.tiles
    // 2. 从 map.properties 构建 Board.properties（含 owner）
    // 3. 从 map.tiles 和 map.special_tiles 构建特殊 tile 映射
    // 4. 计算 linked_targets（组租金）
    // 5. 返回完整 GameState
}
```

### 3. 新增桥接命令 `core:command:create_game`

Flutter 发送：
```json
{
  "command_type": "core:command:create_game",
  "source": "core",
  "payload": {
    "map": { ... 完整 MapDefinition JSON ... },
    "players": [
      {"id": "player_0", "name": "Alice", "is_ai": false},
      {"id": "player_1", "name": "Bob", "is_ai": true}
    ],
    "seed": 12345
  }
}
```

Rust 返回完整 GameState：
```json
{
  "events": [{"event_type": "core:game_created", "map_id": "classic"}],
  "state": { ... 完整初始 GameState ... }
}
```

### 4. 移除 Flutter 硬编码

删除 `_buildInitialState` 中的硬编码数据，改为调用 Rust：

```dart
Future<void> _initGame() async {
  final mapJson = await rootBundle.loadString('assets/maps/classic.json');
  final response = await _bridgeClient.executeCommand(
    command: BridgeCommand.createGame(mapJson, players, seed),
    currentState: {},
  );
  _currentState = response.state;
}
```

## 实施步骤

| # | 文件 | 改动 |
|---|------|------|
| 1 | `crates/infra/src/map.rs` | 扩展 `MapDefinition`，添加 `properties`/`special_tiles`/`chance_tiles` 字段 |
| 2 | `crates/application/src/lib.rs` | 导出新模块 |
| 3 | `crates/application/src/game_setup.rs`（新建） | `map_to_game_state()` 函数 |
| 4 | `crates/application/src/builtin/commands.rs` | 注册 `handle_create_game` 命令 |
| 5 | `flutter/assets/maps/classic.json` | 更新格式匹配新的 MapDefinition |
| 6 | `flutter/lib/bridge_client.dart` | 添加 `BridgeCommand.createGame()` |
| 7 | `flutter/lib/main.dart` | 移除硬编码 `_buildInitialState`，改为调用 Rust |
