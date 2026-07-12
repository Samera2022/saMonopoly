# AI Strategy System

## Architecture Overview

The AI system consists of three components with clear separation of concerns:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Flutter UI Layer                              │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  _processAiTurn()                                        │  │
│  │  1. Call process_ai_turn (Rust: roll → end_turn)          │  │
│  │  2. Play dice & movement animations                       │  │
│  │  3. Call ai_evaluate (buy) → execute purchase             │  │
│  │  4. Call ai_evaluate (upgrade_target) → execute upgrade   │  │
│  │  5. If next player is AI, recurse                         │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                  │
│  Rust FFI Bridge (core:command:)                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  process_ai_turn   → TurnProcessor (roll + end_turn)      │  │
│  │  ai_evaluate (buy) → StrategicAiDecisionMaker::evaluate_buy│  │
│  │  ai_evaluate (upgrade) → best_upgrade_target              │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    Rust Engine Layer                             │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  TurnProcessor.process_turn_with_bus()                    │  │
│  │  - Executes roll command (dice + movement + tile events)  │  │
│  │  - Executes end_turn command                              │  │
│  │  - Does NOT handle buying (deferred to Flutter post-anim) │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  AiSubscriber (EventBus subscriber)                        │  │
│  │  - Listens to card_shop_landed → strategic card purchase   │  │
│  │  - Listens to lottery_landed → judicious ticket buying     │  │
│  │  - Listens to player_sent_to_jail → phase-aware bail       │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  StrategicAiDecisionMaker (decision engine)                │  │
│  │  - evaluate_buy()       — whether to buy a property        │  │
│  │  - score_property()     — property valuation (0-300+)     │  │
│  │  - best_upgrade_target() — best upgrade target             │  │
│  │  - required_safety_reserve() — safety reserve calculation  │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. StrategicAiDecisionMaker — Core Strategy Engine

**File:** [`crates/application/src/turn_processor.rs`](crates/application/src/turn_processor.rs)

### 1.1 Property Scoring `score_property()`

Calculates a 0-300+ score for each property; higher score = more desirable.

#### Scoring Dimensions

| Dimension | Weight Range | Description |
|-----------|-------------|-------------|
| Group Completion Bonus | 0 ~ +100 | Completing a color group → highest score |
| ROI | 0 ~ +60 | L3 rent / total upgrade cost × 10 |
| Price Score | +5 ~ +30 | Cheaper properties score higher |
| Position Score | +5 ~ +25 | Based on distance from Jail (dice probability) |
| Railroad Premium | +10 ~ +70 | Incentive to collect all 4 railroads |
| Utility Premium | +15 ~ +25 | Incentive to collect both utilities |
| Affordability Penalty | -50 ~ 0 | Reduces score when cash is tight |

#### Group Completion Bonus Logic

```rust
if missing_for_monopoly == 1 {
    // Buying completes the group → highest priority
    score += match group_size {
        2 => 80,   // 2-property group: easy to complete
        3 => 100,  // 3-property group: high value
        _ => 60,
    };
} else if owned_in_group >= 1 {
    // Already owns some in this group
    score += match group_size {
        2 => 40,   // One more to complete
        3 => 60,   // Two more needed
        _ => 20,
    };
}
```

#### Position Scoring (Dice Probability)

Dice probability distribution from Jail:
| Spaces from Jail | Landing Prob. | Score |
|-----------------|---------------|-------|
| 7 | 16.7% | 25 |
| 6 or 8 | 13.9% | 22 |
| 5 or 9 | 11.1% | 18 |
| 4 or 10 | 8.3% | 14 |
| 3 or 11 | 5.6% | 10 |
| 2 or 12 | 2.8% | 6 |

**On the classic map, Orange group (prop_9/prop_10/prop_11) sits 6-9 spaces after Jail with a cumulative landing probability of 38.9%!**

### 1.2 Strategic Buy Evaluation `evaluate_buy()`

#### Decision Rules (priority order)

