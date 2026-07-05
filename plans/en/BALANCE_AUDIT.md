# Balance Audit Report — saMonopoly

## Overview

This report evaluates the balance of saMonopoly's game parameters based on a thorough review of the domain layer (`crates/domain/src/`) and application layer (`crates/application/src/`) code, as well as the default map and content pack configurations.

---

## 1. Initial Configuration

| Parameter | Default Value | Notes |
|-----------|--------------|-------|
| `starting_cash` | 1500 | Standard Monopoly baseline |
| `pass_start_bonus` | 200 | Standard |
| `max_upgrade_level` | 3 | Allows 4 rent tiers (L0–L3) |
| `jail_escape_turns` | 3 | Standard |
| `hospital_recovery_turns` | 2 | Custom mechanic |
| `group_rent_enabled` | **false** | ⚠️ Disabled by default |
| `extension_upgrade_enabled` | **false** | Disabled by default |
| `max_players` | 4 | Standard |

**Assessment:** Reasonable baseline, consistent with classic Monopoly.

---

## 2. Property Economy — Core Formulas

### Rent Formula
```
rent = base * (1 + level) / 10
```

| Level | Rent % of Base | Example ($100 prop) | Example ($400 prop) |
|-------|---------------|--------------------|--------------------|
| 0     | 10%           | $10                | $40                |
| 1     | 20%           | $20                | $80                |
| 2     | 30%           | $30                | $120               |
| 3     | 40%           | $40                | $160               |

### Upgrade Cost Formula
```
cost = base * (1 + current_level) / 2
```

| Upgrade | Cost % of Base | Cost ($100 prop) | Rent Increase | Payback Turns |
|---------|---------------|-----------------|--------------|--------------|
| L0 → L1 | 50%           | $50             | $10 → $20    | **5 turns**  |
| L1 → L2 | 100%          | $100            | $20 → $30    | **10 turns** |
| L2 → L3 | 150%          | $150            | $30 → $40    | **15 turns** |

### ⚠️ ISSUE #1: Diminishing Returns on Upgrades

The upgrade cost scales **linearly** (50%, 100%, 150% of base) while rent increases only **additively** (+10% per level). The payback period triples from 5 turns → 15 turns:

- L0→L1: Reasonable (5 turns to recoup)
- L1→L2: Borderline (10 turns — may be worth it in long games)
- **L2→L3: Uneconomical (15 turns — rarely worth the investment)**

In a standard 4-player game, each player only gets ~25% of landings, so you'd need **60 total turns** on average to recoup a L3 upgrade. Most games will end before this.

**Recommendation:** Either:
- (a) Reduce upgrade cost progression: e.g., `cost = base * (1 + level) / 3` (33%, 67%, 100%)
- (b) Increase rent scaling: e.g., `rent = base * (2 + level * 2) / 10` (20%, 40%, 60%, 80%)
- (c) Or adopt a non-linear rent formula: e.g. `base * (1 + level)^2 / 10` (10%, 40%, 90%, 160%)

---

## 3. Rent vs. Purchase Price — ROI Analysis

For a property costing **$100**:

| Metric | Value |
|--------|-------|
| Purchase price | $100 |
| Rent (L0) | $10 |
| **Base ROI period** | **10 landings** |
| Effective ROI (4 players) | ~40 turns |

For a **$400** high-value property:

| Metric | Value |
|--------|-------|
| Purchase price | $400 |
| Rent (L0) | $40 |
| **Base ROI period** | **10 landings** |
| Effective ROI (4 players) | ~40 turns |

### ⚠️ ISSUE #2: Uniform ROI Across All Price Tiers

Because both rent and cost scale linearly with base price, the ROI is identical (~10 landings) regardless of whether a property costs $100 or $400. This means:
- **No strategic differentiation** between cheap and expensive properties
- Expensive properties aren't actually more "valuable" in relative terms
- The risk/reward profile is flat

**Recommendation:** Consider a progressive rent formula where higher-priced properties yield proportionally better returns, e.g., `rent = base * (1 + level) / (8 + base/100)` or introduce a premium multiplier for expensive properties.

---

## 4. Group Rent System

Currently **disabled by default** (`group_rent_enabled: false`).

When enabled, owning all properties in a group sums their individual rents. For a group of 3 properties at level 0 ($10 each): total rent = **$30** (3× normal).

### ⚠️ ISSUE #3: Group Rent May Overpower Individual Rent

- Group rent of 3 properties at L0 ($30) exceeds a single L3 property ($40) for much less investment
- The group rent system encourages complete sets, which is good strategy, but:
  - **The gap between a partial set (no group rent) and a complete set (group rent) is too large** — it creates a "winner takes all" dynamic
  - If group rent is enabled, the player who first completes a color set can effectively dominate

**Recommendation:** If enabling group rent, consider a graduated bonus rather than a full sum, e.g. 1.5× the highest member's rent, or sum with a 20% discount.

