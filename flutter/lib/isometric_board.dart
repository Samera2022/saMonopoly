import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'board_view.dart';

// ============================================================================
// Isometric Camera Controller
// ============================================================================

class IsometricCamera {
  double offsetX = 0.0;
  double offsetY = 0.0;
  double zoom = 1.0;

  void pan(double dx, double dy) {
    offsetX += dx;
    offsetY += dy;
  }

  void zoomBy(double factor, Offset focalPoint) {
    final newZoom = (zoom * factor).clamp(0.3, 4.0);
    if (newZoom == zoom) return;
    // Zoom toward the focal point
    offsetX = focalPoint.dx - (focalPoint.dx - offsetX) * (newZoom / zoom);
    offsetY = focalPoint.dy - (focalPoint.dy - offsetY) * (newZoom / zoom);
    zoom = newZoom;
  }
}

// ============================================================================
// Isometric transformation helpers
// ============================================================================

/// Convert a grid (row, col) position to isometric screen coordinates.
Offset gridToIso(int row, int col, double tileW, double tileH) {
  final isoX = (col - row) * tileW / 2;
  final isoY = (col + row) * tileH / 4;
  return Offset(isoX, isoY);
}

/// Isometric diamond bounding rect for the entire grid.
Rect isoBoardBounds(int gridSize, double tileW, double tileH) {
  // Min/max iso coordinates across all grid cells
  double minX = double.infinity, maxX = double.negativeInfinity;
  double minY = double.infinity, maxY = double.negativeInfinity;
  for (var r = 0; r < gridSize; r++) {
    for (var c = 0; c < gridSize; c++) {
      final p = gridToIso(r, c, tileW, tileH);
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
  }
  // Add tile extents
  return Rect.fromLTWH(
    minX - tileW / 2,
    minY - tileH / 2,
    maxX - minX + tileW,
    maxY - minY + tileH,
  );
}

// ============================================================================
// Isometric Board Painter (CustomPainter)
// ============================================================================

class IsometricBoardPainter extends CustomPainter {
  final BoardViewModel viewModel;
  final IsometricCamera camera;
  final int gridSize;
  final double tileWidth;
  final double tileHeight;
  final Map<String, Color> ownerColors;

  IsometricBoardPainter({
    required this.viewModel,
    required this.camera,
    required this.gridSize,
    required this.tileWidth,
    required this.tileHeight,
    required this.ownerColors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    // Apply camera transform
    canvas.translate(
      size.width / 2 - camera.offsetX,
      size.height / 2 - camera.offsetY,
    );
    canvas.scale(camera.zoom);

    final tiles = viewModel.tiles;
    if (tiles.isEmpty) {
      canvas.restore();
      return;
    }

    // Compute tile-to-grid position mapping (same logic as before)
    final tilesPerSide = (tiles.length - 4) ~/ 4;
    final positions = <int, int>{}; // tileIdx → gridIndex (r,gSize,c)
    int tileIdx = 0;
    for (var i = 0; i <= tilesPerSide; i++) {
      positions[tileIdx] = (gridSize - 1) * gridSize + i;
      tileIdx++;
    }
    for (var i = 0; i < tilesPerSide; i++) {
      positions[tileIdx] = (gridSize - 2 - i) * gridSize + (gridSize - 1);
      tileIdx++;
    }
    for (var i = 0; i <= tilesPerSide; i++) {
      positions[tileIdx] = 0 * gridSize + (gridSize - 1 - i);
      tileIdx++;
    }
    for (var i = 0; i < tilesPerSide; i++) {
      positions[tileIdx] = (1 + i) * gridSize + 0;
      tileIdx++;
    }

    // Pre-compute players on each tile
    final playersOnTile = <int, List<PlayerTokenViewModel>>{};
    for (final player in viewModel.players) {
      final ti = tiles.indexWhere((t) => t.id == player.tileId);
      if (ti >= 0) {
        playersOnTile.putIfAbsent(ti, () => []);
        playersOnTile[ti]!.add(player);
      }
    }

    // Draw tiles from back to front (painter's algorithm: sort by isoY)
    final tileIndices = List.generate(tiles.length, (i) => i);
    tileIndices.sort((a, b) {
      final posA = positions[a] ?? 0;
      final posB = positions[b] ?? 0;
      final rowA = posA ~/ gridSize;
      final colA = posA % gridSize;
      final rowB = posB ~/ gridSize;
      final colB = posB % gridSize;
      // Sort by isoY ascending (paint further tiles first)
      return (rowA + colA).compareTo(rowB + colB);
    });

    for (final ti in tileIndices) {
      if (ti >= tiles.length) continue;
      final pos = positions[ti];
      if (pos == null) continue;
      final row = pos ~/ gridSize;
      final col = pos % gridSize;
      final tile = tiles[ti];
      final players = playersOnTile[ti] ?? [];
      final ownerColor = ownerColors[tile.id];

      final center = gridToIso(row, col, tileWidth, tileHeight);
      _drawTile(canvas, tile, center, ownerColor);
      _drawPlayers(canvas, players, center);
    }

    // Draw tile texts on top (front-most)
    for (final ti in tileIndices) {
      if (ti >= tiles.length) continue;
      final pos = positions[ti];
      if (pos == null) continue;
      final row = pos ~/ gridSize;
      final col = pos % gridSize;
      final tile = tiles[ti];
      final center = gridToIso(row, col, tileWidth, tileHeight);
      _drawTileName(canvas, tile, center);
    }

    canvas.restore();
  }

  void _drawTile(Canvas canvas, BoardTileViewModel tile, Offset center, Color? ownerColor) {
    final hw = tileWidth / 2;
    final hh = tileHeight / 2;

    // Isometric tile rhombus: diamond shape with the 4 corners
    final path = Path()
      ..moveTo(center.dx, center.dy - hh)           // top
      ..lineTo(center.dx + hw, center.dy - hh / 2) // right (shifted for depth)
      ..lineTo(center.dx, center.dy + hh)           // bottom
      ..lineTo(center.dx - hw, center.dy - hh / 2) // left
      ..close();

    // For isometric with depth, use a more traditional approach:
    // Simple flat rhombus
    final flatPath = Path()
      ..moveTo(center.dx, center.dy - hh)
      ..lineTo(center.dx + hw * 0.8, center.dy)
      ..lineTo(center.dx, center.dy + hh)
      ..lineTo(center.dx - hw * 0.8, center.dy)
      ..close();

    final fillColor = tile.color.withOpacity(0.5);
    canvas.drawPath(flatPath, Paint()..color = fillColor);
    canvas.drawPath(flatPath, Paint()
      ..color = Colors.black26
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5);

    // Ownership color strip (bottom half fill)
    if (ownerColor != null && (tile.kind == 'OrdinaryProperty' || tile.kind == 'SpecialProperty')) {
      final ownerPath = Path()
        ..moveTo(center.dx, center.dy)
        ..lineTo(center.dx + hw * 0.8, center.dy)
        ..lineTo(center.dx, center.dy + hh)
        ..lineTo(center.dx - hw * 0.8, center.dy)
        ..close();
      canvas.drawPath(ownerPath, Paint()..color = ownerColor.withOpacity(0.6));
    }
  }

  void _drawTileName(Canvas canvas, BoardTileViewModel tile, Offset center) {
    final fontSize = math.max(tileWidth * camera.zoom * 0.09, 8.0);
    final name = _displayName(tile);
    if (name.isEmpty) return;
    final tp = TextPainter(
      text: TextSpan(
        text: name,
        style: TextStyle(
          color: Colors.black87,
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 1,
      ellipsis: '..',
    );
    tp.layout(maxWidth: tileWidth * 0.7);
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - fontSize * 1.5));
  }

  void _drawPlayers(Canvas canvas, List<PlayerTokenViewModel> players, Offset center) {
    for (var i = 0; i < players.length; i++) {
      final p = players[i];
      final offset = Offset(
        (i - (players.length - 1) / 2) * 6,
        tileHeight * 0.15,
      );
      final pos = center + offset;
      final radius = math.max(tileWidth * camera.zoom * 0.08, 4.0);
      canvas.drawCircle(pos, radius, Paint()..color = p.color);
      canvas.drawCircle(pos, radius, Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0);
      final initialPainter = TextPainter(
        text: TextSpan(
          text: p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
          style: TextStyle(
            color: Colors.white,
            fontSize: radius * 1.0,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      );
      initialPainter.layout();
      initialPainter.paint(
        canvas,
        Offset(pos.dx - initialPainter.width / 2, pos.dy - initialPainter.height / 2),
      );
    }
  }

  String _displayName(BoardTileViewModel tile) {
    final name = tile.name;
    if (name.startsWith('tile.')) return name.substring(5);
    if (name.startsWith('prop.')) return name.substring(5);
    return name;
  }

  @override
  bool shouldRepaint(covariant IsometricBoardPainter oldDelegate) => true;
}

// ============================================================================
// Minimap Painter
// ============================================================================

class MinimapPainter extends CustomPainter {
  final BoardViewModel viewModel;
  final int gridSize;
  final double tileWidth;
  final double tileHeight;
  final Map<String, Color> ownerColors;

  MinimapPainter({
    required this.viewModel,
    required this.gridSize,
    required this.tileWidth,
    required this.tileHeight,
    required this.ownerColors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final tiles = viewModel.tiles;
    if (tiles.isEmpty) return;

    final scale = math.min(
      size.width / (gridSize * tileWidth * 0.8),
      size.height / (gridSize * tileHeight * 0.8),
    );

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);

    final tilesPerSide = (tiles.length - 4) ~/ 4;
    final positions = <int, int>{};
    int tileIdx = 0;
    for (var i = 0; i <= tilesPerSide; i++) {
      positions[tileIdx] = (gridSize - 1) * gridSize + i;
      tileIdx++;
    }
    for (var i = 0; i < tilesPerSide; i++) {
      positions[tileIdx] = (gridSize - 2 - i) * gridSize + (gridSize - 1);
      tileIdx++;
    }
    for (var i = 0; i <= tilesPerSide; i++) {
      positions[tileIdx] = 0 * gridSize + (gridSize - 1 - i);
      tileIdx++;
    }
    for (var i = 0; i < tilesPerSide; i++) {
      positions[tileIdx] = (1 + i) * gridSize + 0;
      tileIdx++;
    }

    final hw = tileWidth / 2;
    final hh = tileHeight / 2;

    for (final entry in positions.entries) {
      final ti = entry.key;
      if (ti >= tiles.length) continue;
      final pos = entry.value;
      final row = pos ~/ gridSize;
      final col = pos % gridSize;
      final tile = tiles[ti];
      final center = gridToIso(row, col, tileWidth, tileHeight);
      final ownerColor = ownerColors[tile.id];

      // Draw tile as small rhombus
      final path = Path()
        ..moveTo(center.dx, center.dy - hh)
        ..lineTo(center.dx + hw * 0.8, center.dy)
        ..lineTo(center.dx, center.dy + hh)
        ..lineTo(center.dx - hw * 0.8, center.dy)
        ..close();

      if (ownerColor != null) {
        canvas.drawPath(path, Paint()..color = ownerColor.withOpacity(0.7));
      } else {
        canvas.drawPath(path, Paint()..color = tile.color.withOpacity(0.3));
      }
      canvas.drawPath(path, Paint()
        ..color = Colors.black12
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MinimapPainter oldDelegate) => true;
}

// ============================================================================
// Isometric Board Widget (StatefulWidget)
// ============================================================================

class IsometricBoardWidget extends StatefulWidget {
  final BoardViewModel viewModel;

  const IsometricBoardWidget({super.key, required this.viewModel});

  @override
  State<IsometricBoardWidget> createState() => _IsometricBoardWidgetState();
}

class _IsometricBoardWidgetState extends State<IsometricBoardWidget> {
  final IsometricCamera _camera = IsometricCamera();
  int _gridSize = 11;
  double _tileWidth = 60;
  double _tileHeight = 60;
  Offset _lastDragPos = Offset.zero;
  double _boardSize = 600;

  // GlobalKey to repaint just the CustomPaint without full rebuild
  final GlobalKey _paintKey = GlobalKey();

  Map<String, Color> get _ownerColors {
    final result = <String, Color>{};
    const ownerColors = [
      Color(0xFFD32F2F),
      Color(0xFF1976D2),
      Color(0xFF388E3C),
      Color(0xFFFBC02D),
      Color(0xFF8E24AA),
      Color(0xFFFF6F00),
    ];
    for (final entry in widget.viewModel.propertyOwners.entries) {
      final playerIdx = int.tryParse(
          entry.value.replaceAll('player_', '')) ?? 0;
      result[entry.key] = ownerColors[playerIdx % ownerColors.length];
    }
    return result;
  }

  void _triggerPaint() {
    final renderObj = _paintKey.currentContext?.findRenderObject();
    if (renderObj is RenderObject) {
      renderObj.markNeedsPaint();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tiles = widget.viewModel.tiles;
    final numTiles = tiles.length;
    if (numTiles < 4) {
      return const Center(child: Text('Not enough tiles'));
    }
    final tilesPerSide = (numTiles - 4) ~/ 4;
    _gridSize = tilesPerSide + 2;

    return LayoutBuilder(
      builder: (context, constraints) {
        _boardSize = math.min(constraints.maxWidth, constraints.maxHeight);
        _tileWidth = _boardSize / _gridSize;
        _tileHeight = _boardSize / _gridSize;

        return ClipRect(
          child: GestureDetector(
            onPanStart: (details) {
              _lastDragPos = details.localPosition;
            },
            onPanUpdate: (details) {
              final delta = details.localPosition - _lastDragPos;
              _lastDragPos = details.localPosition;
              _camera.pan(-delta.dx, -delta.dy);
              _triggerPaint();
            },
            child: Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  _camera.zoomBy(
                    event.scrollDelta.dy < 0 ? 1.1 : 0.9,
                    event.localPosition,
                  );
                  setState(() {});
                }
              },
              child: RepaintBoundary(
                key: _paintKey,
                child: CustomPaint(
                  painter: IsometricBoardPainter(
                    viewModel: widget.viewModel,
                    camera: _camera,
                    gridSize: _gridSize,
                    tileWidth: _tileWidth,
                    tileHeight: _tileHeight,
                    ownerColors: _ownerColors,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ============================================================================
// Minimap Widget
// ============================================================================

class MinimapWidget extends StatelessWidget {
  final BoardViewModel viewModel;
  final int gridSize;
  final double tileWidth;
  final double tileHeight;
  final Map<String, Color> ownerColors;

  const MinimapWidget({
    super.key,
    required this.viewModel,
    required this.gridSize,
    required this.tileWidth,
    required this.tileHeight,
    required this.ownerColors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      height: 140,
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: CustomPaint(
          painter: MinimapPainter(
            viewModel: viewModel,
            gridSize: gridSize,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            ownerColors: ownerColors,
          ),
        ),
      ),
    );
  }
}
