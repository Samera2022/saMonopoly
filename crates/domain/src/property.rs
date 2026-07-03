use serde::{Deserialize, Serialize};

use crate::types::{Money, TileId};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PropertyKind {
    Ordinary,
    Special(SpecialPropertyKind),
    Extension,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SpecialPropertyKind {
    CardShop,
    Lottery,
    Bank,
    Opportunity,
    Jail,
    Hospital,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Property {
    pub tile_id: TileId,
    pub name_key: String,
    pub kind: PropertyKind,
    pub base_price: Money,
    pub rent: Vec<Money>,
    pub upgrade_level: u32,
    pub owner: Option<String>,
    #[serde(default)]
    pub is_mortgaged: bool,
}

impl Property {
    pub fn current_rent(&self) -> Money {
        if self.is_mortgaged {
            return 0;
        }
        self.rent
            .get(self.upgrade_level as usize)
            .copied()
            .or_else(|| self.rent.last().copied())
            .unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_current_rent_normal() {
        let prop = Property {
            tile_id: "P1".to_string(),
            name_key: "prop.p1".to_string(),
            kind: PropertyKind::Ordinary,
            base_price: 200,
            rent: vec![10, 20, 30, 40],
            upgrade_level: 0,
            owner: None,
            is_mortgaged: false,
        };
        assert_eq!(prop.current_rent(), 10);

        let prop_upgraded = Property {
            upgrade_level: 2,
            ..prop
        };
        assert_eq!(prop_upgraded.current_rent(), 30);
    }

    #[test]
    fn test_current_rent_beyond_table() {
        let prop = Property {
            tile_id: "P2".to_string(),
            name_key: "prop.p2".to_string(),
            kind: PropertyKind::Ordinary,
            base_price: 150,
            rent: vec![5, 10, 15],
            upgrade_level: 10, // beyond table length
            owner: None,
            is_mortgaged: false,
        };
        // Should return the last rent value (15)
        assert_eq!(prop.current_rent(), 15);
    }

    #[test]
    fn test_current_rent_empty_table() {
        let prop = Property {
            tile_id: "P3".to_string(),
            name_key: "prop.p3".to_string(),
            kind: PropertyKind::Ordinary,
            base_price: 100,
            rent: vec![], // empty rent table
            upgrade_level: 0,
            owner: None,
            is_mortgaged: false,
        };
        assert_eq!(prop.current_rent(), 0);
    }

    #[test]
    fn test_current_rent_mortgaged() {
        let prop = Property {
            tile_id: "P4".to_string(),
            name_key: "prop.p4".to_string(),
            kind: PropertyKind::Ordinary,
            base_price: 200,
            rent: vec![10, 20, 30],
            upgrade_level: 0,
            owner: Some("player_1".to_string()),
            is_mortgaged: true,
        };
        assert_eq!(prop.current_rent(), 0);
    }
}
