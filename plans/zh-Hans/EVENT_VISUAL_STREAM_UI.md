# 可视化事件流 UI 设计方案

## 目标

将侧边栏的纯文本事件日志改为带图标和颜色的可视化事件流，每个事件类型对应不同的视觉风格。

## 数据模型

在 `GameStateData` 中添加事件类型字段，使 UI 能区分事件种类：

```dart
class EventLogEntry {
  final String message;
  final String type;     // "roll" | "move" | "property" | "card" | "jail" | "money" | "turn" | "system"
  final IconData icon;
  final Color color;
  final DateTime timestamp;
}
```

## 事件类型 → 图标/颜色映射

| 事件类型 | 图标 | 颜色 | 示例消息 |
|---------|------|------|---------|
| `roll` | 🎲 Icons.casino | 橙色 | "Rolled 3 + 4 = 7" |
| `move` | 👟 Icons.directions_walk | 蓝色 | "player_1 moved to prop_3" |
| `money` | 💰 Icons.attach_money | 绿色 | "Income tax paid: $200" |
| `property` | 🏠 Icons.home | 紫色 | "Bought prop_1" |
| `card` | 🃏 Icons.style | 品红 | "Drew card: bonus_200" |
| `jail` | 🔒 Icons.lock | 红色 | "Sent to jail for 3 turns" |
| `turn` | 🔄 Icons.repeat | 灰色 | "Turn 5" |
| `system` | ℹ️ Icons.info | 白色 | "Game started" |

## 实现

### 1. 添加 `EventLogEntry` 类到 `main.dart`

```dart
class EventLogEntry {
  final String message;
  final String type;
  EventLogEntry(this.message, this.type);
  
  IconData get icon { ... }
  Color get color { ... }
}
```

### 2. 修改 `GameStateData.eventLog` 为 `List<EventLogEntry>`

### 3. 更新 `_addLog()` 接受 type 参数

```dart
void _addLog(String message, {String type = 'system'}) {
  final entry = EventLogEntry(message, type);
  // add to list
}
```

### 4. 更新 `_buildEventLog()` 使用图标+颜色渲染

每个条目显示为：`[图标] [彩色文字]`

### 5. EventDispatcher 的 `_handleLog()` 返回事件类型

```dart
static LogResult _handleLog(String type, Map<String, dynamic> event) {
  // 返回 { message, eventCategory }
}
```
