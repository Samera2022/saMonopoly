use std::collections::{HashSet, VecDeque};

use sa_monopoly_domain::Board;

/// Represents a single issue found during map validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValidationIssue {
    /// A tile references a property kind but no matching property exists.
    TileWithoutProperty { tile_id: String },
    /// A property references a tile_id that does not exist in the board tiles.
    PropertyWithoutTile { tile_id: String },
    /// A tile is not reachable from the Start tile via graph edges.
    DisconnectedTile { tile_id: String },
    /// A property has a negative base price.
    NegativePrice { tile_id: String, price: i64 },
    /// Duplicate tile IDs found in the board.
    DuplicateTileId { tile_id: String },
    /// A tile cannot be reached via graph traversal (also unreachable).
    UnreachableTile { tile_id: String },
    /// A non-fatal economic balance warning.
    EconomicWarning { message: String },
}

impl std::fmt::Display for ValidationIssue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ValidationIssue::TileWithoutProperty { tile_id } => {
                write!(f, "Tile '{tile_id}' has a linked property kind but no matching property")
            }
            ValidationIssue::PropertyWithoutTile { tile_id } => {
                write!(f, "Property references tile '{tile_id}' which does not exist")
            }
            ValidationIssue::DisconnectedTile { tile_id } => {
                write!(
                    f,
                    "Tile '{tile_id}' is not connected to the graph via any edge"
                )
            }
            ValidationIssue::NegativePrice { tile_id, price } => {
                write!(f, "Property on tile '{tile_id}' has negative price: {price}")
            }
            ValidationIssue::DuplicateTileId { tile_id } => {
                write!(f, "Duplicate tile ID: '{tile_id}'")
            }
            ValidationIssue::UnreachableTile { tile_id } => {
                write!(
                    f,
                    "Tile '{tile_id}' is unreachable from Start via graph edges"
                )
            }
            ValidationIssue::EconomicWarning { message } => {
                write!(f, "Economic warning: {message}")
            }
        }
    }
}

/// A validator that checks a [`Board`] for structural and economic issues.
pub struct MapValidator;

impl MapValidator {
    /// Runs all validation checks against the given [`Board`] and returns
    /// a list of [`ValidationIssue`]s found. Returns an empty vec if the
    /// board is valid.
    pub fn validate(board: &Board) -> Vec<ValidationIssue> {
        let mut issues = Vec::new();

        // ── 1. Duplicate tile IDs ──────────────────────────────────────────
        let mut seen_ids = HashSet::new();
        for tile in &board.tiles {
            if !seen_ids.insert(&tile.id) {
                issues.push(ValidationIssue::DuplicateTileId {
                    tile_id: tile.id.clone(),
                });
            }
        }

        // ── 2. Tile → Property consistency (tile has linked_property_kind but no property) ──
        for tile in &board.tiles {
            if tile.linked_property_kind.is_some() {
                let has_property = board.properties.iter().any(|p| p.tile_id == tile.id);
                if !has_property {
                    issues.push(ValidationIssue::TileWithoutProperty {
                        tile_id: tile.id.clone(),
                    });
                }
            }
        }

        // ── 3. Property → Tile consistency ─────────────────────────────────
        for prop in &board.properties {
            let tile_exists = board.tiles.iter().any(|t| t.id == prop.tile_id);
            if !tile_exists {
                issues.push(ValidationIssue::PropertyWithoutTile {
                    tile_id: prop.tile_id.clone(),
                });
            }
        }

        // ── 4. Negative prices ─────────────────────────────────────────────
        for prop in &board.properties {
            if prop.base_price < 0 {
                issues.push(ValidationIssue::NegativePrice {
                    tile_id: prop.tile_id.clone(),
                    price: prop.base_price,
                });
            }
        }

        // ── 5. Graph connectivity (BFS from first tile) ────────────────────
        if !board.graph.edges.is_empty() {
            // Build adjacency list for efficient traversal
            let mut adjacency: std::collections::HashMap<&str, Vec<&str>> =
                std::collections::HashMap::new();
            for edge in &board.graph.edges {
                adjacency.entry(edge.from.as_str()).or_default().push(&edge.to);
            }
            // Also include teleporter connections
            for tp in &board.graph.teleporters {
                adjacency.entry(tp.from.as_str()).or_default().push(&tp.to);
            }

            // BFS from the first tile
            let start_id = match board.tiles.first() {
                Some(t) => &t.id,
                None => return issues, // No tiles → nothing to check
            };

            let mut visited: HashSet<&str> = HashSet::new();
            let mut queue = VecDeque::new();
            visited.insert(start_id);
            queue.push_back(start_id.as_str());

            while let Some(current) = queue.pop_front() {
                if let Some(neighbors) = adjacency.get(current) {
                    for &next in neighbors {
                        if visited.insert(next) {
                            queue.push_back(next);
                        }
                    }
                }
            }

            // Report all tiles not reached by BFS
            for tile in &board.tiles {
                if !visited.contains(tile.id.as_str()) {
                    issues.push(ValidationIssue::DisconnectedTile {
                        tile_id: tile.id.clone(),
                    });
                }
            }
        }

        // ── 6. Economic balance check ──────────────────────────────────────
        let total_property_value: i64 = board.properties.iter().map(|p| p.base_price).sum();
        if total_property_value > 0 {
            // A warning with the total property value for context.
            // The caller can decide whether the ratio is acceptable.
            issues.push(ValidationIssue::EconomicWarning {
                message: format!(
                    "Total property base_price sum is {total_property_value}. \
                     Ensure this is balanced relative to player starting cash \
                     (typically 1500 per player)."
                ),
            });
        }

        issues
    }

