# saMonopoly - A2CM 集成协议

## 目标

本文定义 saMonopoly 调用 A2CM 陪伴服务进行大富翁决策的版本化协议。
saMonopoly 的 Rust 后端是游戏状态和命令执行的唯一权威来源；A2CM 只返回决策建议，所有操作仍由 Rust 游戏命令处理器校验。

当前协议版本：`1`

## 服务端点

### 健康检查

```http
GET /monopoly/health
Authorization: Bearer <可选密钥>
```

该端点必须通过与决策端点相同的鉴权，并返回 Monopoly 能力声明：

```json
{
  "status": "ok",
  "service": "a2cm",
  "game": "monopoly",
  "protocol_version": 1,
  "decision_endpoint": "/monopoly/decide",
  "llm_backend": "openai"
}
```

该端点不得发起 LLM 请求或修改 A2CM 状态。

### 回合决策

```http
POST /monopoly/decide
Content-Type: application/json
Authorization: Bearer <可选密钥>
```

请求示例：

```json
{
  "protocol_version": 1,
  "request_id": "turn-12-player_2-1",
  "game": "monopoly",
  "action": "decide_turn",
  "player_id": "player_2",
  "context": {
    "you": {
      "id": "player_2",
      "name": "A2CM",
      "cash": 1400,
      "position": "prop_9",
      "property_count": 2,
      "owned_tiles": ["prop_1", "prop_3"],
      "owned_cards": [],
      "is_in_jail": false,
      "jail_turns": 0
    },
    "opponents": [],
    "landed_tile": {
      "id": "prop_9",
      "name": "prop.prop_9",
      "base_price": 220,
      "owner": null,
      "upgrade_level": 0,
      "group": ["prop_9", "prop_10"],
      "current_rent": 22
    },
    "color_groups": [],
    "available_actions": ["end_turn", "buy_property"],
    "turn": 12,
    "board_layout": [],
    "board_edges": [],
    "teleporters": [],
    "card_decks": [],
    "event_log": ["Player 1 bought prop_8"]
  },
  "prompt": "You are playing Monopoly..."
}
```

`context` 是 Rust 根据当前 `GameState` 生成的权威结构化快照，A2CM 不应修改后回传。`prompt` 是同一上下文的文本表示，可交给 A2CM 内部的人格化 LLM。

## 响应格式

成功必须返回 HTTP `200` 和一个 `LlmDecision`：

```json
{
  "command": "buy_property",
  "payload": {"tile_id": "prop_9"},
  "rationale": "价格可负担且能推进色组收集",
  "commentary": "这块地很适合我们。"
}
```

字段：

| 字段 | 必填 | 说明 |
|---|---:|---|
| `command` | 是 | 下表中的命令之一 |
| `payload` | 否 | 默认 `{}`，必须是 JSON 对象 |
| `rationale` | 否 | 决策依据，用于日志 |
| `commentary` | 否 | A2CM 角色台词，用于游戏界面 |

## 命令与 payload

| command | payload | 约束 |
|---|---|---|
| `buy_property` | `{"tile_id":"prop_9"}` | `tile_id` 非空 |
| `upgrade_property` | `{"tile_id":"prop_1"}` | `tile_id` 非空 |
| `buy_card` | `{"card_id":"bonus_200","price":100}` | 固定价：`bonus_200=100`、`get_out_of_jail=150`、`double_rent=200` |
| `buy_lottery_ticket` | `{"number":7}` | `number` 为 `1..=100` 的整数 |
| `pay_bail` | `{}` | 无额外字段 |
| `use_card` | `{"card_id":"get_out_of_jail"}` | `card_id` 非空 |
| `end_turn` | `{}` | 无额外字段 |

saMonopoly 会拒绝未知命令和格式错误的 payload。即便格式有效，Rust 命令处理器仍会校验当前玩家、资金、所有权和游戏状态。

## 错误处理

- A2CM 应对无效请求返回 `4xx`，服务故障返回 `5xx`。
- saMonopoly 遇到连接失败、非 `200`、无效 JSON、未知命令或非法 payload 时，会记录错误并安全结束当前 LLM 玩家的回合。
- `request_id` 用于日志关联和幂等诊断；协议版本 1 当前不要求服务端缓存响应。

## 兼容性

- A2CM 必须检查 `protocol_version`。不支持时应返回 `400` 或 `422`。
- 新增可选 context 字段属于向后兼容变化。
- 删除字段、修改字段类型、添加命令或改变 payload 语义需要提升协议版本。
