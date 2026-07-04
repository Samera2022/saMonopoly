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
        return Colors.yellow.shade700;
      case 'Jail':
        return Colors.grey;
      case 'Hospital':
        return Colors.pink;
      default:
        return Colors.grey.shade300;
    }
  }

  /// Property group colour for colour-group bonuses.
  static const propertyColors = {
    'brown': Color(0xFF8B4513),
    'lightblue': Color(0xFF87CEEB),
    'pink': Color(0xFFFF69B4),
    'orange': Color(0xFFFF8C00),
    'red': Color(0xFFDC143C),
    'yellow': Color(0xFFFFD700),
    'green': Color(0xFF228B22),
    'darkblue': Color(0xFF00008B),
  };

  /// Return a group colour if this tile belongs to a property colour group.
  Color? get groupColor {
    // The group can be encoded in the tile id or we default to the kind colour.
    return null; // Override per map in the view model.
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
  final Map<String, Color> propertyGroupColors;
  final Map<String, String> propertyOwners;

  const BoardViewModel({
    required this.mapName,
    required this.tiles,
    this.players = const [],
    this.activePlayerIndex = 0,
    this.propertyGroupColors = const {},
    this.propertyOwners = const {},
  });

  factory BoardViewModel.fromJson(Map<String, dynamic> json) {
    final tilesList = (json['tiles'] as List<dynamic>?)
            ?.map((t) => BoardTileViewModel.fromJson(t as Map<String, dynamic>))
            .toList() ??
        [];
    return BoardViewModel(
      mapName: json['mapName'] as String? ?? '',
      tiles: tilesList,
    );
  }
}

// ============================================================================
// BoardPainter – renders the classic square Monopoly board
// ============================================================================

/// Layout constants – these define the visual proportions.
const double _kTileWidth = 1.0; // unit – scaled relative to canvas
const double _kCornerSize = 1.5; // corner tiles are larger
const double _kTokenRadius = 0.12;
const double _kFontSize = 0.12;
const double _kPropertyColorStrip = 0.25;

class TileLayout {
  final Rect rect;
  final double rotation;
  TileLayout(this.rect, this.rotation);
}

class BoardPainter extends CustomPainter {
  final BoardViewModel viewModel;

  BoardPainter(this.viewModel);

  // ---- Colour palette ---------------------------------------------------
  static const Color _boardBg = Color(0xFFE8F5E9);
  static const Color _boardBorder = Color(0xFF2E7D32);
  static const Color _startGreen = Color(0xFF4CAF50);
  static const Color _chanceOrange = Color(0xFFFF9800);
  static const Color _jailGrey = Color(0xFF9E9E9E);
  static const Color _bankYellow = Color(0xFFFBC02D);
  static const Color _lotteryRed = Color(0xFFE53935);
  static const Color _hospitalPink = Color(0xFFEC407A);
  static const Color _cardShopAmber = Color(0xFFFFA000);
  static const Color _textDark = Color(0xFF212121);
  static const Color _textLight = Color(0xFFFFFFFF);

