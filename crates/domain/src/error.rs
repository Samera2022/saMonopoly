use thiserror::Error;

use crate::types::Money;

#[derive(Error, Debug, Clone, PartialEq)]
pub enum DomainError {
    #[error("player {0} not found")]
    PlayerNotFound(String),

    #[error("tile {0} not found")]
    TileNotFound(String),

    #[error("insufficient funds: have {have}, need {need}")]
    InsufficientFunds { have: Money, need: Money },

    #[error("property {tile_id} already owned by {owner}")]
    PropertyAlreadyOwned { tile_id: String, owner: String },

    #[error("property {0} not owned")]
    PropertyNotOwned(String),

    #[error("no active player")]
    ActivePlayerNotFound,

    #[error("game not started")]
    GameNotStarted,

    #[error("invalid command: {0}")]
    InvalidCommand(String),

    #[error("movement failed: {0}")]
    MovementFailed(String),

    #[error("card {0} not found")]
    CardNotFound(String),

    #[error("stock market not enabled")]
    StockMarketNotEnabled,

    #[error("lottery not enabled")]
    LotteryNotEnabled,

    #[error("auction error: {0}")]
    AuctionError(String),

    #[error("board error: {0}")]
    BoardError(String),

    #[error("upgrade not owned by active player: {0}")]
    UpgradeNotOwned(String),

    #[error("upgrades are disabled (max_upgrade_level = 0)")]
    UpgradesDisabled,

    #[error("property {0} already at max upgrade level {1}")]
    MaxUpgradeLevel(String, u64),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_messages() {
        // PlayerNotFound
        let err = DomainError::PlayerNotFound("Alice".to_string());
        assert_eq!(err.to_string(), "player Alice not found");

        // TileNotFound
        let err = DomainError::TileNotFound("GO".to_string());
        assert_eq!(err.to_string(), "tile GO not found");

        // InsufficientFunds
        let err = DomainError::InsufficientFunds { have: 100, need: 500 };
        assert_eq!(err.to_string(), "insufficient funds: have 100, need 500");

        // PropertyAlreadyOwned
        let err = DomainError::PropertyAlreadyOwned {
            tile_id: "Boardwalk".to_string(),
            owner: "Bob".to_string(),
        };
        assert_eq!(
            err.to_string(),
            "property Boardwalk already owned by Bob"
        );

        // PropertyNotOwned
        let err = DomainError::PropertyNotOwned("Park Place".to_string());
        assert_eq!(err.to_string(), "property Park Place not owned");

        // ActivePlayerNotFound
        let err = DomainError::ActivePlayerNotFound;
        assert_eq!(err.to_string(), "no active player");

        // BoardError
        let err = DomainError::BoardError("invalid board configuration".to_string());
        assert_eq!(err.to_string(), "board error: invalid board configuration");

        // GameNotStarted
        let err = DomainError::GameNotStarted;
        assert_eq!(err.to_string(), "game not started");

        // InvalidCommand
        let err = DomainError::InvalidCommand("roll".to_string());
        assert_eq!(err.to_string(), "invalid command: roll");

        // MovementFailed
        let err = DomainError::MovementFailed("no path".to_string());
        assert_eq!(err.to_string(), "movement failed: no path");

        // CardNotFound
        let err = DomainError::CardNotFound("get_out_of_jail".to_string());
        assert_eq!(err.to_string(), "card get_out_of_jail not found");

        // StockMarketNotEnabled
        let err = DomainError::StockMarketNotEnabled;
        assert_eq!(err.to_string(), "stock market not enabled");

        // LotteryNotEnabled
        let err = DomainError::LotteryNotEnabled;
        assert_eq!(err.to_string(), "lottery not enabled");

        // AuctionError
        let err = DomainError::AuctionError("bid too low".to_string());
        assert_eq!(err.to_string(), "auction error: bid too low");

        // UpgradeNotOwned
        let err = DomainError::UpgradeNotOwned("Park Place".to_string());
        assert_eq!(err.to_string(), "upgrade not owned by active player: Park Place");

        // UpgradesDisabled
        let err = DomainError::UpgradesDisabled;
        assert_eq!(err.to_string(), "upgrades are disabled (max_upgrade_level = 0)");

        // MaxUpgradeLevel
        let err = DomainError::MaxUpgradeLevel("Boardwalk".to_string(), 5);
        assert_eq!(err.to_string(), "property Boardwalk already at max upgrade level 5");
    }
}
