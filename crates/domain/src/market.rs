use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StockMarketRule {
    pub id: String,
    pub start_index: i64,
    pub volatility: u32,
    pub current_index: i64,
}

impl StockMarketRule {
    /// Simulate a price tick using a random walk.
    /// 50% chance of rising, 50% chance of falling,
    /// with magnitude controlled by volatility.
    pub fn tick(&mut self, rng: &mut impl FnMut() -> u64) {
        let direction = if rng().is_multiple_of(2) { 1 } else { -1 };
        let step = (rng() % self.volatility as u64) as i64;
        self.current_index += direction * step;
    }

    /// Return the current price (start_index + current_index).
    pub fn current_price(&self) -> i64 {
        self.start_index + self.current_index
    }
}