  // Pre-defined player colours
  static const List<Color> _playerColors = [
    Color(0xFFD32F2F), // red
    Color(0xFF1976D2), // blue
    Color(0xFF388E3C), // green
    Color(0xFFFBC02D), // yellow
    Color(0xFF8E24AA), // purple
    Color(0xFFFF6F00), // orange
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final numTiles = viewModel.tiles.length;
    if (numTiles < 4) return;

    final sideLength =
        (size.width < size.height ? size.width : size.height) * 0.92;
    final originX = (size.width - sideLength) / 2;
    final originY = (size.height - sideLength) / 2;

    // Determine tiles per side: 4 corners + (numTiles - 4) edge tiles
    final tilesPerSide = (numTiles - 4) ~/ 4;
    final remainder = (numTiles - 4) % 4;
    final actualTilesPerSide = <int>[
      tilesPerSide + (remainder > 0 ? 1 : 0),
      tilesPerSide + (remainder > 1 ? 1 : 0),
      tilesPerSide + (remainder > 2 ? 1 : 0),
      tilesPerSide,
    ];

    // Calculate tile sizes
    final cornerSize = sideLength * 0.18;
    final edgeLength = sideLength - cornerSize * 2;
    final tileSizeBySide = <double>[
      for (var i = 0; i < 4; i++)
        actualTilesPerSide[i] > 0
            ? edgeLength / actualTilesPerSide[i]
            : cornerSize,
    ];

    // Build tile layout: for each tile, store its (rect, rotation, side index)
    // Side layout:
    //   Side 0 (bottom):  left-to-right
    //   Side 1 (right):   bottom-to-top
    //   Side 2 (top):     right-to-left
    //   Side 3 (left):    top-to-bottom

    final layouts = <TileLayout>[];
    var tileIdx = 0;

    for (var side = 0; side < 4; side++) {
      final count = actualTilesPerSide[side];
      final tSize = tileSizeBySide[side];

      // Corner at the start of this side
      if (side == 0) {
        // Bottom-left corner
        final cl = _cornerLayout(originX, originY + sideLength - cornerSize,
            sideLength, cornerSize, side, false);
        layouts.add(cl);
        tileIdx++;
      }

      // Edge tiles
      for (var i = 0; i < count; i++) {
        final el = _edgeTileLayout(
            originX, originY, sideLength, side, i, count, cornerSize, tSize);
        layouts.add(el);
        tileIdx++;
      }

      // Corner at the end of this side (unless it's the last corner already done)
      if (side < 3) {
        final nextCornerSide = side + 1;
        final cl = _cornerLayout(originX, originY, sideLength, cornerSize,
            nextCornerSide, true);
        layouts.add(cl);
        tileIdx++;
      }
    }

    // Ensure we have exactly numTiles layouts (handle odd counts)
    while (layouts.length < numTiles) {
      layouts.add(layouts.last);
    }
    if (layouts.length > numTiles) {
      layouts.removeRange(numTiles, layouts.length);
    }

    // ---- Draw board background -------------------------------------------
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(originX - 4, originY - 4, sideLength + 8, sideLength + 8),
      const Radius.circular(8),
    );
    canvas.drawRRect(bgRect, Paint()..color = _boardBorder);
    final innerRect = Rect.fromLTWH(originX, originY, sideLength, sideLength);
    canvas.drawRect(innerRect, Paint()..color = _boardBg);

    // ---- Draw center area (title + "GO") ---------------------------------
    final centerRect = Rect.fromLTWH(
      originX + cornerSize,
      originY + cornerSize,
      sideLength - cornerSize * 2,
      sideLength - cornerSize * 2,
    );
    final centerPaint = Paint()..color = Colors.white.withOpacity(0.3);
    canvas.drawRect(centerRect, centerPaint);

    // Title text in center
    final centerWidth = centerRect.width;
    final centerHeight = centerRect.height;
    if (centerWidth > 0 && centerHeight > 0) {
      final titleSize = centerWidth * 0.08;
      _drawCenteredText(
        canvas,
        viewModel.mapName.isNotEmpty ? viewModel.mapName : 'saMonopoly',
        Offset(centerRect.center.dx, centerRect.center.dy - titleSize * 0.5),
        titleSize,
        _textDark.withOpacity(0.5),
      );
      _drawCenteredText(
        canvas,
        'MONOPOLY',
        Offset(centerRect.center.dx, centerRect.center.dy + titleSize * 0.5),
        titleSize * 0.6,
        _textDark.withOpacity(0.3),
      );
    }

    // ---- Draw each tile --------------------------------------------------
    for (var i = 0; i < layouts.length && i < viewModel.tiles.length; i++) {
      final tile = viewModel.tiles[i];
      final layout = layouts[i];
      _drawTile(canvas, tile, layout.rect, layout.rotation);
    }

