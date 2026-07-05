import 'package:flutter/material.dart';

import 'map_selection_screen.dart';

// ============================================================================
// Home Screen – Main menu with four action buttons
// ============================================================================

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Derive a unique gradient from the app's seed colour
    final seed = Theme.of(context).colorScheme.primary;
    final topColor = seed.withOpacity(0.85);
    final bottomColor = seed.withOpacity(0.50);

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [topColor, bottomColor],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              // ── App logo / title ─────────────────────────────────────
              _buildTitle(context),
              const Spacer(flex: 1),
              // ── Menu buttons ─────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Column(
                  children: [
                    _MenuButton(
                      icon: Icons.play_arrow_rounded,
                      label: '进入游戏',
                      subtitle: '选择地图并开始一局新游戏',
                      color: const Color(0xFF43A047),
                      onTap: () => _onEnterGame(context),
                    ),
                    const SizedBox(height: 16),
                    _MenuButton(
                      icon: Icons.map_rounded,
                      label: '地图功能',
                      subtitle: '浏览和管理游戏地图',
                      color: const Color(0xFF1E88E5),
                      onTap: () => _onMapFeature(context),
                    ),
                    const SizedBox(height: 16),
                    _MenuButton(
                      icon: Icons.extension_rounded,
                      label: '模组功能',
                      subtitle: '管理内容和模组扩展',
                      color: const Color(0xFF8E24AA),
                      onTap: () => _onModFeature(context),
                    ),
                    const SizedBox(height: 16),
                    _MenuButton(
                      icon: Icons.settings_rounded,
                      label: '设置',
                      subtitle: '游戏、画面与网络配置',
                      color: const Color(0xFF546E7A),
                      onTap: () => _onSettings(context),
                    ),
                  ],
                ),
              ),
              const Spacer(flex: 3),
              // ── Version footer ───────────────────────────────────────
              Text(
                'saMonopoly v0.1.0',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white60,
                      fontSize: 12,
                    ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Board game icon
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.20),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.dashboard_rounded,
              size: 44, color: Colors.white),
        ),
        const SizedBox(height: 16),
        const Text(
          'saMonopoly',
          style: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '大富翁 · 跨平台版',
          style: TextStyle(
            fontSize: 14,
            color: Colors.white.withOpacity(0.80),
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }

  void _onEnterGame(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const MapSelectionScreen(),
      ),
    );
  }

  void _onMapFeature(BuildContext context) {
    _showComingSoon(context, '地图功能');
  }

  void _onModFeature(BuildContext context) {
    _showComingSoon(context, '模组功能');
  }

  void _onSettings(BuildContext context) {
    _showComingSoon(context, '设置');
  }

  void _showComingSoon(BuildContext context, String feature) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(feature),
        content: const Text('此功能正在开发中，敬请期待！'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Menu button widget
// ============================================================================

class _MenuButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _MenuButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              children: [
                // Icon circle
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.30),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: Colors.white, size: 26),
                ),
                const SizedBox(width: 16),
                // Text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.65),
                        ),
                      ),
                    ],
                  ),
                ),
                // Arrow
                Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white.withOpacity(0.50),
                  size: 28,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
