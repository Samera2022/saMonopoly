use serde::{Deserialize, Serialize};

use crate::types::{Money, PlayerId, TileId};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Player {
    pub id: PlayerId,
    pub name: String,
    pub cash: Money,
    pub position: TileId,
    pub is_ai: bool,
    pub is_llm_controlled: bool,
    pub jail_turns: u32,
    pub hospital_turns: u32,
    /// Card IDs owned by the player (e.g. "get_out_of_jail", "bonus_200", "double_rent")
    pub owned_cards: Vec<String>,
    /// Number of shares owned in the stock market
    pub stock_shares: u32,
}

impl Player {
    pub fn can_afford(&self, amount: Money) -> bool {
        self.cash >= amount
    }

    pub fn is_bankrupt(&self) -> bool {
        self.cash < 0
    }

    pub fn is_in_jail(&self) -> bool {
        self.jail_turns > 0
    }

    pub fn is_in_hospital(&self) -> bool {
        self.hospital_turns > 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_can_afford() {
        let player = Player {
            id: "p1".to_string(),
            name: "Alice".to_string(),
            cash: 1000,
            position: "GO".to_string(),
            is_ai: false,
            is_llm_controlled: false,
            jail_turns: 0,
            hospital_turns: 0,
            owned_cards: vec![],
            stock_shares: 0,
        };

        assert!(player.can_afford(500));
        assert!(player.can_afford(1000));
        assert!(!player.can_afford(1500));
    }

    #[test]
    fn test_is_in_jail() {
        let player = Player {
            id: "p2".to_string(),
            name: "Bob".to_string(),
            cash: 500,
            position: "Jail".to_string(),
            is_ai: false,
            is_llm_controlled: false,
            jail_turns: 3,
            hospital_turns: 0,
            owned_cards: vec![],
            stock_shares: 0,
        };
        assert!(player.is_in_jail());
    }

    #[test]
    fn test_is_in_hospital() {
        let player = Player {
            id: "p3".to_string(),
            name: "Charlie".to_string(),
            cash: 300,
            position: "Hospital".to_string(),
            is_ai: false,
            is_llm_controlled: false,
            jail_turns: 0,
            hospital_turns: 2,
            owned_cards: vec![],
            stock_shares: 0,
        };
        assert!(player.is_in_hospital());
    }

    #[test]
    fn test_not_in_jail_by_default() {
        let player = Player {
            id: "p4".to_string(),
            name: "Diana".to_string(),
            cash: 1500,
            position: "GO".to_string(),
            is_ai: false,
            is_llm_controlled: false,
            jail_turns: 0,
            hospital_turns: 0,
            owned_cards: vec![],
            stock_shares: 0,
        };
        assert!(!player.is_in_jail());
        assert!(!player.is_in_hospital());
    }
}