    // ---- Draw player tokens ----------------------------------------------
    for (var i = 0; i < viewModel.players.length; i++) {
      final player = viewModel.players[i];
      final tileIdx = viewModel.tiles
          .indexWhere((t) => t.id == player.tileId);
      if (tileIdx >= 0 && tileIdx < layouts.length) {
        final layout = layouts[tileIdx];
        _drawPlayerToken(
          canvas,
          player,
          layout.rect.center,
          i,
          viewModel.players.length,
          layout.rotation,
        );
      }
    }
  }

  // ---- Tile drawing helpers ---------------------------------------------

  TileLayout _cornerLayout(double ox, double oy, double sideLen,
      double cornerSize, int side, bool isEnd) {
    switch (side) {
      case 0: // bottom-left
        return TileLayout(
          rect: Rect.fromLTWH(ox, oy + sideLen - cornerSize, cornerSize,
              cornerSize),
          rotation: 0,
        );
      case 1: // bottom-right
        return TileLayout(
          rect: Rect.fromLTWH(
              ox + sideLen - cornerSize, oy + sideLen - cornerSize, cornerSize,
              cornerSize),
          rotation: math.pi / 2,
        );
      case 2: // top-right
        return TileLayout(
          rect: Rect.fromLTWH(
              ox + sideLen - cornerSize, oy, cornerSize, cornerSize),
          rotation: math.pi,
        );
      case 3: // top-left
        return TileLayout(
          rect:
              Rect.fromLTWH(ox, oy, cornerSize, cornerSize),
          rotation: -math.pi / 2,
        );
      default:
        return TileLayout(
          rect: Rect.fromLTWH(ox, oy, cornerSize, cornerSize),
          rotation: 0,
        );
    }
  }

  TileLayout _edgeTileLayout(
    double ox,
    double oy,
    double sideLen,
    int side,
    int index,
    int count,
    double cornerSize,
    double tileSize,
  ) {
    // Side 0 (bottom): left-to-right, tiles above bottom edge
    // Side 1 (right):  bottom-to-top, tiles left of right edge
    // Side 2 (top):    right-to-left, tiles below top edge
    // Side 3 (left):   top-to-bottom, tiles right of left edge

    switch (side) {
      case 0: // bottom edge
        return TileLayout(
          rect: Rect.fromLTWH(
            ox + cornerSize + index * tileSize,
            oy + sideLen - cornerSize,
            tileSize,
            cornerSize,
          ),
          rotation: 0,
        );
      case 1: // right edge
        return TileLayout(
          rect: Rect.fromLTWH(
            ox + sideLen - cornerSize,
            oy + sideLen - cornerSize - (index + 1) * tileSize,
            cornerSize,
            tileSize,
          ),
          rotation: math.pi / 2,
        );
      case 2: // top edge
        return TileLayout(
          rect: Rect.fromLTWH(
            ox + sideLen - cornerSize - (index + 1) * tileSize,
            oy,
            tileSize,
            cornerSize,
          ),
          rotation: math.pi,
        );
      case 3: // left edge
        return TileLayout(
          rect: Rect.fromLTWH(
            ox,
            oy + cornerSize + index * tileSize,
            cornerSize,
            tileSize,
          ),
          rotation: 3 * math.pi / 2,
        );
      default:
        return TileLayout(
          rect: Rect.fromLTWH(ox, oy, tileSize, cornerSize),
          rotation: 0,
        );
    }
  }

  void _drawTile(
      Canvas canvas, BoardTileViewModel tile, Rect rect, double rotation) {
    canvas.save();
    canvas.translate(rect.center.dx, rect.center.dy);
    canvas.rotate(rotation);
    final localRect = Rect.fromCenter(
      center: Offset.zero,
      width: rect.width,
      height: rect.height,
    );

    // Tile background
    final bgPaint = Paint()..color = tile.color.withOpacity(0.15);
    canvas.drawRect(localRect, bgPaint);

    // Property colour strip at the top (for property tiles)
    if (tile.kind == 'OrdinaryProperty' || tile.kind == 'SpecialProperty') {
      final stripRect = Rect.fromLTWH(
        localRect.left,
        localRect.top,
        localRect.width,
        localRect.height * _kPropertyColorStrip,
      );
      canvas.drawRect(stripRect, Paint()..color = tile.color);
    }

    // Tile border
    final borderPaint = Paint()
      ..color = Colors.black.withOpacity(0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRect(localRect, borderPaint);

    // Tile name text
    final fontSize = localRect.width * 0.1;
    if (fontSize > 4) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: tile.name,
          style: TextStyle(
            color: _textDark,
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 2,
        ellipsis: '..',
      );
      textPainter.layout(maxWidth: localRect.width * 0.9);
      final textOffset = Offset(
        -textPainter.width / 2,
        tile.kind == 'OrdinaryProperty'
            ? localRect.height * (_kPropertyColorStrip + 0.05)
            : localRect.height * 0.1,
      );
      textPainter.paint(canvas, textOffset);
    }

    canvas.restore();
  }

  void _drawPlayerToken(Canvas canvas, PlayerTokenViewModel player,
      Offset center, int index, int totalPlayers, double rotation) {
    // Offset each player slightly to avoid overlap
    final angleOffset = (index / totalPlayers) * math.pi * 2;
    final offsetRadius = 4.0;
    final offset = Offset(
      math.cos(angleOffset) * offsetRadius,
      math.sin(angleOffset) * offsetRadius,
    );
    final tokenCenter = center + offset;

    // Token shadow
    canvas.drawCircle(
      tokenCenter + const Offset(1, 1),
      _kTokenRadius * 20,
      Paint()..color = Colors.black.withOpacity(0.2),
    );

    // Token body
    final tokenColor = index < _playerColors.length
        ? _playerColors[index]
        : _playerColors[index % _playerColors.length];
    canvas.drawCircle(
      tokenCenter,
      _kTokenRadius * 20,
      Paint()..color = tokenColor,
    );

    // Player initial
    final initialPainter = TextPainter(
      text: TextSpan(
        text: player.name.isNotEmpty
            ? player.name[0].toUpperCase()
            : '?',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    initialPainter.layout();
    initialPainter.paint(
      canvas,
      Offset(
        tokenCenter.dx - initialPainter.width / 2,
        tokenCenter.dy - initialPainter.height / 2,
      ),
    );
  }

  void _drawCenteredText(
      Canvas canvas, String text, Offset center, double fontSize, Color color) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(center.dx - textPainter.width / 2,
          center.dy - textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant BoardPainter oldDelegate) {
    return oldDelegate.viewModel != viewModel;
  }
}

// ============================================================================
// BoardWidget – the Flutter widget wrapping BoardPainter
// ============================================================================

class BoardWidget extends StatelessWidget {
  final BoardViewModel viewModel;
  final double? width;
  final double? height;

  const BoardWidget({
    super.key,
    required this.viewModel,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: BoardPainter(viewModel),
        child: _buildCenterContent(context),
      ),
    );
  }

  Widget? _buildCenterContent(BuildContext context) {
    // Return a centered game-info overlay if needed.
    return null;
  }
}

// ============================================================================
// BoardView – the stateful page that manages the board and provides the
//             board widget together with a control bar overlay.
// ============================================================================

class BoardView extends StatelessWidget {
  final BoardViewModel viewModel;
  final Widget? controlBar;

  const BoardView({
    super.key,
    required this.viewModel,
    this.controlBar,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boardSize = constraints.maxWidth < constraints.maxHeight
            ? constraints.maxWidth
            : constraints.maxHeight;
        return Column(
          children: [
            Expanded(
              child: Center(
                child: BoardWidget(
                  viewModel: viewModel,
                  width: boardSize,
                  height: boardSize,
                ),
              ),
            ),
            if (controlBar != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                child: controlBar!,
              ),
          ],
        );
      },
    );
  }
}
