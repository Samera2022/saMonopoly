use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum GameCommand {
    Roll,
    BuyProperty { tile_id: String },
    UpgradeProperty { tile_id: String },
    PayRent { tile_id: String },
    EndTurn,
    /// Buy a card from the card shop
    BuyCard { card_id: String, price: i64 },
    /// Propose a trade between two players.
    Trade {
        from_player_id: String,
        to_player_id: String,
        offered_property: Option<String>,
        offered_cash: i64,
        requested_property: Option<String>,
        requested_cash: i64,
    },
    /// Start an auction for a property.
    Auction { tile_id: String, starting_bid: i64 },
    /// Place a bid in an active auction.
    Bid { player_id: String, amount: i64 },
    /// Mortgage a property for cash (50% of base price).
    Mortgage { tile_id: String },
    /// Redeem a mortgaged property (pay 50% of base price + 10% interest).
    Redeem { tile_id: String },
    /// Sell shares in the stock market at the current price.
    SellShares { player_id: String, shares: u32 },
    /// Get the full configuration document (returns ConfigLoaded event).
    ConfigGet,
    /// Set a configuration section (returns ConfigUpdated event).
    ConfigSet { section: String, value: serde_json::Value },
    /// Player buys a lottery ticket with a chosen number (1-50).
    BuyLotteryTicket { number: u32 },
    /// Player uses a card from their inventory.
    UseCard { card_id: String },
}
