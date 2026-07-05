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
// Edge / corner classification for text rendering
// ============================================================================

/// The two possible isometric edge directions.
///
/// In the diamond tile:
/// ```
///        (0, -hh) top
///          /\
///         /  \
///   (-hw,0)  (hw,0)
///   left     \  /  right
///             \/
///        (0, +hh) bottom
/// ```
/// - [slash] `/`  edges: left→top and right→bottom (angle = +isoA)
/// - [backslash] `\` edges: top→right and bottom→left (angle = −isoA)
enum IsoEdge { slash, backslash }

/// Edge text-layout result — used by [_drawTileName].
///
/// Fields are positional for brevity:
///   (mx, my)  — midpoint offset from tile centre
///   angle     — rotation (radians)
///   anchorEnd — `true` → text END at midpoint, `false` → START at midpoint
class _EdgeTextLayout {
  final double mx;
  final double my;
  final double angle;
  final bool anchorEnd;

  const _EdgeTextLayout(this.mx, this.my, this.angle, this.anchorEnd);
}

/// Determine edge text layout from the grid-movement vector `(Δrow, Δcol)`.
///
/// Movement       Iso edge   Layout
/// ─────────────────────────────────────────────────
/// ( 0, +1) right  \ forward  Left-Bottom mid, −isoA, END
/// ( 0, −1) left   \ backward Right-Top    mid, −isoA, START
/// (+1,  0) down   / forward  Left-Top     mid, +isoA, END
/// (−1,  0) up     / backward Right-Bottom mid, +isoA, START
_EdgeTextLayout _edgeLayoutForMove(int dr, int dc, double hw, double hh) {
  final isoA = math.atan2(hh, hw);

  if (dc > 0) {
    // Moving RIGHT — \ forward
    return _EdgeTextLayout(-hw / 2, hh / 2, -isoA, true);
  }
  if (dc < 0) {
    // Moving LEFT — \ backward
    return _EdgeTextLayout(hw / 2, -hh / 2, -isoA, false);
  }
  if (dr > 0) {
    // Moving DOWN — / forward
    return _EdgeTextLayout(-hw / 2, -hh / 2, isoA, true);
  }
  // Moving UP — / backward
  return _EdgeTextLayout(hw / 2, hh / 2, isoA, false);
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

  /// Pre-computed edge direction for each tile index (from prev → curr move).
  late final List<int> _tileMovements; // 0:right, 1:left, 2:down, 3:up

  IsometricBoardPainter({
    required this.viewModel,
    required this.camera,
    required this.gridSize,
    required this.tileWidth,
    required this.tileHeight,
    required this.ownerColors,
  }) {
    _tileMovements = _computeTileMovements();
  }

  /// Build movement-direction codes for each tile on the perimeter.
  ///
  /// Returns a list parallel to [viewModel.tiles] where each element is:
  ///   0 → right  (dc>0), 1 → left  (dc<0),
  ///   2 → down   (dr>0), 3 → up    (dr<0).
  List<int> _computeTileMovements() {
    final tiles = viewModel.tiles;
    final n = tiles.length;
    if (n < 4) return List.filled(n, 0);

    // Use explicit perimeter positions when provided; otherwise fall back
    // to the standard rectangular formula.
    final rows = List<int>.filled(n, 0);
    final cols = List<int>.filled(n, 0);

    final explicit = viewModel.perimeterPositions;
    if (explicit != null && explicit.length >= n) {
      for (var i = 0; i < n; i++) {
        rows[i] = explicit[i].$1;
        cols[i] = explicit[i].$2;
      }
    } else {
      final tilesPerSide = (n - 4) ~/ 4;
      final gs = tilesPerSide + 2;
      int idx = 0;
      for (var i = 0; i < gs; i++) {
        rows[idx] = gs - 1; cols[idx] = i; idx++;
      }
      for (var i = 0; i < gs - 1; i++) {
        rows[idx] = gs - 2 - i; cols[idx] = gs - 1; idx++;
      }
      for (var i = 0; i < gs - 1; i++) {
        rows[idx] = 0; cols[idx] = gs - 2 - i; idx++;
      }
      for (var i = 0; i < gs - 2; i++) {
        rows[idx] = 1 + i; cols[idx] = 0; idx++;
      }
    }

    final moves = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final prevI = (i - 1 + n) % n;
      final dr = rows[i] - rows[prevI];
      final dc = cols[i] - cols[prevI];
      if (dc > 0)       moves[i] = 0; // right
      else if (dc < 0)  moves[i] = 1; // left
      else if (dr > 0)  moves[i] = 2; // down
      else              moves[i] = 3; // up
    }
    return moves;
  }

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

    // ── Resolve perimeter positions (explicit or computed) ──────────────
    final n = tiles.length;
    final rows = List<int>.filled(n, 0);
    final cols = List<int>.filled(n, 0);

    final explicit = viewModel.perimeterPositions;
    if (explicit != null && explicit.length >= n) {
      for (var i = 0; i < n; i++) {
        rows[i] = explicit[i].$1;
        cols[i] = explicit[i].$2;
      }
    } else {
      for (var i = 0; i < n; i++) {
        final pos = _computeRectPos(i, n, gridSize);
        rows[i] = pos.$1;
        cols[i] = pos.$2;
      }
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
      // Sort by isoY ascending (paint further tiles first)
      return (rows[a] + cols[a]).compareTo(rows[b] + cols[b]);
    });

    for (final ti in tileIndices) {
      if (ti >= tiles.length) continue;
      final tile = tiles[ti];
      final center = gridToIso(rows[ti], cols[ti], tileWidth, tileHeight);
      final players = playersOnTile[ti] ?? [];
      final ownerColor = ownerColors[tile.id];

      _drawTile(canvas, tile, center, ownerColor);
      _drawPlayers(canvas, players, center);
    }

    // Draw tile texts on top (front-most) — along inner edges
    for (final ti in tileIndices) {
      if (ti >= tiles.length) continue;
      final tile = tiles[ti];
      final center = gridToIso(rows[ti], cols[ti], tileWidth, tileHeight);
      _drawTileName(canvas, tile, center, ti);
    }

    canvas.restore();
  }

  /// Rectangular-formula position for tile index [i] (fallback).
  (int, int) _computeRectPos(int i, int n, int gs) {
    final tps = (n - 4) ~/ 4.ceil();
    final g = tps + 2;
    int idx = 0;
    // bottom
    for (var r = 0; r < g; r++) {
      if (idx == i) return (g - 1, r);
      idx++;
    }
    // right
    for (var r = 0; r < g - 1; r++) {
      if (idx == i) return (g - 2 - r, g - 1);
      idx++;
    }
    // top
    for (var c = 0; c < g - 1; c++) {
      if (idx == i) return (0, g - 2 - c);
      idx++;
    }
    // left
    for (var r = 0; r < g - 2; r++) {
      if (idx == i) return (1 + r, 0);
      idx++;
    }
    return (0, 0);
  }

  void _drawTile(Canvas canvas, BoardTileViewModel tile, Offset center, Color? ownerColor) {
    final hw = tileWidth / 2;   // half tile width (grid step = tileW/2)
    final hh = tileHeight / 4;  // half tile height (grid step = tileH/4)

    // Proper isometric diamond tile.
    // The 4 vertices from center: top(0,-hh), right(+hw,0), bottom(0,+hh), left(-hw,0)
    // This ensures adjacent tiles meet exactly at edges without gaps or overlaps.
    final diamond = Path()
      ..moveTo(center.dx, center.dy - hh)         // top
      ..lineTo(center.dx + hw, center.dy)          // right
      ..lineTo(center.dx, center.dy + hh)          // bottom
      ..lineTo(center.dx - hw, center.dy)          // left
      ..close();

    // Fill with tile kind color
    canvas.drawPath(diamond, Paint()..color = tile.color.withOpacity(0.5));

    // Border
    canvas.drawPath(diamond, Paint()
      ..color = Colors.black26
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5);

    // Ownership color strip (lower half of diamond).
    // Shown for all ownable property types when owned.
    if (ownerColor != null &&
        (tile.kind == 'OrdinaryProperty' ||
         tile.kind == 'SpecialProperty' ||
         tile.kind == 'ExtensionProperty')) {
      final ownerDiamond = Path()
        ..moveTo(center.dx, center.dy)             // center
        ..lineTo(center.dx + hw, center.dy)         // right
        ..lineTo(center.dx, center.dy + hh)         // bottom
        ..lineTo(center.dx - hw, center.dy)         // left
        ..close();
      canvas.drawPath(ownerDiamond, Paint()..color = ownerColor.withOpacity(0.6));

      // House icon in the centre of the ownership triangle
      // as a colour-independent ownership indicator.
      final houseSize = math.max(tileWidth * camera.zoom * 0.12, 5.0);
      final housePainter = TextPainter(
        text: TextSpan(
          text: '🏠',
          style: TextStyle(fontSize: houseSize),
        ),
        textDirection: TextDirection.ltr,
      );
      housePainter.layout();
      housePainter.paint(
        canvas,
        Offset(center.dx - housePainter.width / 2, center.dy + hh * 0.3),
      );
    }
  }

  void _drawTileName(Canvas canvas, BoardTileViewModel tile, Offset center, int tileIndex) {
    final fontSize = math.max(tileWidth * camera.zoom * 0.1, 9.0);
    final name = _displayName(tile);
    if (name.isEmpty) return;

    final tp = TextPainter(
      text: TextSpan(
        text: name,
        style: TextStyle(
          color: Colors.black87,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 1,
      ellipsis: '..',
    );
    tp.layout();

    final hw = tileWidth / 2;
    final hh = tileHeight / 4;

    // 1. Determine movement direction for this tile (from prev → curr).
    final moveCode = tileIndex < _tileMovements.length
        ? _tileMovements[tileIndex]
        : 0;
    // 0:right, 1:left, 2:down, 3:up
    final dr = moveCode == 2 ? 1 : (moveCode == 3 ? -1 : 0);
    final dc = moveCode == 0 ? 1 : (moveCode == 1 ? -1 : 0);

    // 2. Look up text layout from the movement direction.
    final layout = _edgeLayoutForMove(dr, dc, hw, hh);

    // 3. Render text using the resolved layout.
    canvas.save();
    canvas.translate(
      center.dx + layout.mx,
      center.dy + layout.my,
    );
    canvas.rotate(layout.angle);
    if (layout.anchorEnd) {
      // END alignment: text ends at the midpoint
      tp.paint(canvas, Offset(-tp.width, -tp.height / 2));
    } else {
      // START alignment: text starts at the midpoint
      tp.paint(canvas, Offset(0, -tp.height / 2));
    }
    canvas.restore();
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

  /// Hit-test a screen-space [point] against the board tiles.
  /// Returns the tile index if the point falls inside a tile's diamond, or
  /// `null` if it misses every tile.
  int? hitTestTile(Offset point, Size canvasSize) {
    final n = viewModel.tiles.length;
    if (n == 0) return null;

    // ── 1. Inverse camera transform ──────────────────────────────────
    // In Flutter's Canvas the LAST transform applied is FIRST:
    //   M = translate(w/2 - ox, h/2 - oy) × scale(z)
    //
    // So a canvas point (cx, cy) → screen (sx, sy):
    //   sx = cx * z + (w/2 - ox)
    //   sy = cy * z + (h/2 - oy)
    //
    // Inverse: given screen (px, py), solve for canvas (cx, cy):
    //   cx = (px - w/2 + ox) / z
    //   cy = (py - h/2 + oy) / z
    final cx = (point.dx - canvasSize.width / 2 + camera.offsetX) / camera.zoom;
    final cy = (point.dy - canvasSize.height / 2 + camera.offsetY) / camera.zoom;

    // ── 2. Resolve perimeter positions ───────────────────────────────
    final rows = List<int>.filled(n, 0);
    final cols = List<int>.filled(n, 0);
    final explicit = viewModel.perimeterPositions;
    if (explicit != null && explicit.length >= n) {
      for (var i = 0; i < n; i++) {
        rows[i] = explicit[i].$1;
        cols[i] = explicit[i].$2;
      }
    } else {
      for (var i = 0; i < n; i++) {
        final pos = _computeRectPos(i, n, gridSize);
        rows[i] = pos.$1;
        cols[i] = pos.$2;
      }
    }

    // ── 3. Test each tile's diamond ──────────────────────────────────
    final hw = tileWidth / 2;
    final hh = tileHeight / 4;

    // Sort by isoY descending so that front tiles are tested first
    final indices = List.generate(n, (i) => i);
    indices.sort((a, b) => (rows[b] + cols[b]).compareTo(rows[a] + cols[a]));

    for (final ti in indices) {
      final center = gridToIso(rows[ti], cols[ti], tileWidth, tileHeight);
      // Point-in-diamond test: |dx|/hw + |dy|/hh <= 1
      final dx = (cx - center.dx).abs();
      final dy = (cy - center.dy).abs();
      if (dx / hw + dy / hh <= 1.0) {
        return ti;
      }
    }
    return null;
  }

  @override
  bool shouldRepaint(covariant IsometricBoardPainter oldDelegate) => true;
}

// ============================================================================
// Minimal data class for tile-tap results
// ============================================================================

/// Lightweight result of a tile tap, passed up to the game screen.
class TileTapResult {
  final int tileIndex;
  final String tileId;
  final String kind;

  const TileTapResult({
    required this.tileIndex,
    required this.tileId,
    required this.kind,
  });
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

    final hw = tileWidth / 2;
    final hh = tileHeight / 4;

    // Resolve perimeter positions (explicit or rectangular)
    final n = tiles.length;
    final rows = List<int>.filled(n, 0);
    final cols = List<int>.filled(n, 0);

    final explicit = viewModel.perimeterPositions;
    if (explicit != null && explicit.length >= n) {
      for (var i = 0; i < n; i++) {
        rows[i] = explicit[i].$1;
        cols[i] = explicit[i].$2;
      }
    } else {
      int idx = 0;
      for (var i = 0; i < gridSize; i++) {
        if (idx < n) { rows[idx] = gridSize - 1; cols[idx] = i; idx++; }
      }
      for (var i = 0; i < gridSize - 1; i++) {
        if (idx < n) { rows[idx] = gridSize - 2 - i; cols[idx] = gridSize - 1; idx++; }
      }
      for (var i = 0; i < gridSize - 1; i++) {
        if (idx < n) { rows[idx] = 0; cols[idx] = gridSize - 2 - i; idx++; }
      }
      for (var i = 0; i < gridSize - 2; i++) {
        if (idx < n) { rows[idx] = 1 + i; cols[idx] = 0; idx++; }
      }
    }

    // Compute scale and centre using the bounding box of all positions
    double minR = rows[0].toDouble(), maxR = rows[0].toDouble();
    double minC = cols[0].toDouble(), maxC = cols[0].toDouble();
    for (var i = 1; i < n; i++) {
      if (rows[i] < minR) minR = rows[i].toDouble();
      if (rows[i] > maxR) maxR = rows[i].toDouble();
      if (cols[i] < minC) minC = cols[i].toDouble();
      if (cols[i] > maxC) maxC = cols[i].toDouble();
    }
    final spanR = maxR - minR + 1;
    final spanC = maxC - minC + 1;
    final scale = math.min(
      size.width / (spanC * tileWidth * 1.1),
      size.height / (spanR * tileHeight * 1.1),
    );

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);

    for (var i = 0; i < n; i++) {
      final tile = tiles[i];
      final center = gridToIso(rows[i], cols[i], tileWidth, tileHeight);
      final ownerColor = ownerColors[tile.id];

      final path = Path()
        ..moveTo(center.dx, center.dy - hh)
        ..lineTo(center.dx + hw, center.dy)
        ..lineTo(center.dx, center.dy + hh)
        ..lineTo(center.dx - hw, center.dy)
        ..close();

      if (ownerColor != null) {
        canvas.drawPath(path, Paint()..color = ownerColor.withOpacity(0.7));
      } else if (tile.kind == 'OrdinaryProperty' ||
                 tile.kind == 'SpecialProperty' ||
                 tile.kind == 'ExtensionProperty') {
        canvas.drawPath(path, Paint()..color = Colors.grey.withOpacity(0.35));
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
  final ValueChanged<TileTapResult>? onTileTap;

  const IsometricBoardWidget({
    super.key,
    required this.viewModel,
    this.onTileTap,
  });

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

    // Grid size: from explicit positions or rectangular formula.
    final explicit = widget.viewModel.perimeterPositions;
    if (explicit != null && explicit.length >= numTiles) {
      int maxR = 0, maxC = 0;
      for (final p in explicit) {
        if (p.$1 > maxR) maxR = p.$1;
        if (p.$2 > maxC) maxC = p.$2;
      }
      _gridSize = (maxR > maxC ? maxR : maxC) + 1;
    } else {
      final tilesPerSide = (numTiles - 4) ~/ 4;
      _gridSize = tilesPerSide + 2;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _boardSize = math.min(constraints.maxWidth, constraints.maxHeight);
        _tileWidth = _boardSize / _gridSize;
        _tileHeight = _boardSize / _gridSize;

        // We need the CustomPaint's size for hit-testing.
        // Use a GlobalKey on the RepaintBoundary to get its render-box.
        return ClipRect(
          child: GestureDetector(
            onTapUp: (details) {
              final renderObj =
                  _paintKey.currentContext?.findRenderObject();
              if (renderObj is RenderBox) {
                final size = renderObj.size;
                // Ask the painter to hit-test
                final painter = IsometricBoardPainter(
                  viewModel: widget.viewModel,
                  camera: _camera,
                  gridSize: _gridSize,
                  tileWidth: _tileWidth,
                  tileHeight: _tileHeight,
                  ownerColors: _ownerColors,
                );
                final ti = painter.hitTestTile(details.localPosition, size);
                if (ti != null && widget.onTileTap != null) {
                  final tile = widget.viewModel.tiles[ti];
                  widget.onTileTap!(TileTapResult(
                    tileIndex: ti,
                    tileId: tile.id,
                    kind: tile.kind,
                  ));
                }
              }
            },
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
