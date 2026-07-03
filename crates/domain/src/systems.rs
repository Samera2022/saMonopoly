use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CardDeckId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LotteryRuleSet {
    pub enabled: bool,
    pub ticket_price: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StockMarketRuleSet {
    pub enabled: bool,
    pub tick_interval_turns: u64,
}