    /// Convenience method that returns `Ok(())` if no issues are found,
    /// or `Err(issues)` with all found issues.
    pub fn validate_ok(board: &Board) -> Result<(), Vec<ValidationIssue>> {
        let issues = Self::validate(board);
        if issues.is_empty() {
            Ok(())
        } else {
            Err(issues)
        }
    }
}

#[cfg(test)]
mod tests {
    use sa_monopoly_domain::{
        BoardEdge, BoardGraph, Property, PropertyKind, Tile, TileKind, Teleporter,
    };

    use super::*;

    fn make_board(tiles: Vec<Tile>, properties: Vec<Property>, graph: BoardGraph) -> Board {
        Board {
            tiles,
            properties,
            graph,
        }
    }

    fn make_tile(id: &str, kind: TileKind, linked_property_kind: Option<PropertyKind>) -> Tile {
        Tile {
            id: id.to_string(),
            name_key: format!("tile.{id}"),
            kind,
            linked_property_kind,
        }
    }

    fn make_property(tile_id: &str, base_price: i64) -> Property {
        Property {
            tile_id: tile_id.to_string(),
            name_key: format!("prop.{tile_id}"),
            kind: PropertyKind::Ordinary,
            base_price,
            rent: vec![10, 20, 30],
            upgrade_level: 0,
            owner: None,
            is_mortgaged: false,
            linked_targets: vec![],
        }
    }

    // ── Duplicate Tile ID ─────────────────────────────────────────────────

    #[test]
    fn test_duplicate_tile_ids() {
        let board = make_board(
            vec![
                make_tile("GO", TileKind::Start, None),
                make_tile("GO", TileKind::Start, None), // duplicate
            ],
            vec![],
            BoardGraph::default(),
        );
        let issues = MapValidator::validate(&board);
        assert!(issues.iter().any(|i| matches!(
            i,
            ValidationIssue::DuplicateTileId { tile_id } if tile_id == "GO"
        )));
    }

    // ── Tile without Property ─────────────────────────────────────────────

    #[test]
    fn test_tile_without_property() {
        let board = make_board(
            vec![make_tile(
                "P1",
                TileKind::OrdinaryProperty,
                Some(PropertyKind::Ordinary),
            )],
            vec![], // no matching property
            BoardGraph::default(),
        );
        let issues = MapValidator::validate(&board);
        assert!(issues.iter().any(|i| matches!(
            i,
            ValidationIssue::TileWithoutProperty { tile_id } if tile_id == "P1"
        )));
    }

    // ── Property without Tile ─────────────────────────────────────────────

    #[test]
    fn test_property_without_tile() {
        let board = make_board(
            vec![make_tile("GO", TileKind::Start, None)],
            vec![make_property("P1", 200)], // P1 does not exist in tiles
            BoardGraph::default(),
        );
        let issues = MapValidator::validate(&board);
        assert!(issues.iter().any(|i| matches!(
            i,
            ValidationIssue::PropertyWithoutTile { tile_id } if tile_id == "P1"
        )));
    }

    // ── Negative Price ────────────────────────────────────────────────────

    #[test]
    fn test_negative_price() {
        let board = make_board(
            vec![make_tile("P1", TileKind::OrdinaryProperty, Some(PropertyKind::Ordinary))],
            vec![make_property("P1", -100)],
            BoardGraph::default(),
        );
        let issues = MapValidator::validate(&board);
        assert!(issues.iter().any(|i| matches!(
            i,
            ValidationIssue::NegativePrice { tile_id, price } if tile_id == "P1" && *price == -100
        )));
    }

    // ── Graph Connectivity ────────────────────────────────────────────────

