import 'dart:math' as math;

import 'package:flutter/material.dart';

// ============================================================================
// View models
// ============================================================================

/// A single tile on the board (serialised from the content pack).
class BoardTileViewModel {
  final String id;
  final String name;
  final String kind;

  const BoardTileViewModel({
    required this.id,
    required this.name,
    required this.kind,
  });

  factory BoardTileViewModel.fromJson(Map<String, dynamic> json) {
    return BoardTileViewModel(
      id: json['id'] as String,
      name: json['name'] as String,
      kind: json['kind'] as String,
    );
  }

  /// Return a colour associated with the tile kind for visual distinction.
  Color get color {
    switch (kind) {
      case 'Start':
        return Colors.green;
      case 'OrdinaryProperty':
        return Colors.blue;
      case 'SpecialProperty':
        return Colors.purple;
      case 'ExtensionProperty':
        return Colors.teal;
      case 'Chance':
        return Colors.orange;
      case 'CardShop':
        return Colors.amber;
      case 'Lottery':
        return Colors.red;
      case 'Bank':
        return Colors.brown;
      case 'Jail':
        return Colors.grey;
      case 'Hospital':
        return Colors.pink;
      default:
        return Colors.grey.shade300;
    }
  }
}

/// Lightweight player token displayed on the board.
class PlayerTokenViewModel {
  final String id;
  final String name;
  final String tileId;
  final Color color;
  final int cash;

  const PlayerTokenViewModel({
    required this.id,
    required this.name,
    required this.tileId,
    required this.color,
    required this.cash,
  });
}

/// Full board state for the renderer.
class BoardViewModel {
  final String mapName;
  final List<BoardTileViewModel> tiles;
  final List<PlayerTokenViewModel> players;
  final int activePlayerIndex;
  /// Maps tile_id → player_id for properties that have been bought.
  final Map<String, String> propertyOwners;

  /// Explicit perimeter grid positions `(row, col)` for each tile index,
  /// in path order (clockwise).  When set, the renderer uses these instead
  /// of computing positions from the rectangular formula.
  ///
  /// `null` (default) → fall back to the standard rectangular layout.
  final List<(int, int)>? perimeterPositions;

  const BoardViewModel({
    required this.mapName,
    required this.tiles,
    this.players = const [],
    this.activePlayerIndex = 0,
    this.propertyOwners = const {},
    this.perimeterPositions,
  });
}

// ============================================================================
// BoardWidget – renders the classic square Monopoly board using Flutter widgets
// ============================================================================

class BoardWidget extends StatelessWidget {
  final BoardViewModel viewModel;

