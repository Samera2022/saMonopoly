use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LotteryRule {
    pub id: String,
    pub draw_cost: i64,
    pub payout_table: Vec<i64>,
}
