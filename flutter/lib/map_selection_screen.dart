import 'package:flutter/material.dart';

import 'character_selection_screen.dart';

// ============================================================================
// Data model for a map entry
// ============================================================================

class MapEntryData {
  final String id;
  final String name;
  final String description;
  final Color themeColor;
  final int tileCount;

  const MapEntryData({
    required this.id,
    required this.name,
    required this.description,
    required this.themeColor,
    required this.tileCount,
  });
}

/// Built-in map entries.
const List<MapEntryData> kBuiltinMaps = [
  MapEntryData(
    id: 'classic',
    name: '经典大富翁',
    description: '标准 40 格经典大富翁地图，包含完整的物业、机会卡和特殊地块。',
    themeColor: Color(0xFF2E7D32),
    tileCount: 40,
  ),
  MapEntryData(
    id: 'l_shaped',
    name: 'L 形测试板',
    description: '非标准的 L 形自定义布局，用于测试复杂路径和拐角渲染。',
    themeColor: Color(0xFF1565C0),
    tileCount: 16,
  ),
  MapEntryData(
    id: 'mini',
    name: '迷你地图',
    description: '精简版 20 格地图，适合快速对局体验。',
    themeColor: Color(0xFFE65100),
    tileCount: 20,
  ),
];

// ============================================================================
// Map Selection Screen – 3D card stacking with smooth transitions
// ============================================================================

class MapSelectionScreen extends StatefulWidget {
  const MapSelectionScreen({super.key});

  @override
  State<MapSelectionScreen> createState() => _MapSelectionScreenState();
}

class _MapSelectionScreenState extends State<MapSelectionScreen>
    with TickerProviderStateMixin {
  late final PageController _pageController;
  late final AnimationController _bgBlurController;
  int _currentPage = 0;
  double _pageOffset = 0.0;

  final List<MapEntryData> _maps = kBuiltinMaps;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.70);
    _pageController.addListener(() {
      setState(() {
        _pageOffset = _pageController.page ?? 0;
        _currentPage = _pageController.page?.round() ?? 0;
      });
    });
    _bgBlurController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _bgBlurController.forward();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _bgBlurController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF1B1B2F),
              const Color(0xFF162447),
              const Color(0xFF1B1B2F),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // ── Header ────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded,
                          color: Colors.white70),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    const Text(
                      '选择地图',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 48), // balance
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // ── 3D Card Stack ─────────────────────────────────────────
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Background blur layer
                    _buildBlurBackground(),
                    // PageView for card stacking
                    PageView.builder(
                      controller: _pageController,
                      itemCount: _maps.length,
                      onPageChanged: (index) {
                        setState(() => _currentPage = index);
                      },
                      itemBuilder: (context, index) {
                        return _buildMapCard(index);
                      },
                    ),
                    // Left navigation arrow
                    Positioned(
                      left: 4,
                      child: _buildNavArrow(Icons.chevron_left_rounded, -1),
                    ),
                    // Right navigation arrow
                    Positioned(
                      right: 4,
                      child: _buildNavArrow(Icons.chevron_right_rounded, 1),
                    ),
                  ],
                ),
              ),

              // ── Bottom info + action ──────────────────────────────────
              _buildBottomInfo(context),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  /// Build the blurred background layer behind the current card.
  Widget _buildBlurBackground() {
    if (_maps.isEmpty) return const SizedBox.shrink();
    final clamped = _currentPage.clamp(0, _maps.length - 1);
    final current = _maps[clamped];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      margin: const EdgeInsets.symmetric(horizontal: 40),
      decoration: BoxDecoration(
        color: current.themeColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: current.themeColor.withOpacity(0.10),
            blurRadius: 60,
            spreadRadius: 10,
          ),
        ],
      ),
    );
  }

  /// Build a single map card with 3D stacking transform.
  Widget _buildMapCard(int index) {
    final map = _maps[index];
    final pageOffset = _pageOffset - index;
    // Scale: center = 1.0, sides = 0.80
    final scale = 1.0 - (pageOffset.abs() * 0.20).clamp(0.0, 0.20);
    // Opacity: center = 1.0, sides = 0.50
    final opacity = 1.0 - (pageOffset.abs() * 0.50).clamp(0.0, 0.50);
    // Elevation (y translation): center = 0, sides offset downward
    final translateY = 20.0 * pageOffset.abs();
    // Rotation for depth effect
    final rotateY = pageOffset * 0.15;

    return GestureDetector(
      onTap: () {
        if (index != _currentPage) {
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeInOutCubic,
          );
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        child: Opacity(
          opacity: opacity,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.001) // perspective
              ..rotateY(rotateY)
              ..translate(0.0, translateY)
              ..scale(scale),
            child: _MapCardContent(map: map, isActive: index == _currentPage),
          ),
        ),
      ),
    );
  }

  /// Navigation arrow button.
  Widget _buildNavArrow(IconData icon, int direction) {
    final canGo = direction < 0
        ? _currentPage > 0
        : _currentPage < _maps.length - 1;
    return Material(
      color: Colors.white.withOpacity(canGo ? 0.15 : 0.05),
      shape: const CircleBorder(),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: canGo
            ? () {
                _pageController.animateToPage(
                  _currentPage + direction,
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeInOutCubic,
                );
              }
            : null,
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          child: Icon(
            icon,
            color: Colors.white.withOpacity(canGo ? 0.80 : 0.20),
            size: 32,
          ),
        ),
      ),
    );
  }

  /// Bottom info panel with map details and confirm button.
  Widget _buildBottomInfo(BuildContext context) {
    if (_maps.isEmpty) return const SizedBox.shrink();
    final map = _maps[_currentPage.clamp(0, _maps.length - 1)];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Map name
        Text(
          map.name,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 4),
        // Tile count badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.10),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '${map.tileCount} 格 | ${map.id}',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.60),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Description
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            map.description,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withOpacity(0.70),
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 24),
        // Confirm button
        FilledButton.icon(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CharacterSelectionScreen(mapId: map.id),
              ),
            );
          },
          icon: const Icon(Icons.arrow_forward_rounded),
          label: const Text('选择此地图 · 下一步'),
          style: FilledButton.styleFrom(
            backgroundColor: map.themeColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// Map Card Content Widget
// ============================================================================

class _MapCardContent extends StatelessWidget {
  final MapEntryData map;
  final bool isActive;

  const _MapCardContent({required this.map, required this.isActive});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;
        final cardHeight = constraints.maxHeight * 0.70;

        return Center(
          child: Container(
            width: cardWidth,
            height: cardHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: map.themeColor.withOpacity(isActive ? 0.35 : 0.15),
                  blurRadius: isActive ? 24 : 12,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                children: [
                  // ── Background (map thumbnail representation) ─────────
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          map.themeColor.withOpacity(0.60),
                          map.themeColor.withOpacity(0.30),
                          Colors.white.withOpacity(0.10),
                        ],
                      ),
                    ),
                  ),
                  // Decorative grid pattern (simulating board tiles)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _MapThumbnailPainter(
                        themeColor: map.themeColor,
                        tileCount: map.tileCount,
                      ),
                    ),
                  ),
                  // Map name overlay
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.60),
                          ],
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              map.name,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.20),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${map.tileCount} tiles',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ============================================================================
// Map Thumbnail Painter – draws a simplified board representation
// ============================================================================