  const BoardWidget({
    super.key,
    required this.viewModel,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boardSize =
            constraints.maxWidth < constraints.maxHeight
                ? constraints.maxWidth
                : constraints.maxHeight;
        return SizedBox(
          width: boardSize,
          height: boardSize,
          child: _buildBoard(boardSize),
        );
      },
    );
  }

  /// Map tile_id → owner player color for property ownership display.
  Map<String, Color> get _ownerColors {
    final result = <String, Color>{};
    final ownerColors = [
      const Color(0xFFD32F2F), // red – Player 1
      const Color(0xFF1976D2), // blue – Player 2
      const Color(0xFF388E3C), // green – Player 3
      const Color(0xFFFBC02D), // yellow – Player 4
      const Color(0xFF8E24AA), // purple – Player 5
      const Color(0xFFFF6F00), // orange – Player 6
    ];
    for (final entry in viewModel.propertyOwners.entries) {
      final playerIdx = int.tryParse(
          entry.value.replaceAll('player_', '')) ?? 0;
      result[entry.key] = ownerColors[playerIdx % ownerColors.length];
    }
    return result;
  }

  Widget _buildBoard(double boardSize) {
    final tiles = viewModel.tiles;
    final numTiles = tiles.length;
    if (numTiles < 4) {
      return const Center(child: Text('Not enough tiles'));
    }

    // 4 corners + edge tiles distributed along 4 sides
    final tilesPerSide = (numTiles - 4) ~/ 4;
    final cornerSize = boardSize * 0.18;
    final edgeLength = boardSize - cornerSize * 2;
    final tileSize = tilesPerSide > 0 ? edgeLength / tilesPerSide : cornerSize;

    // Build the tile grid: we create a table-like layout
    // side 0 = bottom (left to right), side 1 = right (bottom to top),
    // side 2 = top (right to left), side 3 = left (top to bottom)
    //
    // Grid positions:
    //   Row 0:     TL corner | top edge (RTL) | TR corner
    //   Row 1..N:  left tile |   center area  | right tile
    //   Row N+1:   BL corner | bottom edge(LTR)| BR corner

    final gridSize = tilesPerSide + 2; // tiles per row/col including corners
    final cellSize = boardSize / gridSize;

    // Map tile index -> grid (row, col)
    //
    // The board perimeter has 4*(gridSize-1) cells.  We allocate:
    //   bottom: gridSize cols (includes both BL & BR corners)
    //   right:  gridSize-1 rows (excludes BR corner already placed)
    //   top:    gridSize-1 cols (excludes TR corner already placed)
    //   left:   gridSize-2 rows (excludes TL & BL corners already placed)
    final positions = <int, int>{}; // tileIdx -> gridIndex (row * gridSize + col)
    int tileIdx = 0;

    // Bottom row (side 0): row = gridSize-1, col = 0..gridSize-1
    for (var i = 0; i < gridSize; i++) {
      positions[tileIdx] = (gridSize - 1) * gridSize + i;
      tileIdx++;
    }

    // Right column (side 1): col = gridSize-1, row = gridSize-2 down to 0
    for (var i = 0; i < gridSize - 1; i++) {
      positions[tileIdx] = (gridSize - 2 - i) * gridSize + (gridSize - 1);
      tileIdx++;
    }

    // Top row (side 2): row = 0, col = gridSize-2 down to 0
    for (var i = 0; i < gridSize - 1; i++) {
      positions[tileIdx] = 0 * gridSize + (gridSize - 2 - i);
      tileIdx++;
    }

    // Left column (side 3): col = 0, row = 1 up to gridSize-2
    for (var i = 0; i < gridSize - 2; i++) {
      positions[tileIdx] = (1 + i) * gridSize + 0;
      tileIdx++;
    }

    // Pre-compute which players are on each tile
    final playersOnTile = <int, List<PlayerTokenViewModel>>{};
    for (final player in viewModel.players) {
      final tileIdx = tiles.indexWhere((t) => t.id == player.tileId);
      if (tileIdx >= 0) {
        playersOnTile.putIfAbsent(tileIdx, () => []);
        playersOnTile[tileIdx]!.add(player);
      }
    }

    // Build grid cells
    final cells = <Widget>[];
    for (var r = 0; r < gridSize; r++) {
      for (var c = 0; c < gridSize; c++) {
        final gridIndex = r * gridSize + c;
        final tileIndex = positions.entries
            .where((e) => e.value == gridIndex)
            .map((e) => e.key)
            .toList();

        if (tileIndex.isEmpty) {
          // Center area — only the actual center cell shows the map name
          final isCenter = r == gridSize ~/ 2 && c == gridSize ~/ 2;
          cells.add(_buildCenterCell(boardSize, isCenter));
        } else {
          final ti = tileIndex.first;
          if (ti < tiles.length) {
            final ownerColor = _ownerColors[tiles[ti].id];
            cells.add(_buildTileCell(
              tiles[ti],
              cellSize,
              r, c, gridSize,
              players: playersOnTile[ti] ?? [],
              ownerColor: ownerColor,
            ));
          } else {
            cells.add(const SizedBox());
          }
        }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5E9),
        border: Border.all(color: const Color(0xFF2E7D32), width: 3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: List.generate(gridSize, (r) {
          return Expanded(
            child: Row(
              children: List.generate(gridSize, (c) {
                return Expanded(
                  child: cells[r * gridSize + c],
                );
              }),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildTileCell(
    BoardTileViewModel tile,
    double cellSize,
    int row, int col, int gridSize, {
    List<PlayerTokenViewModel> players = const [],
    Color? ownerColor,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: tile.color.withOpacity(0.3),
        border: Border.all(color: Colors.black26, width: 0.5),
      ),
      child: Stack(
        children: [
          // Tile content
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Property color strip at top (for all ownable property tiles).
              // When owned, the top strip shows the owner's colour so both
              // coloured bars always match – avoiding ambiguity when a tile's
              // kind colour happens to overlap with a player's colour.
              if (tile.kind == 'OrdinaryProperty' ||
                  tile.kind == 'SpecialProperty' ||
                  tile.kind == 'ExtensionProperty')
                Container(
                  height: 3,
                  color: ownerColor ?? tile.color,
                  margin: const EdgeInsets.only(bottom: 1),
                ),
              // Tile name with ownership icon
              Expanded(
                child: Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Ownership icon: a small house icon shown only when
                      // the property is owned.  This provides a colour-
                      // independent visual indicator so ownership is always
                      // clear even when the tile kind colour matches the
                      // player's colour.
                      if (ownerColor != null &&
                          (tile.kind == 'OrdinaryProperty' ||
                           tile.kind == 'SpecialProperty' ||
                           tile.kind == 'ExtensionProperty'))
                        Padding(
                          padding: const EdgeInsets.only(right: 2),
                          child: Icon(
                            Icons.home,
                            size: cellSize * 0.14,
                            color: ownerColor,
                          ),
                        ),
                      Flexible(
                        child: Text(
                          _displayName(tile),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: cellSize * 0.12,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Ownership indicator bar at bottom of tile content.
              if (ownerColor != null &&
                  (tile.kind == 'OrdinaryProperty' ||
                   tile.kind == 'SpecialProperty' ||
                   tile.kind == 'ExtensionProperty'))
                Container(
                  height: 4,
                  color: ownerColor,
                  margin: const EdgeInsets.only(top: 1),
                ),
            ],
          ),
          // Player tokens at bottom of tile
          if (players.isNotEmpty)
            Positioned(
              bottom: 1,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: players.map((p) {
                  return Container(
                    width: cellSize * 0.4,
                    height: cellSize * 0.4,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: p.color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Center(
                      child: Text(
                        p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: cellSize * 0.2,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCenterCell(double boardSize, bool isCenter) {
    return Container(
      color: Colors.white.withOpacity(0.5),
      child: isCenter
          ? Center(
              child: Text(
                viewModel.mapName.isNotEmpty ? viewModel.mapName : 'saMonopoly',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: boardSize * 0.035,
                  fontWeight: FontWeight.bold,
                  color: Colors.black38,
                ),
              ),
            )
          : null,
    );
  }

  String _displayName(BoardTileViewModel tile) {
    final name = tile.name;
    // Strip localization key prefix if present
    if (name.startsWith('tile.')) {
      return name.substring(5);
    }
    if (name.startsWith('prop.')) {
      return name.substring(5);
    }
    return name;
  }
}
