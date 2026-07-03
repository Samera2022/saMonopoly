use sa_monopoly_domain::{LotteryRuleSet, StockMarketRuleSet};

pub struct LotteryService;

impl LotteryService {
    pub fn is_enabled(rules: &LotteryRuleSet) -> bool {
        rules.enabled
    }
}

pub struct StockMarketService;

impl StockMarketService {
    pub fn is_enabled(rules: &StockMarketRuleSet) -> bool {
        rules.enabled
    }
}