---

## 5. Lottery System

| Parameter | Value |
|-----------|-------|
| Base jackpot | **$500** (33% of starting cash) |
| Jackpot growth | +$10/turn |
| Ticket price (start) | **$50** |
| Draw frequency | Every **15 turns** |
| Odds of winning | **1/50 = 2%** |
| Rollover multiplier | **1.5^consecutive_no_winner** |

### Expected Value Analysis

| Scenario | Odds | EV |
|----------|------|----|
| Turn 1, no rollover | 2% × $500 = $10 | $10 - $50 = **-$40** |
| Turn 15, 1 rollover | 2% × $750 = $15 | $15 - $55 = **-$40** |
| Turn 30, 1 rollover | 2% × $800 = $16 | $16 - $65 = **-$49** |
| After 5 rollovers | 2% × $7,594 = $152 | $152 - $85 = **+$67** |
| After 10 rollovers | 2% × $57,665 = $1,153 | $1,153 - $100 = **+$1,053** |

### ⚠️ ISSUE #4: Lottery EV is Deeply Negative Until Many Rollovers

For the first ~5 cycles (75+ turns), the lottery has strongly negative expected value (−$40 to −$50 per ticket). This is intended as a money sink, but:

- **Only whales benefit**: The exponential rollover (1.5^n) means jackpots explode after 5+ consecutive no-winners: 1.5^10 ≈ **57.7× the base**. A jackpot of $57,665 at turn 100 would instantly eliminate any semblance of game balance.
- **The bifurcation is extreme**: Either nobody wins for 10+ cycles and the jackpot becomes game-breaking, or someone wins early and the lottery feels pointless.

**Recommendation:**
- (a) Cap the rollover multiplier at, say, 3.0× (after ~3 rollovers)
- (b) Increase base jackpot to $800–1,000 and reduce rollover growth to 1.2× instead of 1.5×
- (c) Or change to a tiered prize system (partial matching pays smaller amounts)

---

## 6. Card System

| Card | Effect | Balance Assessment |
|------|--------|-------------------|
| `get_out_of_jail` | Instant jail release | ✅ **Essential**, reasonable |
| `bonus_200` | +$200 cash | ✅ Good, equivalent to 1 pass-start bonus |
| `double_rent` | ×2 rent for one payment | ⚠️ **Potentially problematic** |
| `skip_turn` | Skip next turn | ⚠️ **Weak/negative effect** |

### ⚠️ ISSUE #5: `skip_turn` Card is Strictly Negative

The `skip_turn` card causes the player to miss their next turn (via `jail_turns = 1`). This is a **detrimental effect** that no rational player would pay for or choose to use. It should either:
- Be removed from purchasable cards, or
- Be reworked as a weapon card ("Force skip on opponent"), or
- Be reworked as a strategic tool ("Skip this turn to avoid paying rent")

### ⚠️ ISSUE #6: `double_rent` Card Has No Counterplay

The `double_rent` card is consumed automatically when paying rent, doubling the amount. This provides no counterplay for the payer. Combined with group rent, a player could theoretically force a rent payment of `2 × 3 × $40 = $240` on a single landing — potentially bankrupting an opponent in one turn.

**Recommendation:** Consider adding a maximum cap (e.g., "cannot exceed 2× base rent") or make the card optional for the payer.

### ⚠️ ISSUE #7: Card Prices Are Not Defined in Backend

Looking at [`crates/application/src/engine.rs`](crates/application/src/engine.rs:296), the `BuyCard` command accepts a `price` parameter from the client/frontend with **no server-side validation** of what the price should be. This means:

- A malicious client could send `price: 0` and get cards for free
- There's no standard pricing enforced — different frontends could have different prices

**Recommendation:** Define card prices as constants in the domain or application layer:
```rust
const CARD_PRICES: &[(&str, i64)] = &[
    ("get_out_of_jail", 150),
    ("bonus_200", 100),
    ("double_rent", 200),
    ("skip_turn", 50),
];
```
And validate: `if price != CARD_PRICE[card_id] { reject }`.

---

## 7. Tax & Bonus System

| Tile | Amount | % of Starting Cash | Assessment |
|------|--------|-------------------|------------|
| Income Tax | **−$200** | 13.3% | ⚠️ **High for early game** |
| Luxury Tax | −$100 | 6.7% | Reasonable |
| Free Parking | +$200 | 13.3% | Windfall |

### ⚠️ ISSUE #8: Income Tax ($200) is Punishing

At $200, income tax represents **13.3% of starting cash**. In classic Monopoly, Income Tax is either 10% of total worth or $200 (whichever is less). The current flat $200 is fine for mid-game but can be devastating in the first circuit (potentially eliminating nearly all liquid cash).

**Recommendation:** Consider making it `min(200, total_worth / 10)` or reducing to $150.

---

## 8. Jail & Hospital

