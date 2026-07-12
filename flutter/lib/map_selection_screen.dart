import 'package:flutter/material.dart';

import 'game_lobby_screen.dart';
import 'map_models.dart';
import 'map_repository.dart' show DiscoveredMap, MapRepository, MapSource;

// ============================================================================
// Map Selection Screen – 3D card stacking with real map data
// ============================================================================

class MapSelectionScreen extends StatefulWidget {
  const MapSelectionScreen({super.key});

  @override
  State<MapSelectionScreen> createState() => _MapSelectionScreenState();
}

class _MapSelectionScreenState extends State<MapSelectionScreen>
    with TickerProviderStateMixin {
  late final PageController _pageController;
  int _currentPage = 0;

  /// Repository managing built-in + external maps.
  final MapRepository _repository = MapRepository();

  /// Loading state.
  bool _isLoading = true;
  String? _loadError;
  String _mapsDirectoryPath = '';

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.70);
    _pageController.addListener(() {
      setState(() {
        _currentPage = _pageController.page?.round() ?? 0;
      });
    });
    _loadMaps();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Load maps from all sources.
  Future<void> _loadMaps() async {
    try {
      await _repository.initialize(locale: 'zh');
      final dirPath = await _repository.getMapsDirectoryPath();

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _mapsDirectoryPath = dirPath;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
    }
  }

  List<MapMeta> get _maps => _repository.maps;

  /// All entries with source info.
  List<DiscoveredMap> get _entries => _repository.entries;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF1B1B2F),
              Color(0xFF162447),
              Color(0xFF1B1B2F),
            ],
          ),
        ),
        child: SafeArea(
          child: _isLoading
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white54),
                      SizedBox(height: 16),
                      Text('正在加载地图...',
                          style: TextStyle(color: Colors.white54)),
                    ],
                  ),
                )
              : _loadError != null
                  ? _buildErrorView()
                  : _maps.isEmpty
                      ? _buildEmptyView()
                      : _buildContent(),
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
          const SizedBox(height: 12),
          const Text('加载地图失败',
              style: TextStyle(color: Colors.white70, fontSize: 18)),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              _loadError!,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _loadError = null;
                  });
                  _loadMaps();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined, color: Colors.white38, size: 48),
            const SizedBox(height: 12),
            const Text('未找到地图',
                style: TextStyle(color: Colors.white70, fontSize: 18)),
            const SizedBox(height: 8),
            Text(
              '将 .smap 文件放入外部地图目录即可自动加载',
              style: TextStyle(color: Colors.white.withOpacity(0.50)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _mapsDirectoryPath,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withOpacity(0.45),
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _isLoading = true;
                    });
                    _loadMaps();
                  },
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('刷新'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Column(
      children: [
        // ── Header ────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              IconButton(
                icon:
                    const Icon(Icons.arrow_back_rounded, color: Colors.white70),
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
              const SizedBox(width: 48),
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
    final entry = _entries[index];
    final map = entry.meta;
    final source = entry.source;
    final page = _pageController.hasClients ? _pageController.page ?? 0 : 0.0;
    final pageOffset = page - index;
    // Scale: center = 1.0, sides = 0.80
    final scale = 1.0 - (pageOffset.abs() * 0.20).clamp(0.0, 0.20);
    // Opacity: center = 1.0, sides = 0.50
    final opacity = 1.0 - (pageOffset.abs() * 0.50).clamp(0.0, 0.50);
    // Y translation for depth
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
      child: Opacity(
        opacity: opacity,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001) // perspective
            ..rotateY(rotateY)
            ..translate(0.0, translateY)
            ..scale(scale),
          child: _MapCardContent(map: map, isActive: index == _currentPage, source: source),
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
          map.displayName,
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
            '${map.tileCount} 格 | ${map.id} v${map.version}',
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
            map.description.isNotEmpty
                ? map.description
                : '${map.tileCount} 个图块，${map.propertyCount} 个地产',
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
                builder: (_) =>
                    GameLobbyScreen(mapId: map.id, mapMeta: map),
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
  final MapMeta map;
  final bool isActive;
  final MapSource source;

  const _MapCardContent({
    required this.map,
    required this.isActive,
    required this.source,
  });

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
                  // ── Background: thumbnail image or procedural fallback ──
                  if (map.resolvedThumbnailPath != null)
                    // Real thumbnail image
                    Image.asset(
                      map.resolvedThumbnailPath!,
                      width: cardWidth,
                      height: cardHeight,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          _buildProceduralBackground(),
                    )
                  else
                    _buildProceduralBackground(),

                  // ── Scrim overlay for text readability ────────────
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.40),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── Source badge (top-left) ───────────────────────
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: source == MapSource.builtin
                            ? const Color(0xFF43A047).withOpacity(0.85)
                            : const Color(0xFF1E88E5).withOpacity(0.85),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            source == MapSource.builtin
                                ? Icons.inventory_2_rounded
                                : Icons.folder_open_rounded,
                            size: 11,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            source == MapSource.builtin ? '内置' : '外置',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Map name overlay at bottom
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
                              map.displayName,
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

  /// Fallback procedural background when no thumbnail is available.
  Widget _buildProceduralBackground() {
    return Stack(
      children: [
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
        Positioned.fill(
          child: CustomPaint(
            painter: _MapThumbnailPainter(
              themeColor: map.themeColor,
              tileCount: map.tileCount,
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// Map Thumbnail Painter
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

    // Draw tile indicators along the perimeter
    final tilesPerSide = ((tileCount - 4) / 4).ceil();
    final sideLength = boardSize / (tilesPerSide + 1);

    // Bottom row
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

    // Center S logo
    final center = Offset(size.width / 2, size.height / 2);
    final sPaint = Paint()
      ..color = Colors.white.withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    final sSize = boardSize * 0.08;
    canvas.drawArc(
      Rect.fromCenter(center: center, width: sSize, height: sSize),
      -3.14 / 2,
      3.14,
      false,
      sPaint,
    );
    canvas.drawArc(
      Rect.fromCenter(
          center: Offset(center.dx, center.dy + sSize * 0.25),
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
      oldDelegate.themeColor != themeColor ||
      oldDelegate.tileCount != tileCount;
}
