use serde::{Deserialize, Serialize};

use crate::types::{Money, TileId};

/// Base rent ratio: rent = base_price * RENT_RATIO_NUM / RENT_RATIO_DEN
/// At upgrade level 0, rent = base_price * 1/10 = 10% of base price.
const RENT_RATIO_NUM: i64 = 1;
const RENT_RATIO_DEN: i64 = 10;

/// Upgrade cost ratio: cost = base_price * UPGRADE_COST_RATIO_NUM / UPGRADE_COST_RATIO_DEN
/// At upgrade level 0, cost = base_price * 1/3 ≈ 33% of base price.
/// At level 1, cost = base_price * 2/3 ≈ 67%; at level 2, cost = base_price * 3/3 = 100%.
/// This softer curve (vs. 1/2) ensures higher-level upgrades remain economical.
const UPGRADE_COST_RATIO_NUM: i64 = 1;
const UPGRADE_COST_RATIO_DEN: i64 = 3;

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
    /// IDs of other properties that form a group with this one.
    /// When group rent is enabled and all properties in the group are owned
    /// by the same player, the rent paid is the sum of all group members'
    /// individual rent.
    #[serde(default)]
    pub linked_targets: Vec<TileId>,
}

impl Property {
    /// Calculate the current rent using a formula based on upgrade level.
    ///
    /// Rent is always derived from `base_price`, ensuring different properties
    /// have proportionally different rents based on their purchase price.
    ///
    /// Formula: `base_price * (1 + level) / 10`
    /// - level 0: 10% of base price
    /// - level 1: 20% of base price
    /// - level 2: 30% of base price
    /// - level 3: 40% of base price
    ///
    /// Example: a $100 property at level 0 charges $10 rent;
    ///          a $400 property at level 0 charges $40 rent.
    ///
    /// If the property is mortgaged, rent is 0.
    pub fn current_rent(&self) -> Money {
        if self.is_mortgaged {
            return 0;
        }
        let level = self.upgrade_level as i64;
        self.base_price * (RENT_RATIO_NUM + level) / RENT_RATIO_DEN
    }

    /// Calculate the cost to upgrade this property from its current level.
    ///
    /// Cost is always derived from `base_price`, so upgrading a more expensive
    /// property costs proportionally more.
    ///
    /// Formula: `base_price * (1 + current_level) / 3`
    /// - level 0→1: ~33% of base price
    /// - level 1→2: ~67% of base price
    /// - level 2→3: 100% of base price
    /// - etc.
    pub fn upgrade_cost(&self) -> Money {
        let level = self.upgrade_level as i64;
        self.base_price * (UPGRADE_COST_RATIO_NUM + level) / UPGRADE_COST_RATIO_DEN
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
            linked_targets: vec![],
        }
    }

    #[test]
    fn test_current_rent_formula_level_0() {
        // level 0: base_price * (1 + 0) / 10 = base_price / 10
        let prop = make_prop(200, vec![], 0);
        assert_eq!(prop.current_rent(), 200 * 1 / 10);
    }

    #[test]
    fn test_current_rent_formula_level_1() {
        // level 1: base_price * (1 + 1) / 10 = base_price * 2 / 10
        let prop = make_prop(200, vec![], 1);
        assert_eq!(prop.current_rent(), 200 * 2 / 10);
    }

    #[test]
    fn test_current_rent_formula_level_2() {
        // level 2: base_price * (1 + 2) / 10 = base_price * 3 / 10
        let prop = make_prop(200, vec![], 2);
        assert_eq!(prop.current_rent(), 200 * 3 / 10);
    }

    #[test]
    fn test_current_rent_scales_with_price() {
        // A $400 property charges 4× the rent of a $100 property
        let cheap = make_prop(100, vec![], 0);
        let expensive = make_prop(400, vec![], 0);
        assert_eq!(expensive.current_rent(), cheap.current_rent() * 4);
    }

    #[test]
    fn test_current_rent_mortgaged() {
        let mut prop = make_prop(200, vec![], 1);
        prop.is_mortgaged = true;
        assert_eq!(prop.current_rent(), 0);
    }

    #[test]
    fn test_upgrade_cost_level_0() {
        // level 0→1: base_price * (1 + 0) / 3 = base_price / 3
        let prop = make_prop(200, vec![], 0);
        assert_eq!(prop.upgrade_cost(), 200 * 1 / 3);
    }

    #[test]
    fn test_upgrade_cost_level_1() {
        // level 1→2: base_price * (1 + 1) / 3 = base_price * 2 / 3
        let prop = make_prop(200, vec![], 1);
        assert_eq!(prop.upgrade_cost(), 200 * 2 / 3);
    }

    #[test]
    fn test_upgrade_cost_level_2() {
        // level 2→3: base_price * (1 + 2) / 3 = base_price * 3 / 3 = base_price
        let prop = make_prop(200, vec![], 2);
        assert_eq!(prop.upgrade_cost(), 200 * 3 / 3);
    }
}