1. **Rule 1 — Completes Group**: If buying completes a color group and cash is sufficient → **always buy**
2. **Rule 2 — Near Group Completion**: If owns 50%+ of group and can afford remaining → **strong buy**
3. **Rule 3 — One Away**: Already owns 2/3 of group → **strong buy**
4. **Rule 4 — Railroad**: Cash ≥ price + 200 → **aggressive buy**
5. **Rule 5 — Utility**: Already owns one or only one exists → **moderate buy**
6. **Rule 6 — Score Threshold**: Dynamic threshold based on cash:
   - Cash > $1000 (early): threshold 40
   - Cash $500~$1000 (mid): threshold 55
   - Cash < $500 (late): threshold 70
7. **Rule 7 — Safety Limit**: Never spend more than 50% of cash on one property

### 1.3 Strategic Upgrade Evaluation `best_upgrade_target()`

#### Preconditions

- Only considers properties in **fully owned color groups**
- Upgrade level must not exceed `max_upgrade_level`
- Must afford upgrade cost + safety reserve

#### Priority Score

```rust
priority = ROI * 50
         + (if lowest_in_group then +30)    // Even building bonus
         + (if first_upgrade then +20)       // First upgrade most impactful
         - current_level * 5                 // Diminishing returns penalty
```

**Even Building Strategy**: Only upgrades the lowest-level property in the group, ensuring all group properties are upgraded evenly for maximum total rent income.

### 1.4 Safety Reserve Calculation `required_safety_reserve()`

**Core Principle:** "If I land on the opponent's strongest property 3 times in a row, will I go bankrupt?"

```
safety_reserve = MAX(
    max_opponent_rent × 3 + 200,   // Survive 3 worst-case landings
    100                              // Minimum guarantee
)
```

**Max Opponent Rent** calculation:
1. Iterates all properties owned by **opponent players**
2. Calculates each property's `current_rent()` (if `group_rent_enabled` and has `linked_targets`, includes group rent sum)
3. Takes the maximum value

**Examples:**
| Scenario | Max Opponent Rent | Safety Reserve |
|----------|------------------|----------------|
| Opponent has fully upgraded Orange group ($72+$72+$80=$224) | $224 | $224×3+200 = **$872** |
| Opponent has one low-level property ($10) | $10 | $10×3+200 = **$230** |
| No opponent properties | $0 | **$100** |

---

## 2. AiSubscriber — Reactive Event Decisions

**File:** [`crates/application/src/ai_subscriber.rs`](crates/application/src/ai_subscriber.rs)

AiSubscriber listens to specific events via EventBus and makes immediate decisions.

### 2.1 Card Shop Decision `handle_card_shop_landed()`

#### Card Scoring System

| Card | Price | Condition | Score |
|------|-------|-----------|-------|
| get_out_of_jail | $150 | Sufficient cash | 100 |
| | | Low cash | 30 |
| double_rent | $200 | Owns ≥2 properties | 80 + count×5 |
| | | Owns <2 properties | 20 |
| bonus_200 | $100 | Cash < $300 | 70 |
| | | Cash $300~$500 | 50 |
| | | Cash > $500 | 10 |

**Strategy:** Choose the highest-scoring affordable card.

### 2.2 Lottery Decision `handle_lottery_landed()`

- Only buys when cash ≥ ticket_price + **$500** (disposable income)
- Skips lottery when cash is low (protects liquidity)

### 2.3 Jail Decision `handle_sent_to_jail()`

#### Phase-based Strategy

| Phase | Condition | Action |
|-------|-----------|--------|
| Has get_out_of_jail + late game | Owns ≥3 properties and has card | Use card |
| Early game | Owns ≤2 properties or cash > $1500 | Pay bail (continue acquiring) |
| Late game | Owns ≥3 properties | Stay in jail (avoid opponent rent) |
| Cannot afford | Cash < bail | Stay in jail |

**Bail calculation:** `jail_turns × $50/turn`

---

## 3. Bridge Command (`core:command:ai_evaluate`)

**File:** [`crates/application/src/bridge.rs`](crates/application/src/bridge.rs)

### 3.1 Request Format

```json
{
  "command_type": "core:command:ai_evaluate",
  "source": "core",
  "payload": {
    "action": "buy | upgrade_target | score",
    "tile_id": "prop_1",        // required for buy/score
    "player_id": "player_0"     // optional, defaults to active_player
  },
  "state": { /* full GameState */ }
}
```

