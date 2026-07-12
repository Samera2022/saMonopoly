# 预设地产所有权方案

## 目标

在地图文件中预设某些地块的所有权归属（如 prop_1 归 player_1，prop_2 归 player_2），游戏启动时直接生效。

## 改动点

### 1. 地图 JSON 格式（`content/maps/builtin/classic.json`）

在 property 条目中添加可选的 `owner` 字段：

```json
{
  "properties": [
    { "tile_id": "prop_1", "base_price": 60, "color_group": "brown", "owner": "player_1" },
    { "tile_id": "prop_2", "base_price": 60, "color_group": "brown" }
  ]
}
```

- `owner` 为可选字段，值为玩家 ID（`"player_0"`、`"player_1"` 等）
- 不填或为 `null` 表示无人拥有（与现有行为一致），`serde(default)` 自动处理

### 2. Rust 侧 — 无需改动

`Property` 结构体已有 `owner: Option<String>` 字段且 `#[serde(default)]`：

```rust
pub struct Property {
    pub tile_id: TileId,
    pub base_price: Money,
    pub owner: Option<String>,   // ← serde 自动反序列化 JSON 中的 "owner"
    // ...
}
```

地图 JSON → `MapDefinition`（存于 `map.rs`）→ 解析为 `Property` 时，`owner` 字段会自动从 JSON 中读取。

### 3. Flutter 侧 — `_buildInitialState()`

在 `main.dart` 的 `_buildInitialState()` 中，构建 property 对象时检查地图数据中的 `owner`：

```dart
properties.add({
  'tile_id': tid,
  'name_key': 'prop.$tid',
  'kind': 'Ordinary',
  'base_price': price,
  'rent': <int>[],
  'upgrade_level': 0,
  'owner': tile['owner'],       // ← 从地图数据读取预设 owner
  'is_mortgaged': false,
  'linked_targets': groups[tid] ?? <String>[],
});
```

## 实施步骤

| # | 文件 | 改动 |
|---|------|------|
| 1 | [`content/maps/builtin/classic.json`](content/maps/builtin/classic.json) | 在部分 property 中添加 `"owner": "player_0"` 等 |
| 2 | [`flutter/lib/main.dart`](flutter/lib/main.dart) | 在 `_buildInitialState()` 中从 tile 数据读取 `owner` |
