use serde::{Deserialize, Serialize};

use crate::types::{Money, TileId};

/// Base rent ratio: rent = base_price * RENT_RATIO_NUM / RENT_RATIO_DEN
/// At upgrade level 0, rent = base_price * 1/10 = 10% of base price.
const RENT_RATIO_NUM: i64 = 1;
const RENT_RATIO_DEN: i64 = 10;

/// Upgrade cost ratio: cost = base_price * UPGRADE_COST_RATIO_NUM / UPGRADE_COST_RATIO_DEN
/// At upgrade level 0, cost = base_price * 1/2 = 50% of base price.
const UPGRADE_COST_RATIO_NUM: i64 = 1;
const UPGRADE_COST_RATIO_DEN: i64 = 2;

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
    /// Rent table (kept for backward compatibility with map data).
    /// When present, its first element is used as the base rent for formula
    /// calculation; otherwise the formula uses `base_price` directly.
    pub rent: Vec<Money>,
    pub upgrade_level: u32,
    pub owner: Option<String>,
    #[serde(default)]
    pub is_mortgaged: bool,
}

impl Property {
    /// Calculate the current rent using a formula based on upgrade level.
    ///
    /// Formula: `base * (1 + level) / 10`
    /// - level 0: 10% of base price
    /// - level 1: 20% of base price
    /// - level 2: 30% of base price
    /// - etc.
    ///
    /// If the property is mortgaged, rent is 0.
    pub fn current_rent(&self) -> Money {
        if self.is_mortgaged {
            return 0;
        }
        // Use `rent[0]` as the base if available, otherwise base_price.
        let base = self.rent.first().copied().unwrap_or(self.base_price);
        let level = self.upgrade_level as i64;
        base * (RENT_RATIO_NUM + level) / RENT_RATIO_DEN
    }

    /// Calculate the cost to upgrade this property from its current level.
    ///
    /// Formula: `base * (1 + current_level) / 2`
    /// - level 0→1: 50% of base price
    /// - level 1→2: 100% of base price
    /// - level 2→3: 150% of base price
    /// - etc.
    pub fn upgrade_cost(&self) -> Money {
        let base = self.rent.first().copied().unwrap_or(self.base_price);
        let level = self.upgrade_level as i64;
        base * (UPGRADE_COST_RATIO_NUM + level) / UPGRADE_COST_RATIO_DEN
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_prop(base_price: Money, rent: Vec<Money>, level: u32) -> Property {
        Property {
            tile_id: "P1".to_string(),
            name_key: "prop.p1".to_string(),
            kind: PropertyKind::Ordinary,
            base_price,
            rent,
            upgrade_level: level,
            owner: None,
            is_mortgaged: false,
        }
    }

    #[test]
    fn test_current_rent_formula_level_0() {
        // level 0: base * (1 + 0) / 10 = base / 10
        let prop = make_prop(200, vec![10], 0);
        assert_eq!(prop.current_rent(), 10 * 1 / 10);
    }

    #[test]
    fn test_current_rent_formula_level_1() {
        // level 1: base * (1 + 1) / 10 = base * 2 / 10
        let prop = make_prop(200, vec![10], 1);
        assert_eq!(prop.current_rent(), 10 * 2 / 10);
    }

    #[test]
    fn test_current_rent_formula_level_2() {
        // level 2: base * (1 + 2) / 10 = base * 3 / 10
        let prop = make_prop(200, vec![10], 2);
        assert_eq!(prop.current_rent(), 10 * 3 / 10);
    }

    #[test]
    fn test_current_rent_uses_rent0_as_base() {
        // When rent[0] is present, it's used as the base.
        let prop = make_prop(200, vec![15], 1);
        assert_eq!(prop.current_rent(), 15 * 2 / 10);
    }

    #[test]
    fn test_current_rent_falls_back_to_base_price() {
        // When rent is empty, base_price is used as the base.
        let prop = make_prop(200, vec![], 0);
        assert_eq!(prop.current_rent(), 200 * 1 / 10);
    }

    #[test]
    fn test_current_rent_mortgaged() {
        let mut prop = make_prop(200, vec![10], 1);
        prop.is_mortgaged = true;
        assert_eq!(prop.current_rent(), 0);
    }

    #[test]
    fn test_upgrade_cost_level_0() {
        // level 0→1: base * (1 + 0) / 2 = base / 2
        let prop = make_prop(200, vec![100], 0);
        assert_eq!(prop.upgrade_cost(), 100 * 1 / 2);
    }

    #[test]
    fn test_upgrade_cost_level_1() {
        // level 1→2: base * (1 + 1) / 2 = base * 2 / 2 = base
        let prop = make_prop(200, vec![100], 1);
        assert_eq!(prop.upgrade_cost(), 100 * 2 / 2);
    }

    #[test]
    fn test_upgrade_cost_level_2() {
        // level 2→3: base * (1 + 2) / 2 = base * 3 / 2
        let prop = make_prop(200, vec![100], 2);
        assert_eq!(prop.upgrade_cost(), 100 * 3 / 2);
    }

    #[test]
    fn test_upgrade_cost_falls_back_to_base_price() {
        let prop = make_prop(200, vec![], 0);
        assert_eq!(prop.upgrade_cost(), 200 * 1 / 2);
    }
}