class _MapThumbnailPainter extends CustomPainter {
  final Color themeColor;
  final int tileCount;

  _MapThumbnailPainter({required this.themeColor, required this.tileCount});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.10)
      ..strokeWidth = 1.0;

    // Draw a simplified square board outline
    final margin = size.width * 0.10;
    final boardSize = size.width - margin * 2;
    final boardRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(margin, margin, boardSize, boardSize),
      const Radius.circular(8),
    );

    // Board border
    final borderPaint = Paint()
      ..color = themeColor.withOpacity(0.40)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRRect(boardRect, borderPaint);

    // Draw some tile indicators along the perimeter
    final tilesPerSide = ((tileCount - 4) / 4).ceil();
    final sideLength = boardSize / (tilesPerSide + 1);

    // Bottom row tiles
    for (var i = 0; i < tilesPerSide + 1; i++) {
      final x = margin + i * sideLength;
      final y = margin + boardSize - sideLength;
      canvas.drawRect(
        Rect.fromLTWH(x, y, sideLength, sideLength),
        paint,
      );
    }

    // Left column
    for (var i = 1; i < tilesPerSide; i++) {
      final x = margin;
      final y = margin + i * sideLength;
      canvas.drawRect(
        Rect.fromLTWH(x, y, sideLength, sideLength),
        paint,
      );
    }

    // Top row
    for (var i = 1; i < tilesPerSide; i++) {
      final x = margin + i * sideLength;
      final y = margin;
      canvas.drawRect(
        Rect.fromLTWH(x, y, sideLength, sideLength),
        paint,
      );
    }

    // Right column
    for (var i = 1; i < tilesPerSide; i++) {
      final x = margin + boardSize - sideLength;
      final y = margin + i * sideLength;
      canvas.drawRect(
        Rect.fromLTWH(x, y, sideLength, sideLength),
        paint,
      );
    }

    // Center "S" logo
    final textPaint = Paint()
      ..color = Colors.white.withOpacity(0.20)
      ..style = PaintingStyle.fill;
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(center, boardSize * 0.12, textPaint);

    // Draw "S" using simple lines
    final sPaint = Paint()
      ..color = Colors.white.withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    final sSize = boardSize * 0.08;
    final sCenter = center;
    // Simplified S shape
    canvas.drawArc(
      Rect.fromCenter(center: sCenter, width: sSize, height: sSize),
      -3.14 / 2,
      3.14,
      false,
      sPaint,
    );
    canvas.drawArc(
      Rect.fromCenter(
          center: Offset(sCenter.dx, sCenter.dy + sSize * 0.25),
          width: sSize,
          height: sSize),
      3.14 / 2,
      3.14,
      false,
      sPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _MapThumbnailPainter oldDelegate) =>
      oldDelegate.themeColor != themeColor || oldDelegate.tileCount != tileCount;
}