| Mechanic | Value | Assessment |
|----------|-------|-----------|
| Jail escape turns | 3 | ✅ Standard |
| Hospital recovery turns | 2 | ✅ Reasonable |
| Bail payment option | **None** | ⚠️ **Missing** |
| `get_out_of_jail` card | Available | ✅ |

### ⚠️ ISSUE #9: No Bail Option for Jail

Players cannot pay to get out of jail early. Classic Monopoly has a $50 bail option. Without it, players are **completely stuck** for 3 turns, unable to act. This is especially frustrating for a player who lands on "Go To Jail" early in the game.

**Recommendation:** Add a bail option in [`engine.rs`](crates/application/src/engine.rs:64):
```rust
// During roll, if jail_turns > 0, offer bail option:
if player.cash >= 50 {
    // Allow player to pay $50 to release immediately
}
```

---

## 9. Mortgage System

| Parameter | Value | Assessment |
|-----------|-------|-----------|
| Loan amount | 50% of base_price | ✅ Standard |
| Redemption cost | 50% + 10% = 60% | ✅ 10% interest is fair |
| Mortgaged rent | $0 | ✅ Standard |

**Assessment:** ✅ Well balanced, matches classic Monopoly convention.

---

## 10. Auction System

| Parameter | Assessment |
|-----------|-----------|
| Starting bid = player-defined | ✅ Flexible |
| Increment = +1 minimum | ⚠️ Very small increment could lead to many bids |
| No time limit | Depends on frontend implementation |

**Assessment:** ✅ Reasonable design.

---

## 11. Stock Market

| Parameter | Assessment |
|-----------|-----------|
| Random walk (50/50 up/down) | ✅ Simple and fair |
| Volatility control | ✅ Per-map parameter |
| Default: **disabled** | ✅ Good as optional feature |

**Assessment:** ✅ The stock market is well-designed as an optional side system.

---

## 12. Consecutive Sum-7 → Jail Rule

| Aspect | Value |
|--------|-------|
| Trigger condition | 3 consecutive sum-7 rolls |
| Probability of 3× sum-7 | (6/36)^3 = **0.46%** |
| Risk of false positive | Extremely low |

**Assessment:** ✅ Replaces the traditional "three doubles" rule with an equivalent statistical trigger. Well balanced.

---

## 13. Classic Map Configuration

The default [`classic.json`](content/maps/builtin/classic.json) map has only **4 tiles** (start, property_1, opportunity_1, bank_1). This is a **placeholder** — a production game needs 28–40 tiles for a proper game loop.

**Assessment:** ⚠️ Insufficient for balanced gameplay. The balance analysis above assumes a full board of ~28–40 tiles.

---

## Summary of Issues by Severity

### 🔴 Critical
| # | Issue | Location | Fix Priority |
|---|-------|----------|-------------|
| 7 | Card prices unvalidated server-side — client can set arbitrary prices | [`engine.rs:296`](crates/application/src/engine.rs:296) | **Immediate** |
| 3 | Group rent creates winner-take-all dynamic | [`economy.rs:224-228`](crates/application/src/economy.rs:224-228) | High if enabling |
| 9 | No bail option from jail — players stuck for 3 turns | [`engine.rs:64-75`](crates/application/src/engine.rs:64-75) | **High** |

### 🟡 Moderate
| # | Issue | Location | Fix Priority |
|---|-------|----------|-------------|
| 1 | L2→L3 upgrade payback (15 turns) is uneconomical | [`property.rs:81`](crates/domain/src/property.rs:81) | Medium |
| 2 | Uniform ROI across all price tiers — no strategic differentiation | [`property.rs:71`](crates/domain/src/property.rs:71) | Medium |
| 4 | Lottery exponential rollover (1.5^n) can create game-breaking jackpots | [`lottery.rs:67`](crates/domain/src/lottery.rs:67) | Medium |
| 8 | Income tax ($200 = 13.3% of starting cash) too punishing early game | [`effects.rs:57`](crates/application/src/effects.rs:57) | Low-Medium |

### 🟢 Minor
| # | Issue | Location | Fix Priority |
|---|-------|----------|-------------|
| 5 | `skip_turn` card is strictly negative for the user | [`economy.rs:194`](crates/application/src/economy.rs:194) | Low |
| 6 | `double_rent` has no cap or counterplay | [`economy.rs:231-246`](crates/application/src/economy.rs:231-246) | Low |
| 13 | Classic map is only 4 tiles — placeholder for production | [`classic.json`](content/maps/builtin/classic.json) | Low |

---

## Recommended Quick Wins

1. **Fix card pricing** — Define constants and validate server-side
2. **Add jail bail** — Allow $50 payment to leave jail early
3. **Cap lottery rollover** — Limit 1.5^n to max 3.0×
4. **Smooth upgrade curve** — Change upgrade cost to `base * (1 + level) / 3`

---

*Audit performed on all domain and application source files as of the current codebase.*