### 3.2 Response Formats

**buy action:**
```json
{
  "action": "buy",
  "decision": "buy | pass",
  "score": 75,
  "tile_id": "prop_1"
}
```

**upgrade_target action:**
```json
{
  "action": "upgrade",
  "target": "prop_1 | null",
  "score": 85
}
```

**score action:**
```json
{
  "action": "score",
  "tile_id": "prop_1",
  "score": 75
}
```

---

## 4. Flutter Execution Flow

**File:** [`flutter/lib/main.dart`](flutter/lib/main.dart) `_processAiTurn()`

```
_processAiTurn()
  │
  ├─ 1. Call core:command:process_ai_turn (Rust: roll→end_turn)
  │
  ├─ 2. Play dice animation (8 random frames → show real values)
  │
  ├─ 3. Play piece movement animation (150ms per tile)
  │
  ├─ 4. Execute deferred UI actions (dialogs, etc.)
  │
  ├─ 5. Evaluate buy: ai_evaluate(action: 'buy', tileId: pos)
  │     ├─ decision == "buy" → execute buy_property command
  │     └─ decision == "pass" → log skip reason
  │
  ├─ 6. Evaluate upgrade: ai_evaluate(action: 'upgrade_target')
  │     ├─ target != null → execute upgrade_property command
  │     └─ target == null → skip
  │
  └─ 7. If next player is AI → recurse _processAiTurn()
```

---

## 5. Economic Model Reference

### Rent Formula

```
rent = base_price × (1 + level) / 10
```

| Level | Rent Ratio | Example ($100 prop) | Example ($400 prop) |
|-------|-----------|---------------------|---------------------|
| 0 | 10% | $10 | $40 |
| 1 | 20% | $20 | $80 |
| 2 | 30% | $30 | $120 |
| 3 | 40% | $40 | $160 |

### Upgrade Cost Formula

```
cost = base_price × (1 + level) / 3
```

| Upgrade | Cost Ratio | Example ($100 prop) |
|---------|-----------|---------------------|
| 0→1 | 33% | $33 |
| 1→2 | 67% | $67 |
| 2→3 | 100% | $100 |

### Classic Map Color Group Analysis

| Color Group | Properties | Total Cost | Priority | Reason |
|------------|-----------|------------|----------|--------|
| Orange | $180+$180+$200=$560 | ⭐⭐⭐⭐⭐ | 6-9 spaces after Jail, highest landing prob. |
| Red | $220+$220+$240=$680 | ⭐⭐⭐⭐ | 11-13 spaces after Jail, good probability |
| Light Blue | $100+$100+$120=$320 | ⭐⭐⭐⭐ | Cheapest, fastest to complete, quick ROI |
| Pink | $140+$140+$160=$440 | ⭐⭐⭐ | 1-4 spaces after Jail, moderate upgrade cost |
| Brown | $60+$60=$120 | ⭐⭐⭐ | Cheapest, 2-property group easy to complete |
| Yellow | $260+$280=$540 | ⭐⭐ | 2-property group, expensive |
| Green | $300+$300+$320=$920 | ⭐ | Too expensive, hard to complete |
| Blue | $350+$400=$750 | ⭐ | End of board, rarely reached by opponents |

**Starting Cash: $1500**

---

## 6. Future Development Suggestions

### 6.1 Advanced Strategies

- **Mortgage Financing**: Auto-mortgage low-value properties when buying key property
- **Auction Strategy**: Bidding strategy for auction participation
- **Trade Strategy**: Property valuation and negotiation for player trades
- **Stock Market**: Portfolio considerations if stock market is enabled

### 6.2 Machine Learning

- Use [`MonteCarloAgent`](crates/infra/src/ai.rs) in `crates/infra/src/ai.rs` as baseline
- Consider rule-based AI + MCTS hybrid strategy

### 6.3 Configuration

- Move strategy parameters (score weights, thresholds, etc.) to config files
- Support preset configurations for different difficulty levels

### 6.4 LLM Integration

- [`ConfigurableLlmClient`](crates/infra/src/llm.rs) in `crates/infra/src/llm.rs` supports rule overrides
- "Expert advice" mode: AI decides by rules, then LLM suggests corrections via prompt
