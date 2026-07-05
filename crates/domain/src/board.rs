use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::property::Property;
use crate::tile::Tile;
use crate::types::{Money, TileId};

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
    /// When `true`, the engine will automatically compute `linked_targets`
    /// for properties on the same board edge, based on grouping rules:
    ///   - max 5 properties per group
    ///   - groups must be contiguous (no non-property tiles between members)
    ///   - single-tile gaps allowed only when each side has >= 3 properties
    /// Properties that already have manual `linked_targets` are skipped.
    #[serde(default)]
    pub auto_link_rent: bool,
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

    // ── Auto-link Rent ────────────────────────────────────────────────────

    /// Automatically compute `linked_targets` for all properties based on
    /// board topology and the grouping rules.
    ///
    /// **Rules** (when `self.auto_link_rent` is `true`):
    /// 1. Groups only form within the same board "edge" (same side).
    /// 2. Group members must be contiguous — no non-property tiles between them.
    /// 3. Maximum 5 properties per group.
    /// 4. **Exception**: a single non-property gap is allowed if the combined
    ///    group would have >= 3 properties (e.g. P-S-P-S-P → 3 properties linked).
    ///
    /// Properties that already have non-empty `linked_targets` (manual bindings)
    /// are skipped.  Call this once after loading a map, before game start.
    /// Automatically compute `linked_targets` for all properties based on
    /// board topology and the grouping rules.
    ///
    /// **Rules** (when `self.auto_link_rent` is `true`):
    /// 1. Groups only form within the same board "edge" (same side).
    /// 2. Group members must be contiguous — no non-property tiles between them.
    /// 3. Maximum 5 properties per group.
    /// 4. **Exception**: a single non-property gap is allowed if the combined
    ///    group would have >= 3 properties (e.g. P-S-P-S-P → 3 properties linked).
    ///
    /// Properties that already have non-empty `linked_targets` (manual bindings)
    /// are skipped.  Call this once after loading a map, before game start.
    pub fn compute_auto_links(&mut self) {
        if !self.auto_link_rent {
            return;
        }

        let n = self.tiles.len();
        if n < 4 {
            return;
        }

        // Collect tile IDs with manual bindings (owned strings to avoid borrow issues)
        let manual: HashSet<String> = self
            .properties
            .iter()
            .filter(|p| !p.linked_targets.is_empty())
            .map(|p| p.tile_id.clone())
            .collect();

        let is_prop: HashSet<String> = self
            .properties
            .iter()
            .map(|p| p.tile_id.clone())
            .collect();

        // Build the traversal path (tile IDs in order, owned strings).
        let path: Vec<String> = self.build_path();

        // Split path into edges (direction segments) and process each independently.
        // Rule 1: group rent only happens within the same board edge.
        let edges: Vec<Vec<usize>> = if self.graph.edges.is_empty() {
            Self::linear_edges(n)
        } else {
            self.graph_edges()
        };

        for edge_indices in &edges {
            let edge_path: Vec<String> = edge_indices
                .iter()
                .filter_map(|&idx| path.get(idx))
                .cloned()
                .collect();
            if !edge_path.is_empty() {
                Self::apply_grouping(&edge_path, &is_prop, &manual, &mut self.properties);
            }
        }
    }

    /// Split the linear tile sequence into 4 rectangular sides.
    ///
    /// Only valid when `n` matches the rectangular formula `4(g-1)`.
    /// For non‑rectangular layouts the whole path is returned as one edge.
    fn linear_edges(n: usize) -> Vec<Vec<usize>> {
        if n < 4 {
            return vec![(0..n).collect()];
        }
        // Check if n fits the rectangular formula: n == 4(g-1) for integer g
        if (n + 4) % 4 != 0 {
            return vec![(0..n).collect()];
        }
        let g = (n + 4) / 4; // grid size
        // Verify g >= 2 (minimum for a rectangle)
        if g < 2 {
            return vec![(0..n).collect()];
        }
        vec![
            (0..g).collect(),                         // bottom: g tiles
            (g..(2 * g - 1)).collect(),                // right:  g-1 tiles
            ((2 * g - 2)..(3 * g - 3)).collect(),      // top:    g-1 tiles
            ((3 * g - 3)..(4 * g - 5)).collect(),      // left:   g-2 tiles
        ]
    }

    /// Walk the graph to find edge segments (paths between degree-≠2 nodes).
    fn graph_edges(&self) -> Vec<Vec<usize>> {
        if self.tiles.is_empty() { return vec![]; }
        let tile_idx: std::collections::HashMap<&str, usize> = self
            .tiles.iter().enumerate().map(|(i, t)| (t.id.as_str(), i)).collect();
        let mut path: Vec<usize> = Vec::new();
        let mut visited: std::collections::HashSet<String> = std::collections::HashSet::new();
        if let Some(first) = self.tiles.first() {
            let mut current = first.id.clone();
            loop {
                if !visited.insert(current.clone()) { break; }
                if let Some(&idx) = tile_idx.get(current.as_str()) { path.push(idx); }
                match self.next_tile_id(&current) {
                    Some(next) => current = next,
                    None => break,
                }
            }
        }
        // Build undirected adjacency for degree detection
        let mut adj: std::collections::HashMap<&str, Vec<&str>> = std::collections::HashMap::new();
        for edge in &self.graph.edges {
            adj.entry(edge.from.as_str()).or_default().push(&edge.to);
            adj.entry(edge.to.as_str()).or_default().push(&edge.from);
        }
        let mut edges: Vec<Vec<usize>> = Vec::new();
        let mut current: Vec<usize> = Vec::new();
        for &idx in &path {
            let tid = &self.tiles[idx].id;
            let deg = adj.get(tid.as_str()).map_or(0, |v| v.len());
            current.push(idx);
            if deg != 2 {
                edges.push(std::mem::take(&mut current));
            }
        }
        if !current.is_empty() { edges.push(current); }
        edges
    }

    /// Walk the board graph (or linear fallback) to produce the tile-ID path.
    fn build_path(&self) -> Vec<String> {
        let mut path: Vec<String> = Vec::new();
        let mut visited: HashSet<String> = HashSet::new();
        if let Some(first) = self.tiles.first() {
            let mut current: String = first.id.clone();
            loop {
                if !visited.insert(current.clone()) {
                    break;
                }
                path.push(current.clone());
                match self.next_tile_id(&current) {
                    Some(next) => current = next,
                    None => break,
                }
            }
        }
        path
    }

    /// Apply grouping rules to a slice of tile IDs that form a path segment.
    fn apply_grouping(
        tile_ids: &[String],
        is_prop: &HashSet<String>,
        manual: &HashSet<String>,
        properties: &mut [Property],
    ) {
        // ── 1. Walk and find contiguous property runs ────────────────
        let mut runs: Vec<Vec<String>> = Vec::new();
        let mut i = 0usize;
        while i < tile_ids.len() {
            if !is_prop.contains(&tile_ids[i]) || manual.contains(&tile_ids[i]) {
                i += 1;
                continue;
            }
            let mut run = vec![tile_ids[i].clone()];
            i += 1;
            while i < tile_ids.len()
                && is_prop.contains(&tile_ids[i])
                && !manual.contains(&tile_ids[i])
            {
                run.push(tile_ids[i].clone());
                i += 1;
            }
            if !run.is_empty() {
                runs.push(run);
            }
        }

        if runs.is_empty() {
            return;
        }

        // ── 2. Merge runs connected by single-tile gaps ────────────
        let mut merged: Vec<Vec<String>> = Vec::new();
        let mut ri = 0usize;
        while ri < runs.len() {
            let mut cluster: Vec<String> = runs[ri].clone();
            ri += 1;

            // Collect consecutive runs connected by gap=1
            let mut contiguous: Vec<Vec<String>> = vec![cluster.clone()];
            while ri < runs.len() {
                let prev_tid = &contiguous.last().unwrap().last().unwrap().clone();
                let gap = Self::count_gap(tile_ids, prev_tid, &runs[ri][0]);
                if gap == 1 {
                    contiguous.push(runs[ri].clone());
                    ri += 1;
                } else {
                    break;
                }
            }

            if contiguous.len() > 1 {
                let total: usize = contiguous.iter().map(|r| r.len()).sum();
                if total >= 3 {
                    // Merge all into one group
                    cluster.clear();
                    for r in &contiguous {
                        cluster.extend(r.clone());
                    }
                    merged.push(cluster);
                } else {
                    // Keep each run separate
                    for r in contiguous {
                        merged.push(r);
                    }
                }
            } else {
                merged.push(cluster);
            }
        }

        // ── 3. Enforce max 5 per group & set linked_targets ──────
        for group in &merged {
            let max = if group.len() > 5 { 5 } else { group.len() };
            if max < 2 {
                continue;
            }
            for i in 0..max {
                let tid = &group[i];
                let targets: Vec<String> = (0..max)
                    .filter(|&j| j != i)
                    .map(|j| group[j].clone())
                    .collect();
                if let Some(prop) = properties.iter_mut().find(|p| p.tile_id == *tid) {
                    prop.linked_targets = targets;
                }
            }
        }
    }

    /// Count the number of non-property tiles between two tile IDs in the path.
    fn count_gap(tile_ids: &[String], from: &str, to: &str) -> usize {
        let mut counting = false;
        let mut count = 0usize;
        for tid in tile_ids {
            if tid == from {
                counting = true;
                continue;
            }
            if tid == to {
                return count;
            }
            if counting {
                count += 1;
            }
        }
        count
    }

    // ── Group (Union-Find) Rent Logic ─────────────────────────────────────

    /// Build a union-find map from `linked_targets` on all properties.
    /// Returns a map: tile_id → root_tile_id (group representative).
    fn build_union_find(&self) -> HashMap<TileId, TileId> {
        let mut parent: HashMap<TileId, TileId> = HashMap::new();

        // Each property is its own parent initially
        for prop in &self.properties {
            parent.entry(prop.tile_id.clone()).or_insert_with(|| prop.tile_id.clone());
        }

        // Union: for each linked_target, union the two tile IDs
        for prop in &self.properties {
            for target in &prop.linked_targets {
                Self::union(&mut parent, &prop.tile_id, target);
            }
        }

        // Path compression
        for key in parent.keys().cloned().collect::<Vec<_>>() {
            Self::find(&mut parent, &key);
        }

        parent
    }

    fn find(parent: &mut HashMap<TileId, TileId>, x: &TileId) -> TileId {
        let p = parent.get(x).cloned().unwrap_or_else(|| x.clone());
        if p != *x {
            let root = Self::find(parent, &p);
            parent.insert(x.clone(), root.clone());
            root
        } else {
            x.clone()
        }
    }

    fn union(parent: &mut HashMap<TileId, TileId>, a: &TileId, b: &TileId) {
        let ra = Self::find(parent, a);
        let rb = Self::find(parent, b);
        if ra != rb {
            parent.insert(ra, rb.clone());
        }
    }

    /// If group rent is enabled and all properties in the same linked group
    /// as `tile_id` are owned by the same player, return the sum of all
    /// group members' current rent.  Otherwise return `None`.
    pub fn group_rent(&self, tile_id: &str) -> Option<Money> {
        // Find the property for this tile
        let prop = self.property(tile_id)?;
        if prop.linked_targets.is_empty() {
            return None; // no group defined
        }

        // Build union-find and find the group root
        let mut uf = self.build_union_find();
        let tid = tile_id.to_string();
        let root = Self::find(&mut uf, &tid);

        // Collect all members of this group
        let members: Vec<TileId> = uf
            .iter()
            .filter(|(_, r)| **r == root)
            .map(|(k, _)| k.clone())
            .collect();

        if members.is_empty() {
            return None;
        }

        // Check that all members have the same owner
        let first_owner: Option<String> = self
            .property(&members[0])
            .and_then(|p| p.owner.clone());

        let owner = match first_owner {
            Some(ref o) => o.clone(),
            None => return None,
        };

        // If any member is unowned or has a different owner, no group rent
        for member_id in &members {
            match self.property(member_id) {
                Some(p) if p.owner.as_deref() == Some(&owner) => {}
                _ => return None,
            }
        }

        // All owned by same player → sum all members' current rent
        let total: Money = members
            .iter()
            .filter_map(|mid| self.property(mid))
            .map(|p| p.current_rent())
            .sum();

        if total > 0 { Some(total) } else { None }
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
            linked_targets: vec![],
        }
    }

    fn make_board(
        tiles: Vec<Tile>,
        properties: Vec<Property>,
        graph: BoardGraph,
        auto_link: bool,
    ) -> Board {
        Board {
            tiles,
            properties,
            graph,
            auto_link_rent: auto_link,
        }
    }

    #[test]
    fn test_tile_index() {
        let board = make_board(
            vec![make_tile("A"), make_tile("B"), make_tile("C")],
            vec![],
            BoardGraph::default(),
            false,
        );
        assert_eq!(board.tile_index("A"), Some(0));
        assert_eq!(board.tile_index("B"), Some(1));
        assert_eq!(board.tile_index("C"), Some(2));
        assert_eq!(board.tile_index("D"), None);
    }

    #[test]
    fn test_tile_lookup() {
        let board = make_board(
            vec![make_tile("GO"), make_tile("Mediterranean")],
            vec![],
            BoardGraph::default(),
            false,
        );
        assert!(board.tile("GO").is_some());
        assert_eq!(board.tile("GO").unwrap().id, "GO");
        assert!(board.tile("NonExistent").is_none());
    }

    #[test]
    fn test_property_lookup() {
        let mut board = make_board(
            vec![make_tile("GO"), make_tile("P1")],
            vec![make_property("P1", 200)],
            BoardGraph::default(),
            false,
        );

        let prop = board.property("P1");
        assert!(prop.is_some());
        assert_eq!(prop.unwrap().base_price, 200);
        assert!(board.property("GO").is_none());

        let mut_prop = board.property_mut("P1");
        assert!(mut_prop.is_some());
        mut_prop.unwrap().base_price = 300;
        assert_eq!(board.property("P1").unwrap().base_price, 300);
    }

    #[test]
    fn test_graph_next_tile() {
        let board = make_board(
            vec![make_tile("A"), make_tile("B"), make_tile("C")],
            vec![],
            BoardGraph {
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
            false,
        );
        assert_eq!(board.graph_next_tile_id("A"), Some("C".to_string()));
        assert_eq!(board.graph_next_tile_id("C"), Some("B".to_string()));
        assert_eq!(board.graph_next_tile_id("B"), None);
    }

    #[test]
    fn test_next_tile_id_linear_fallback() {
        let board = make_board(
            vec![make_tile("A"), make_tile("B"), make_tile("C")],
            vec![],
            BoardGraph::default(),
            false,
        );
        assert_eq!(board.next_tile_id("A"), Some("B".to_string()));
        assert_eq!(board.next_tile_id("B"), Some("C".to_string()));
        assert_eq!(board.next_tile_id("C"), Some("A".to_string()));
    }

    #[test]
    fn test_next_tile_id_graph_priority() {
        let board = make_board(
            vec![make_tile("A"), make_tile("B"), make_tile("C")],
            vec![],
            BoardGraph {
                edges: vec![BoardEdge {
                    from: "A".to_string(),
                    to: "C".to_string(),
                    label: None,
                }],
                teleporters: vec![],
            },
            false,
        );
        assert_eq!(board.next_tile_id("A"), Some("C".to_string()));
        assert_eq!(board.next_tile_id("C"), None);
    }

    // ── Auto-link tests ─────────────────────────────────────────────────

    fn make_ordinary_tile(id: &str) -> Tile {
        Tile {
            id: id.to_string(),
            name_key: format!("tile.{}", id),
            kind: TileKind::OrdinaryProperty,
            linked_property_kind: Some(crate::property::PropertyKind::Ordinary),
        }
    }

    fn make_chance_tile(id: &str) -> Tile {
        Tile {
            id: id.to_string(),
            name_key: format!("tile.{}", id),
            kind: TileKind::Chance,
            linked_property_kind: None,
        }
    }

    #[test]
    fn test_auto_link_disabled_does_nothing() {
        let mut board = make_board(
            vec![make_ordinary_tile("P1"), make_ordinary_tile("P2")],
            vec![make_property("P1", 100), make_property("P2", 100)],
            BoardGraph::default(),
            false, // auto_link_rent = false
        );
        board.compute_auto_links();
        assert!(board.property("P1").unwrap().linked_targets.is_empty());
        assert!(board.property("P2").unwrap().linked_targets.is_empty());
    }

    #[test]
    fn test_auto_link_contiguous_run() {
        // 3 contiguous properties on an edge → should be linked
        let tiles = vec![
            make_tile("S"),       // start (corner)
            make_ordinary_tile("P1"),
            make_ordinary_tile("P2"),
            make_ordinary_tile("P3"),
            make_tile("C"),       // corner
        ];
        let props = vec![
            make_property("P1", 100),
            make_property("P2", 100),
            make_property("P3", 100),
        ];
        let mut board = make_board(tiles, props, BoardGraph::default(), true);
        board.compute_auto_links();

        let p1 = board.property("P1").unwrap();
        let p2 = board.property("P2").unwrap();
        let p3 = board.property("P3").unwrap();

        assert!(!p1.linked_targets.is_empty());
        assert_eq!(p1.linked_targets.len(), 2); // linked to P2 and P3
        assert!(p1.linked_targets.contains(&"P2".to_string()));
        assert!(p1.linked_targets.contains(&"P3".to_string()));

        assert!(!p2.linked_targets.is_empty());
        assert_eq!(p2.linked_targets.len(), 2); // linked to P1 and P3

        assert!(!p3.linked_targets.is_empty());
        assert_eq!(p3.linked_targets.len(), 2); // linked to P1 and P2
    }

    #[test]
    fn test_auto_link_max_5() {
        // 7 contiguous properties → should only link max 5
        let mut tiles = vec![make_tile("S")];
        let mut props = vec![];
        for i in 1..=7 {
            tiles.push(make_ordinary_tile(&format!("P{i}")));
            props.push(make_property(&format!("P{i}"), 100));
        }
        tiles.push(make_tile("C"));
        let mut board = make_board(tiles, props, BoardGraph::default(), true);
        board.compute_auto_links();

        let p1 = board.property("P1").unwrap();
        assert_eq!(p1.linked_targets.len(), 4); // P2, P3, P4, P5 only (max 5)
        assert!(!p1.linked_targets.contains(&"P6".to_string()));
        assert!(!p1.linked_targets.contains(&"P7".to_string()));
    }

    #[test]
    fn test_auto_link_single_gap_exception() {
        // P1 - S - P2 - S - P3  (gap=1 each, total 3 properties → merged)
        let tiles = vec![
            make_tile("S"),
            make_ordinary_tile("P1"),
            make_chance_tile("G1"),
            make_ordinary_tile("P2"),
            make_chance_tile("G2"),
            make_ordinary_tile("P3"),
            make_tile("C"),
        ];
        let props = vec![
            make_property("P1", 100),
            make_property("P2", 100),
            make_property("P3", 100),
        ];
        let mut board = make_board(tiles, props, BoardGraph::default(), true);
        board.compute_auto_links();

        let p1 = board.property("P1").unwrap();
        assert_eq!(p1.linked_targets.len(), 2); // linked to P2 and P3

        let p2 = board.property("P2").unwrap();
        assert_eq!(p2.linked_targets.len(), 2);

        let p3 = board.property("P3").unwrap();
        assert_eq!(p3.linked_targets.len(), 2);
    }

    #[test]
    fn test_auto_link_single_gap_too_few() {
        // P1 - S - P2  (gap=1, but only 2 properties → no merge)
        let tiles = vec![
            make_tile("S"),
            make_ordinary_tile("P1"),
            make_chance_tile("G1"),
            make_ordinary_tile("P2"),
            make_tile("C"),
        ];
        let props = vec![
            make_property("P1", 100),
            make_property("P2", 100),
        ];
        let mut board = make_board(tiles, props, BoardGraph::default(), true);
        board.compute_auto_links();

        let p1 = board.property("P1").unwrap();
        // P1 only has P2 as potential, but P2 only has P1, total=2 < 3
        // So they should NOT be merged across the gap
        assert!(p1.linked_targets.is_empty() || p1.linked_targets.len() == 1);

        // Actually, since gap=1 but combined is only 2 (< 3), they stay separate,
        // and each run has only 1 property (< 2), so no links at all
        assert!(p1.linked_targets.is_empty());
    }

    #[test]
    fn test_auto_link_double_gap_no_merge() {
        // P1 - S - S - P2  (gap=2, should NOT merge even if combined >= 3)
        let tiles = vec![
            make_tile("S"),
            make_ordinary_tile("P1"),
            make_chance_tile("G1"),
            make_chance_tile("G2"),
            make_ordinary_tile("P2"),
            make_tile("C"),
        ];
        let props = vec![
            make_property("P1", 100),
            make_property("P2", 100),
        ];
        let mut board = make_board(tiles, props, BoardGraph::default(), true);
        board.compute_auto_links();

        let p1 = board.property("P1").unwrap();
        assert!(p1.linked_targets.is_empty());
    }

    #[test]
    fn test_auto_link_manual_skip() {
        // P1 has manual linked_targets, should be skipped by auto-link
        let mut p1 = make_property("P1", 100);
        p1.linked_targets = vec!["P3".to_string()]; // manual
        let p2 = make_property("P2", 100);
        let p3 = make_property("P3", 100);

        let tiles = vec![
            make_tile("S"),
            make_ordinary_tile("P1"),
            make_ordinary_tile("P2"),
            make_ordinary_tile("P3"),
            make_tile("C"),
        ];
        let mut board = make_board(tiles, vec![p1, p2, p3], BoardGraph::default(), true);
        board.compute_auto_links();

        // P1 retains its manual binding
        assert_eq!(board.property("P1").unwrap().linked_targets, vec!["P3".to_string()]);

        // P2 and P3 were auto-linked to each other (P1 skipped)
        let p2_links = &board.property("P2").unwrap().linked_targets;
        let p3_links = &board.property("P3").unwrap().linked_targets;
        // P2 and P3 should be linked to each other (but NOT to P1)
        assert!(!p2_links.is_empty());
        assert!(p2_links.contains(&"P3".to_string()));
        assert!(!p2_links.contains(&"P1".to_string()));
        assert!(!p3_links.is_empty());
        assert!(p3_links.contains(&"P2".to_string()));
        assert!(!p3_links.contains(&"P1".to_string()));
    }
}
