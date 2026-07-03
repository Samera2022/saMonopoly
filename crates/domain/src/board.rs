use serde::{Deserialize, Serialize};

use crate::property::Property;
use crate::tile::Tile;
use crate::types::TileId;

/// Represents a directed edge between two tiles in the board graph.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoardEdge {
    pub from: TileId,
    pub to: TileId,
    pub label: Option<String>,
}

/// Represents a teleportation link between two tiles, optionally gated by a condition.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Teleporter {
    pub from: TileId,
    pub to: TileId,
    pub condition: Option<String>,
}

/// A graph-based topology for the board, replacing the strictly linear layout.
///
/// When `edges` is empty, the board falls back to the legacy linear behavior.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct BoardGraph {
    pub edges: Vec<BoardEdge>,
    pub teleporters: Vec<Teleporter>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Board {
    pub tiles: Vec<Tile>,
    pub properties: Vec<Property>,
    pub graph: BoardGraph,
}

impl Board {
    pub fn tile_index(&self, tile_id: &str) -> Option<usize> {
        self.tiles.iter().position(|tile| tile.id == tile_id)
    }

    pub fn tile(&self, tile_id: &str) -> Option<&Tile> {
        self.tiles.iter().find(|tile| tile.id == tile_id)
    }

    pub fn property(&self, tile_id: &str) -> Option<&Property> {
        self.properties.iter().find(|property| property.tile_id == tile_id)
    }

    pub fn property_mut(&mut self, tile_id: &str) -> Option<&mut Property> {
        self.properties.iter_mut().find(|property| property.tile_id == tile_id)
    }

    /// Returns the next tile ID using the graph-based topology.
    /// Looks for the first edge where `from == current_tile_id`.
    pub fn graph_next_tile_id(&self, current_tile_id: &str) -> Option<TileId> {
        self.graph
            .edges
            .iter()
            .find(|edge| edge.from == current_tile_id)
            .map(|edge| edge.to.clone())
    }

    /// Returns the next tile ID in linear order (legacy fallback).
    ///
    /// When `graph.edges` is non-empty, delegates to [`graph_next_tile_id`];
    /// otherwise falls back to the sequential tile index.
    pub fn next_tile_id(&self, current_tile_id: &str) -> Option<TileId> {
        // Use graph-based lookup when edges are defined
        if !self.graph.edges.is_empty() {
            return self.graph_next_tile_id(current_tile_id);
        }

        // Legacy linear fallback
        let index = self.tile_index(current_tile_id)?;
        let next_index = (index + 1) % self.tiles.len();
        self.tiles.get(next_index).map(|tile| tile.id.clone())
    }
}

#[cfg(test)]
mod tests {
    use crate::property::Property;
    use crate::tile::{Tile, TileKind};
    use crate::types::Money;

    use super::*;

    fn make_tile(id: &str) -> Tile {
        Tile {
            id: id.to_string(),
            name_key: format!("tile.{}", id),
            kind: TileKind::Start,
            linked_property_kind: None,
        }
    }

    fn make_property(tile_id: &str, price: Money) -> Property {
        Property {
            tile_id: tile_id.to_string(),
            name_key: format!("prop.{}", tile_id),
            kind: crate::property::PropertyKind::Ordinary,
            base_price: price,
            rent: vec![10, 20, 30],
            upgrade_level: 0,
            owner: None,
            is_mortgaged: false,
        }
    }

    #[test]
    fn test_tile_index() {
        let board = Board {
            tiles: vec![make_tile("A"), make_tile("B"), make_tile("C")],
            properties: vec![],
            graph: BoardGraph::default(),
        };
        assert_eq!(board.tile_index("A"), Some(0));
        assert_eq!(board.tile_index("B"), Some(1));
        assert_eq!(board.tile_index("C"), Some(2));
        assert_eq!(board.tile_index("D"), None);
    }

    #[test]
    fn test_tile_lookup() {
        let board = Board {
            tiles: vec![make_tile("GO"), make_tile("Mediterranean")],
            properties: vec![],
            graph: BoardGraph::default(),
        };
        assert!(board.tile("GO").is_some());
        assert_eq!(board.tile("GO").unwrap().id, "GO");
        assert!(board.tile("NonExistent").is_none());
    }

    #[test]
    fn test_property_lookup() {
        let mut board = Board {
            tiles: vec![make_tile("GO"), make_tile("P1")],
            properties: vec![make_property("P1", 200)],
            graph: BoardGraph::default(),
        };

        // Immutable lookup
        let prop = board.property("P1");
        assert!(prop.is_some());
        assert_eq!(prop.unwrap().base_price, 200);
        assert!(board.property("GO").is_none());

        // Mutable lookup
        let mut_prop = board.property_mut("P1");
        assert!(mut_prop.is_some());
        mut_prop.unwrap().base_price = 300;
        assert_eq!(board.property("P1").unwrap().base_price, 300);
    }

    #[test]
    fn test_graph_next_tile() {
        let board = Board {
            tiles: vec![make_tile("A"), make_tile("B"), make_tile("C")],
            properties: vec![],
            graph: BoardGraph {
                edges: vec![
                    BoardEdge {
                        from: "A".to_string(),
                        to: "C".to_string(),
                        label: None,
                    },
                    BoardEdge {
                        from: "C".to_string(),
                        to: "B".to_string(),
                        label: Some("shortcut".to_string()),
                    },
                ],
                teleporters: vec![],
            },
        };
        // Graph edge A -> C
        assert_eq!(board.graph_next_tile_id("A"), Some("C".to_string()));
        // Graph edge C -> B
        assert_eq!(board.graph_next_tile_id("C"), Some("B".to_string()));
        // No edge from B
        assert_eq!(board.graph_next_tile_id("B"), None);
    }

    #[test]
    fn test_next_tile_id_linear_fallback() {
        let board = Board {
            tiles: vec![make_tile("A"), make_tile("B"), make_tile("C")],
            properties: vec![],
            graph: BoardGraph::default(), // empty edges → linear fallback
        };
        // Linear: A -> B -> C -> A (wrap around)
        assert_eq!(board.next_tile_id("A"), Some("B".to_string()));
        assert_eq!(board.next_tile_id("B"), Some("C".to_string()));
        assert_eq!(board.next_tile_id("C"), Some("A".to_string()));
    }

    #[test]
    fn test_next_tile_id_graph_priority() {
        let board = Board {
            tiles: vec![make_tile("A"), make_tile("B"), make_tile("C")],
            properties: vec![],
            graph: BoardGraph {
                edges: vec![BoardEdge {
                    from: "A".to_string(),
                    to: "C".to_string(),
                    label: None,
                }],
                teleporters: vec![],
            },
        };
        // Graph takes priority: A -> C (not A -> B)
        assert_eq!(board.next_tile_id("A"), Some("C".to_string()));
        // No graph edge from C → falls through but edges is non-empty,
        // so graph_next_tile_id returns None and next_tile_id returns None too.
        assert_eq!(board.next_tile_id("C"), None);
    }
}
