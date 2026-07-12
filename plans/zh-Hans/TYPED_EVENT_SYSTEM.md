# 类型化事件系统设计方案

## 目标

将当前基于 `serde_json::Value` 的字符串类型事件系统升级为 **强类型事件系统**，所有事件具有明确的 Rust 数据类型和 Dart 数据类型，事件通过订阅/发布模式驱动游戏逻辑和 UI。

---

## 一、事件清单（22 个事件 + 4 个数据对象）

### 数据对象

```
PropertyData {
    tile_id: String,           // 地产注册名 (eg. "prop_1")
    kind: PropertyKind,        // 地产类型: Ordinary | Extension | Special
    base_price: i64,           // 基础价格
    owner: Option<String>,     // 当前所有者 (None = 无主)
    upgrade_level: u32,        // 当前等级
    linked_targets: Vec<String>, // 连锁收费目标 (未启用则为空)
}

CardData {
    id: String,                // 卡牌注册名
    name_key: String,          // 卡牌名称 key
    effect_key: String,        // 效果 key
    effect: Option<Box<dyn Fn()>>, // 可调用的效果方法 (仅 Flutter 端)
}

PlayerData {
    id: String,
    name: String,
    cash: i64,
    position: String,
    is_ai: bool,
    jail_turns: u32,
    hospital_turns: u32,
    owned_cards: Vec<String>,
}

DiceResult {
    dice1: u64,
    dice2: u64,
    is_seven: bool,
    consecutive: u32,
}
```

### 事件定义

| # | 事件名称 | Rust 事件类型 | 参数 | 触发时机 |
|---|---------|-------------|------|---------|
| 1 | **地产购买** | `PropertyBought` | `player_id, property: PropertyData` | 玩家确认购买地产 |
| 2 | **地产升级** | `PropertyUpgraded` | `player_id, property: PropertyData` | 玩家升级地产 |
| 3 | **走到他人地产** | `LandedOnOwnedProperty` | `from_player_id, to_player_id, property: PropertyData` | 玩家落在有主地产 |
| 4 | **走到特殊地产** | `LandedOnSpecialProperty` | `player_id, property: PropertyData` | 玩家落在特殊地产 (tax/park/bank) |
| 5 | **投骰子开始** | `DiceRollStarted` | `player_id` | 玩家点击 Roll 按钮 |
| 6 | **棋子移动开始** | `MovementStarted` | `player_id, steps: u64` | 骰子结果确定后 |
| 7 | **投骰子结束** | `DiceRollEnded` | `player_id, dice1, dice2, is_seven, consecutive` | 骰子动画完成后 |
| 8 | **棋子移动结束** | `MovementEnded` | `player_id, steps: u64` | 棋子动画完成后 |
| 9 | **玩家回合开始** | `PlayerTurnStarted` | `player_id` | 轮到该玩家 |
| 10 | **玩家回合结束** | `PlayerTurnEnded` | `player_id` | 玩家结束回合 |
| 11 | **彩票开奖** | `LotteryDraw` | `prize_amount: i64, winner_id: Option<String>` | 开奖结果 |
| 12 | **彩票被购买** | `LotteryTicketBought` | `player_id, number: u64` | 玩家购买彩票 |
| 13 | **玩家进监狱** | `PlayerSentToJail` | `player_id, turns: u32` | GoToJail/三连双 |
| 14 | **玩家使用保释金** | `PlayerPaidBail` | `player_id, amount: i64` | 玩家支付保释金 |
| 15 | **玩家离开监狱** | `PlayerLeftJail` | `player_id` | 掷出对子/刑期满/保释 |
| 16 | **玩家进医院** | `PlayerSentToHospital` | `player_id, turns: u32` | 触发住院事件 |
| 17 | **玩家出医院** | `PlayerLeftHospital` | `player_id` | 住院期满 |
| 18 | **玩家破产** | `PlayerBankrupt` | `player_id` | 玩家现金为负 |
| 19 | **玩家胜利** | `PlayerWon` | `player_id` | 仅剩一名玩家 |
| 20 | **玩家使用卡牌** | `CardUsed` | `player_id, card: CardData, target: Option<String>` | 玩家使用持有卡牌 |
| 21 | **玩家发起交易** | `TradeProposed` | `from_player_id, to_player_id` | 玩家提出交易 |
| 22 | **玩家发起拍卖** | `AuctionStarted` | `initiator_id, tile_id` | 玩家发起拍卖 |

---

## 二、Rust 端实现

### 2.1 新增类型化事件结构体

在 [`crates/domain/src/events/core_events.rs`](crates/domain/src/events/core_events.rs) 中新增所有 22 个事件结构体，每个实现 `GameEvent` trait：

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PropertyBought {
    pub player_id: String,
    pub property: PropertyData,  // 全量地产数据
}

