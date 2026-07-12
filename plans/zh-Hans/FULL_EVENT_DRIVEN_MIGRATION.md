# 完全事件驱动模式迁移方案

## 目标

将当前"命令处理器直接操作 state → 发布事件通知"模式，改为 **"命令处理器只做验证 → 发布事件 → EventSubscriber 处理游戏逻辑"** 模式。

## 核心架构变化

```
当前:  CommandHandler → 直接操作 state → publish (通知)
目标:  CommandHandler → 验证 → publish (事件) → Subscriber 操作 state
```

## 迁移后的事件流

```
Flutter → BridgeCommand("core:command:buy_property")
  → EventBus.execute_command()
    → CommandHandler.handle_buy_property()
      → 1. 验证合法性 (player turn, affordability, etc.)
      → 2. bus.publish_typed(&PropertyBoughtEvent{...}, state)
      → 3. 返回 (不再直接操作 state)
    → EventSubscriber "property_handler" 收到 PropertyBoughtEvent
      → 4. 执行购买逻辑: 扣钱、设置 owner
      → 5. bus.publish_custom("core:property_bought", ...) 通知Flutter
    → BridgeResponse
```

## 需要修改的文件

### 1. `crates/application/src/builtin/commands.rs` — 命令处理器瘦身

每个命令处理器改为：
- **保留**：验证逻辑（玩家身份、余额检查、所有权检查等）
- **删除**：直接操作 GameState 的代码（扣钱、设置 owner、移动玩家等）
- **保留并增强**：`publish_typed()` 发布类型化事件
- **新增**：事件 payload 包含执行逻辑所需的全部数据

### 2. `crates/application/src/subscribers.rs` — 核心业务逻辑迁移

创建 `EventSubscriber` 实现，处理每个事件：

```rust
// 地产购买处理器
struct PropertyBuyHandler;
impl EventSubscriber for PropertyBuyHandler {
    fn interested_types(&self) -> Vec<&'static str> {
        vec!["core:property_bought_event"]
    }
    fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction {
        // 解析事件
        let ev: PropertyBoughtEvent = event.clone().into_typed().unwrap();
        // 执行购买：扣钱、设置 owner
        // 发布结果通知
        EventAction::Continue
    }
}
```

### 3. 迁移顺序（按风险从小到大）

| 优先级 | 命令 | 风险 | 原因 |
|--------|------|------|------|
| 1 | `handle_buy_card` | 低 | 简单逻辑，独立无依赖 |
| 2 | `handle_buy_lottery_ticket` | 低 | 简单逻辑 |
| 3 | `handle_mortgage` / `handle_redeem` | 低 | 简单逻辑 |
| 4 | `handle_buy_property` | 中 | 核心逻辑但独立 |
| 5 | `handle_upgrade_property` | 中 | 类似买地产 |
| 6 | `handle_pay_rent` | 中 | 涉及两个玩家 |
| 7 | `handle_pay_bail` | 中 | 涉及监狱状态 |
| 8 | `handle_use_card` | 中 | 涉及卡牌系统 |
| 9 | `handle_end_turn` | 高 | 涉及回合切换、破产检测 |
| 10 | `handle_roll` | 最高 | 最复杂，涉及移动、触发 tile 行为 |

## 已完成的准备

- ✅ 22 个类型化事件结构体
- ✅ `publish_typed()` 方法
- ✅ 所有命令处理器已发布类型化事件（当前作为额外通知）

## 下一阶段工作

阶段 1：创建 EventSubscriber 基础设施
阶段 2：迁移低风险命令（buy_card, lottery, mortgage, redeem）
阶段 3：迁移中等风险命令（buy_property, upgrade, pay_rent, pay_bail, use_card）
阶段 4：迁移高风险命令（end_turn, roll）
阶段 5：回归验证