    #[test]
    fn test_disconnected_tile() {
        let board = make_board(
            vec![
                make_tile("A", TileKind::Start, None),
                make_tile("B", TileKind::OrdinaryProperty, Some(PropertyKind::Ordinary)),
                make_tile("C", TileKind::OrdinaryProperty, Some(PropertyKind::Ordinary)),
            ],
            vec![make_property("B", 100), make_property("C", 100)],
            BoardGraph {
                edges: vec![BoardEdge {
                    from: "A".to_string(),
                    to: "B".to_string(),
                    label: None,
                }],
                teleporters: vec![],
            },
        );
        let issues = MapValidator::validate(&board);
        // C is disconnected
        assert!(issues.iter().any(|i| matches!(
            i,
            ValidationIssue::DisconnectedTile { tile_id } if tile_id == "C"
        )));
        // A and B should not be disconnected
        assert!(!issues.iter().any(|i| matches!(
            i,
            ValidationIssue::DisconnectedTile { tile_id } if tile_id == "A" || tile_id == "B"
        )));
    }

    #[test]
    fn test_connected_graph_no_issues() {
        let board = make_board(
            vec![
                make_tile("GO", TileKind::Start, None),
                make_tile("P1", TileKind::OrdinaryProperty, Some(PropertyKind::Ordinary)),
                make_tile("P2", TileKind::OrdinaryProperty, Some(PropertyKind::Ordinary)),
            ],
            vec![make_property("P1", 200), make_property("P2", 150)],
            BoardGraph {
                edges: vec![
                    BoardEdge {
                        from: "GO".to_string(),
                        to: "P1".to_string(),
                        label: None,
                    },
                    BoardEdge {
                        from: "P1".to_string(),
                        to: "P2".to_string(),
                        label: None,
                    },
                    BoardEdge {
                        from: "P2".to_string(),
                        to: "GO".to_string(),
                        label: None,
                    },
                ],
                teleporters: vec![],
            },
        );
        let issues = MapValidator::validate(&board);
        // Should only have the economic warning
        for issue in &issues {
            assert!(
                matches!(issue, ValidationIssue::EconomicWarning { .. }),
                "Unexpected issue: {issue:?}"
            );
        }
    }

    #[test]
    fn test_teleporter_connectivity() {
        let board = make_board(
            vec![
                make_tile("GO", TileKind::Start, None),
                make_tile("P1", TileKind::OrdinaryProperty, Some(PropertyKind::Ordinary)),
                make_tile("Far", TileKind::OrdinaryProperty, Some(PropertyKind::Ordinary)),
            ],
            vec![make_property("P1", 200), make_property("Far", 300)],
            BoardGraph {
                edges: vec![BoardEdge {
                    from: "GO".to_string(),
                    to: "P1".to_string(),
                    label: None,
                }],
                teleporters: vec![Teleporter {
                    from: "P1".to_string(),
                    to: "Far".to_string(),
                    condition: None,
                }],
            },
        );
        let issues = MapValidator::validate(&board);
        // Far should be reachable via the teleporter from P1
        assert!(!issues.iter().any(|i| matches!(
            i,
            ValidationIssue::DisconnectedTile { tile_id } if tile_id == "Far"
        )));
    }

    // ── Empty Board ───────────────────────────────────────────────────────

    #[test]
    fn test_empty_tiles_no_crash() {
        let board = make_board(vec![], vec![], BoardGraph::default());
        let issues = MapValidator::validate(&board);
        // No tiles → no issues (nothing to disconnect)
        assert!(issues.is_empty());
    }

    // ── Economic Warning ──────────────────────────────────────────────────

    #[test]
    fn test_economic_warning_present() {
        let board = make_board(
            vec![
                make_tile("GO", TileKind::Start, None),
                make_tile("P1", TileKind::OrdinaryProperty, Some(PropertyKind::Ordinary)),
            ],
            vec![make_property("P1", 2000)],
            BoardGraph::default(),
        );
        let issues = MapValidator::validate(&board);
        assert!(issues.iter().any(|i| matches!(i, ValidationIssue::EconomicWarning { .. })));
    }

    // ── validate_ok convenience ───────────────────────────────────────────

    #[test]
    fn test_validate_ok_valid_board() {
        let board = make_board(
            vec![make_tile("GO", TileKind::Start, None)],
            vec![],
            BoardGraph::default(),
        );
        assert!(MapValidator::validate_ok(&board).is_ok());
    }

    #[test]
    fn test_validate_ok_invalid_board() {
        let board = make_board(
            vec![make_tile("GO", TileKind::Start, None)],
            vec![make_property("P1", -100)],
            BoardGraph::default(),
        );
        assert!(MapValidator::validate_ok(&board).is_err());
    }
}
