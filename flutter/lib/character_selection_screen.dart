import 'package:flutter/material.dart';

import 'game_rules_screen.dart' show GameRulesScreen, PlayerSlotInfo;
import 'map_models.dart' show MapMeta;

// ============================================================================
// Data model for a player slot
// ============================================================================

class PlayerSlotData {
  final String id;
  String name;
  final Color color;
  PlayerSlotType type;

  PlayerSlotData({
    required this.id,
    required this.name,
    required this.color,
    this.type = PlayerSlotType.human,
  });
}

enum PlayerSlotType { human, bot, empty, waiting }

// ============================================================================
// Character Selection Screen – 4 slots for player setup
// ============================================================================

class CharacterSelectionScreen extends StatefulWidget {
  final String mapId;
  final MapMeta? mapMeta;

  const CharacterSelectionScreen({
    super.key,
    required this.mapId,
    this.mapMeta,
  });

  @override
  State<CharacterSelectionScreen> createState() =>
      _CharacterSelectionScreenState();
}

class _CharacterSelectionScreenState extends State<CharacterSelectionScreen> {
  static const List<Color> _slotColors = [
    Color(0xFFD32F2F),
    Color(0xFF1976D2),
    Color(0xFF388E3C),
    Color(0xFFFBC02D),
  ];

  late List<PlayerSlotData> _slots;

  @override
  void initState() {
    super.initState();
    _slots = [
      PlayerSlotData(
        id: 'player_0',
        name: '玩家 1',
        color: _slotColors[0],
        type: PlayerSlotType.human,
      ),
      PlayerSlotData(
        id: 'player_1',
        name: '空闲',
        color: _slotColors[1],
        type: PlayerSlotType.empty,
      ),
      PlayerSlotData(
        id: 'player_2',
        name: '空闲',
        color: _slotColors[2],
        type: PlayerSlotType.empty,
      ),
      PlayerSlotData(
        id: 'player_3',
        name: '空闲',
        color: _slotColors[3],
        type: PlayerSlotType.empty,
      ),
    ];
  }

  /// Count non-empty slots.
  int get _activePlayerCount =>
      _slots.where((s) => s.type != PlayerSlotType.empty).length;

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
              Color(0xFF1A1A2E),
              Color(0xFF16213E),
              Color(0xFF0F3460),
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
                      '选择角色',
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
              const SizedBox(height: 8),

              // ── Map indicator ─────────────────────────────────────────
              Text(
                '地图: ${widget.mapId}',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withOpacity(0.50),
                ),
              ),
              const SizedBox(height: 24),

              // ── Player slots ──────────────────────────────────────────
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: ListView.separated(
                    itemCount: _slots.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 16),
                    itemBuilder: (context, index) {
                      return _buildPlayerSlot(index);
                    },
                  ),
                ),
              ),

              // ── Bottom actions ────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _activePlayerCount < 4
                            ? _addBotPlayer
                            : null,
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: const Text('添加电脑玩家'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: BorderSide(
                            color: Colors.white.withOpacity(0.20),
                          ),
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _activePlayerCount >= 2
                            ? _onNext
                            : null,
                        icon:
                            const Icon(Icons.arrow_forward_rounded),
                        label: const Text('下一步 · 规则设置'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF43A047),
                          foregroundColor: Colors.white,
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build a single player slot card.
  Widget _buildPlayerSlot(int index) {
    final slot = _slots[index];
    final isHuman = slot.type == PlayerSlotType.human;
    final isEmpty = slot.type == PlayerSlotType.empty;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isHuman
              ? slot.color.withOpacity(0.60)
              : Colors.white.withOpacity(0.10),
          width: isHuman ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Avatar circle
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: isEmpty
                    ? Colors.white.withOpacity(0.10)
                    : slot.color.withOpacity(0.80),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withOpacity(0.30),
                  width: 2,
                ),
              ),
              child: Center(
                child: isEmpty
                    ? Icon(Icons.person_add_alt_1_rounded,
                        color: Colors.white.withOpacity(0.40), size: 24)
                    : Text(
                        slot.name.isNotEmpty ? slot.name[0] : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 16),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name
                  Text(
                    isEmpty ? '空位 (点击添加)' : slot.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: isEmpty
                          ? Colors.white.withOpacity(0.40)
                          : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Type badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color:
                          _slotTypeColor(slot.type).withOpacity(0.20),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _slotTypeLabel(slot.type),
                      style: TextStyle(
                        fontSize: 11,
                        color: _slotTypeColor(slot.type),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Slot number badge
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: slot.color.withOpacity(0.20),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: slot.color.withOpacity(0.80),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Add a bot player to the first empty slot.
  void _addBotPlayer() {
    setState(() {
      final emptyIdx =
          _slots.indexWhere((s) => s.type == PlayerSlotType.empty);
      if (emptyIdx >= 0) {
        final botIndex =
            _slots.where((s) => s.type == PlayerSlotType.bot).length +
                1;
        _slots[emptyIdx] = PlayerSlotData(
          id: 'player_$emptyIdx',
          name: '电脑玩家 $botIndex',
          color: _slotColors[emptyIdx],
          type: PlayerSlotType.bot,
        );
      }
    });
  }

  /// Navigate to game rules screen.
  void _onNext() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GameRulesScreen(
          mapId: widget.mapId,
          players: _slots
              .where((s) => s.type != PlayerSlotType.empty)
              .map((s) => PlayerSlotInfo(
                    id: s.id,
                    name: s.name,
                    isBot: s.type == PlayerSlotType.bot,
                  ))
              .toList(),
        ),
      ),
    );
  }

  Color _slotTypeColor(PlayerSlotType type) {
    switch (type) {
      case PlayerSlotType.human:
        return const Color(0xFF43A047);
      case PlayerSlotType.bot:
        return const Color(0xFF1E88E5);
      case PlayerSlotType.waiting:
        return const Color(0xFFFDD835);
      case PlayerSlotType.empty:
        return Colors.grey;
    }
  }

  String _slotTypeLabel(PlayerSlotType type) {
    switch (type) {
      case PlayerSlotType.human:
        return '本地玩家';
      case PlayerSlotType.bot:
        return '电脑玩家 (AI)';
      case PlayerSlotType.waiting:
        return '等待加入...';
      case PlayerSlotType.empty:
        return '空位';
    }
  }
}