impl GameEvent for PropertyBought {
    fn event_type(&self) -> &'static str { "core:property_bought" }
    fn source(&self) -> &str { "core" }
    fn as_any(&self) -> &dyn Any { self }
}
```

### 2.2 新增数据对象

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PropertyData {
    pub tile_id: String,
    pub kind: PropertyKind,
    pub base_price: i64,
    pub owner: Option<String>,
    pub upgrade_level: u32,
    pub linked_targets: Vec<String>,
}
```

### 2.3 在命令处理器中发布类型化事件

原有命令处理器（如 [`handle_buy_property`](crates/application/src/builtin/commands.rs:330)）不再直接操作 `GameState`，而是发布类型化事件：

```rust
fn handle_buy_property(state, event, rng, bus) {
    // ... 验证逻辑 ...
    
    // 构造 PropertyData
    let property_data = PropertyData::from(&property);
    
    // 发布类型化事件
    let ev = PropertyBought {
        player_id: cmd.player_id,
        property: property_data,
    };
    bus.publish_typed(ev, state);
}
```

### 2.4 事件订阅者处理游戏逻辑

```rust
// 在 startup.rs 中注册
struct PropertyBuyHandler;
impl EventSubscriber for PropertyBuyHandler {
    fn interested_types(&self) -> Vec<&'static str> {
        vec!["core:property_bought"]
    }
    fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction {
        // 反序列化为类型化事件
        let ev: PropertyBought = event.into_typed().unwrap();
        // 处理购买逻辑：扣钱、设置 owner
        // ...
    }
}
```

---

## 三、Flutter 端实现

### 3.1 新增 Dart 数据类

```dart
class PropertyData {
    final String tileId;
    final String kind;
    final int basePrice;
    final String? owner;
    final int upgradeLevel;
    final List<String> linkedTargets;
    
    PropertyData({required this.tileId, ...});
    
    factory PropertyData.fromJson(Map<String, dynamic> json) => ...;
}

enum PropertyKind { ordinary, extension, special }
```

### 3.2 事件订阅（已有框架，扩展使用）

```dart
// 在 _registerEventSubscriptions() 中
EventDispatcher.subscribe(
    'core:property_bought',
    EventSubscriber((event) {
        final property = PropertyData.fromJson(event['property']);
        final playerId = event['player_id'] as String;
        // UI 效果：显示成功购买通知
    }),
);

EventDispatcher.subscribe(
    'core:player_turn_started',
    EventSubscriber((event) {
        final playerId = event['player_id'] as String;
        // UI 效果：高亮当前玩家、启用 Roll 按钮
    }),
);
```

### 3.3 `deferUiActions` 按需使用

仅 UI 对话框类事件（`card_shop_landed`、`lottery_landed`、`auction_started`）标记 `isUiAction: true`。游戏逻辑事件（`property_bought`、`player_sent_to_jail`、`rent_paid`）标记 `isUiAction: false`，立即执行。

---

## 四、迁移策略

### 阶段 1：定义类型（不影响现有代码）
- 在 `core_events.rs` 中新增全部 22 个事件结构体
- 定义 `PropertyData`、`CardData` 等数据对象

### 阶段 2：Rust 端逐步切换
- 逐个命令处理器从"直接操作 state → 发布类型化事件"
- 添加 `EventSubscriber` 监听事件并执行逻辑
- 保持向后兼容

### 阶段 3：Flutter 端扩展订阅
- 在 `_registerEventSubscriptions()` 中添加新订阅
- 移除不再需要的 `_onBuyProperty` 等直接方法

---

## 五、事件流示意

```
┌──────────────────────────────────────────────────────────────────┐
│ 当前架构 (已实现)                                                 │
│                                                                  │
│ Flutter → BridgeCommand → Rust CommandHandler                    │
│   → 直接操作 GameState → 发布 serde_json::Value 事件             │
│   → BridgeResponse → EventDispatcher.dispatch()                  │
│   → _handleLog() 显示日志                                        │
└──────────────────────────────────────────────────────────────────┘
                          ↓
┌──────────────────────────────────────────────────────────────────┐
│ 目标架构 (类型化事件订阅)                                          │
│                                                                  │
│ Flutter → BridgeCommand → Rust CommandHandler                    │
│   → 发布类型化事件 (PropertyBought, DiceRollStarted, 等)         │
│   → Rust EventSubscriber 处理游戏逻辑                             │
│   → BridgeResponse (含类型化事件)                                  │
│   → Flutter EventDispatcher.dispatch()                            │
│     → 日志订阅者 → 显示日志                                       │
│     → UI 订阅者 → 更新 UI/显示对话框                              │
└──────────────────────────────────────────────────────────────────┘
```
