import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'board_view.dart';
import 'bridge_client.dart';
import 'card_inventory_dialog.dart';
import 'card_shop_dialog.dart';
import 'config_provider.dart';
import 'content_pack.dart';
import 'content_pack_loader.dart';
import 'isometric_board.dart';
import 'lottery_dialog.dart';

// ============================================================================
// Game state management (simple InheritedWidget)
// ============================================================================

/// Top-level game state exposed through the widget tree.
class GameStateData {
  final List<PlayerTokenViewModel> players;
  final Map<String, dynamic> rawState;
  final String lastEvent;
  final List<String> eventLog;
  final Map<String, int> diceResult;

  const GameStateData({
    this.players = const [],
    this.rawState = const {},
    this.lastEvent = '',
    this.eventLog = const [],
    this.diceResult = const {},
  });

  GameStateData copyWith({
    List<PlayerTokenViewModel>? players,
    Map<String, dynamic>? rawState,
    String? lastEvent,
    List<String>? eventLog,
    Map<String, int>? diceResult,
  }) {
    return GameStateData(
      players: players ?? this.players,
      rawState: rawState ?? this.rawState,
      lastEvent: lastEvent ?? this.lastEvent,
      eventLog: eventLog ?? this.eventLog,
      diceResult: diceResult ?? this.diceResult,
    );
  }

  int get activePlayerIndex =>
      (rawState['active_player_index'] as num?)?.toInt() ?? 0;

  int get currentTurn => (rawState['current_turn'] as num?)?.toInt() ?? 0;

  int get numPlayers => players.length;
}

class GameStateWidget extends InheritedWidget {
  final GameStateData data;
  final void Function(GameStateData) onUpdate;

  const GameStateWidget({
    super.key,
    required this.data,
    required this.onUpdate,
    required super.child,
  });

  static GameStateWidget of(BuildContext context) {
    final result = context.dependOnInheritedWidgetOfExactType<GameStateWidget>();
    assert(result != null, 'No GameStateWidget found in context');
    return result!;
  }

  @override
  bool updateShouldNotify(covariant GameStateWidget oldWidget) {
    return oldWidget.data != data;
  }
}

// ============================================================================
// App entry point
// ============================================================================

void main() {
  runApp(const SaMonopolyApp());
}

class SaMonopolyApp extends StatelessWidget {
  const SaMonopolyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'saMonopoly',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const GameScreen(),
    );
  }
}

// ============================================================================
// Game screen – orchestrates the board, player panel, and action buttons
// ============================================================================

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final BridgeClient _bridgeClient = const BridgeClient();
  final ContentPackLoader _loader = const ContentPackLoader();
  final ScrollController _logScrollController = ScrollController();

  // ---- Game state ----------------------------------------------------------
  GameStateData _gameState = const GameStateData();
  late ContentPackViewModel _pack;
  late Map<String, dynamic> _currentState;

  // ---- Animation state -----------------------------------------------------
  bool _isAnimating = false;
  /// Overridden player tile IDs during hopping animation.
  final Map<int, String> _animatedPositions = {};

  // ---- Dice animation state ------------------------------------------------
  bool _isRollingDice = false;
  int _animDice1 = 1;
  int _animDice2 = 1;

  // ---- Config provider -----------------------------------------------------
  final ConfigProvider _configProvider = ConfigProvider();

  // ---- Turn state ----------------------------------------------------------
  /// Number of rolls remaining for the current active player this turn.
  /// Default: 1. Re-rolls when die=6 add another roll.
  int _rollsRemainingThisTurn = 1;

  /// The tile the active player just landed on this turn after rolling.
  /// `null` if they haven't rolled yet this turn or the turn has ended.
  /// Used to prevent Buy/Upgrade without having just arrived at the tile.
  String? _landedTileIdThisTurn;

  // Player colours
  static const List<Color> _playerColors = [
    Color(0xFFD32F2F),
    Color(0xFF1976D2),
    Color(0xFF388E3C),
    Color(0xFFFBC02D),
    Color(0xFF8E24AA),
    Color(0xFFFF6F00),
  ];

  /// Set to `true` to use the complex L-shaped test board instead of the
  /// classic rectangular 40-tile layout.
  bool _useComplexBoard = true;

  // ── Complex L‑shaped test board ─────────────────────────────────────────
  //
  // Grid layout (row, col):
  //
  //         C0  C1  C2  C3  C4
  //   R0:  [11] [–] [9] [–] [–]
  //   R1:  [12] [–] [8] [7] [–]
  //   R2:  [13] [–] [–] [–] [–]
  //   R3:  [14] [–] [–] [–] [–]
  //   R4:  [15] [0] [1] [2] [3]
  //
  // Path: 15→0→1→2→3→4→5→6→7→8→9→10→11→12→13→14→(back to 15)
  //
  // Corners:
  //   tile  4 (4,4) right→up      → _|   type  (\ → /)
  //   tile  7 (1,4) up→left        → -|   type  (/ → \)
  //   tile  9 (1,2) left→up        → |-   type  (\ → /)
  //   tile 12 (0,0) left→down      → |-   type  (\ → /)
  //   tile 15 (3,0) down→right     → |_   type  (/ → \)

  /// Perimeter grid positions for the complex L‑shaped board (row, col).
  final List<(int, int)> _complexPositions = const [
    (4, 0), // tile 0  — Start
    (4, 1), // tile 1
    (4, 2), // tile 2
    (4, 3), // tile 3
    (4, 4), // tile 4  — corner right→up
    (3, 4), // tile 5
    (2, 4), // tile 6
    (1, 4), // tile 7  — corner up→left
    (1, 3), // tile 8
    (1, 2), // tile 9  — corner left→up
    (0, 2), // tile 10
    (0, 1), // tile 11
    (0, 0), // tile 12 — corner left→down
    (1, 0), // tile 13
    (2, 0), // tile 14
    (3, 0), // tile 15 — corner down→right
  ];

  final List<Map<String, String>> _complexTiles = const [
    {'id': 'start',     'name': 'Start',        'kind': 'Start'},
    {'id': 'prop_1',    'name': 'Med Ave',      'kind': 'OrdinaryProperty'},
    {'id': 'chance_1',  'name': 'Chance',       'kind': 'Chance'},
    {'id': 'prop_2',    'name': 'Baltic Ave',   'kind': 'OrdinaryProperty'},
    {'id': 'tax_1',     'name': 'Income Tax',   'kind': 'Bank'},
    {'id': 'prop_3',    'name': 'Oriental Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'rr_1',      'name': 'Reading RR',   'kind': 'OrdinaryProperty'},
    {'id': 'corner_1',  'name': '↱ Up Turn',    'kind': 'Jail'},
    {'id': 'chance_2',  'name': 'Community',    'kind': 'Chance'},
    {'id': 'corner_2',  'name': '↰ Left Turn',  'kind': 'CardShop'},
    {'id': 'prop_4',    'name': 'Vermont Ave',  'kind': 'OrdinaryProperty'},
    {'id': 'prop_5',    'name': 'Conn Ave',     'kind': 'OrdinaryProperty'},
    {'id': 'corner_3',  'name': '↖ Top',        'kind': 'Start'},
    {'id': 'util_1',    'name': 'Electric Co',  'kind': 'ExtensionProperty'},
    {'id': 'prop_6',    'name': 'St Charles',   'kind': 'OrdinaryProperty'},
    {'id': 'corner_4',  'name': '↙ Down Turn',  'kind': 'Bank'},
  ];

  // Default tile set for the built-in board
  final List<Map<String, String>> _defaultTiles = const [
    {'id': 'start', 'name': 'Start', 'kind': 'Start'},
    {'id': 'prop_1', 'name': 'Mediterranean Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'chance_1', 'name': 'Chance', 'kind': 'Chance'},
    {'id': 'prop_2', 'name': 'Baltic Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'tax_1', 'name': 'Income Tax', 'kind': 'Bank'},
    {'id': 'rr_1', 'name': 'Reading RR', 'kind': 'OrdinaryProperty'},
    {'id': 'prop_3', 'name': 'Oriental Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'chance_2', 'name': 'Community Chest', 'kind': 'Chance'},
    {'id': 'prop_4', 'name': 'Vermont Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'prop_5', 'name': 'Connecticut Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'jail', 'name': 'Jail', 'kind': 'Jail'},
    {'id': 'prop_6', 'name': 'St. Charles Pl', 'kind': 'OrdinaryProperty'},
    {'id': 'util_1', 'name': 'Electric Co', 'kind': 'ExtensionProperty'},
    {'id': 'prop_7', 'name': 'States Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'prop_8', 'name': 'Virginia Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'rr_2', 'name': 'Penn RR', 'kind': 'OrdinaryProperty'},
    {'id': 'prop_9', 'name': 'St. James Pl', 'kind': 'OrdinaryProperty'},
    {'id': 'chance_3', 'name': 'Chance', 'kind': 'Chance'},
    {'id': 'prop_10', 'name': 'Tennessee Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'prop_11', 'name': 'New York Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'park', 'name': 'Free Parking', 'kind': 'Bank'},
    {'id': 'prop_12', 'name': 'Kentucky Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'chance_4', 'name': 'Chance', 'kind': 'Chance'},
    {'id': 'prop_13', 'name': 'Indiana Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'prop_14', 'name': 'Illinois Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'rr_3', 'name': 'B&O RR', 'kind': 'OrdinaryProperty'},
    {'id': 'prop_15', 'name': 'Atlantic Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'prop_16', 'name': 'Ventnor Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'util_2', 'name': 'Water Works', 'kind': 'ExtensionProperty'},
    {'id': 'prop_17', 'name': 'Marvin Gardens', 'kind': 'OrdinaryProperty'},
    {'id': 'go_to_jail', 'name': 'Go To Jail', 'kind': 'Jail'},
    {'id': 'prop_18', 'name': 'Pacific Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'prop_19', 'name': 'N. Carolina Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'chance_5', 'name': 'Community Chest', 'kind': 'Chance'},
    {'id': 'prop_20', 'name': 'Pennsylvania Ave', 'kind': 'OrdinaryProperty'},
    {'id': 'rr_4', 'name': 'Short Line', 'kind': 'OrdinaryProperty'},
    {'id': 'chance_6', 'name': 'Chance', 'kind': 'Chance'},
    {'id': 'prop_21', 'name': 'Park Place', 'kind': 'OrdinaryProperty'},
    {'id': 'tax_2', 'name': 'Luxury Tax', 'kind': 'Bank'},
    {'id': 'prop_22', 'name': 'Boardwalk', 'kind': 'OrdinaryProperty'},
  ];

  @override
  void initState() {
    super.initState();
    _pack = sampleClassicPack();
    _currentState = _buildInitialState(2);
    _gameState = _buildGameState(_currentState);
    _landedTileIdThisTurn = null;
    final mapLabel = _useComplexBoard ? 'Complex L‑board' : 'Classic';
    _addLog('Game started ($mapLabel) with ${_gameState.numPlayers} players');
  }

  @override
  void dispose() {
    _logScrollController.dispose();
    super.dispose();
  }

  // ---- State builders ------------------------------------------------------

  /// Build the initial GameState JSON map for [numPlayers] players.
  Map<String, dynamic> _buildInitialState(int numPlayers) {
    // Pick tile source: complex or classic
    final tileSource = _useComplexBoard ? _complexTiles : _defaultTiles;
    final tiles = tileSource
        .map((t) => {
              'id': t['id'],
              'name': t['name'],
              'name_key': 'tile.${t['id']}',
              'kind': t['kind'],
              'linked_property_kind': null,
            })
        .toList();

    final players = List<Map<String, dynamic>>.generate(
      numPlayers,
      (i) => {
        'id': 'player_$i',
        'name': 'Player ${i + 1}',
        'cash': 1500,
        'position': 'start',
        'is_ai': i > 0, // Player 1 is human by default
        'is_llm_controlled': false,
        'jail_turns': 0,
        'hospital_turns': 0,
        'owned_cards': <String>[],
        'stock_shares': 0,
      },
    );

    // Build properties from tiles that are OrdinaryProperty
    final properties = <Map<String, dynamic>>[];
    for (final tile in tileSource) {
      if (tile['kind'] == 'OrdinaryProperty') {
        properties.add({
          'tile_id': tile['id'],
          'name_key': 'prop.${tile['id']}',
          'kind': 'Ordinary',
          'base_price': 100 + math.Random().nextInt(300),
          'rent': [10, 20, 30, 40],
          'upgrade_level': 0,
          'owner': null,
          'is_mortgaged': false,
          'linked_targets': <String>[],
        });
      } else if (tile['kind'] == 'ExtensionProperty') {
        properties.add({
          'tile_id': tile['id'],
          'name_key': 'prop.${tile['id']}',
          'kind': 'Extension',
          'base_price': 150,
          'rent': [15, 30, 45],
          'upgrade_level': 0,
          'owner': null,
          'is_mortgaged': false,
          'linked_targets': <String>[],
        });
      }
    }

    // ── Auto-link rent for the complex L‑shaped board ────────────
    // Duplicates the Rust compute_auto_links() logic so the Flutter
    // simulator can exercise group-rent behaviour.
    if (_useComplexBoard) {
      _computeAutoLinks(tileSource, properties);
    }

    return {
      'board': {
        'tiles': tiles,
        'properties': properties,
        'graph': {'edges': [], 'teleporters': []},
      },
      'players': players,
      'ruleset': {'id': 'classic', 'version': '0.1.0'},
      'current_turn': 0,
      'active_player_index': 0,
      'seed': DateTime.now().microsecondsSinceEpoch,
      'decks': [],
      'stock_market': null,
      'active_auction': null,
      'consecutive_doubles': 0,
      'group_rent_enabled': _useComplexBoard, // enable group rent for test
    };
  }

  /// Auto-link rent computation for the Flutter simulator.
  ///
  /// Mirrors the Rust `Board::compute_auto_links` logic.
  /// Walks the tile source in path order, finds contiguous property runs,
  /// applies the gap-merging rule (gap=1, total≥3), and sets linked_targets.
  void _computeAutoLinks(
      List<Map<String, String>> tileSource,
      List<Map<String, dynamic>> properties) {
    // Helper: check if a tile is a property (has a matching property entry)
    bool isProp(int ti) =>
        ti < tileSource.length &&
        properties.any((p) => p['tile_id'] == tileSource[ti]['id']);

    // Collect tile IDs that already have manual linked_targets
    final manual = properties
        .where((p) => (p['linked_targets'] as List).isNotEmpty)
        .map((p) => p['tile_id'] as String)
        .toSet();

    // ── 1. Find contiguous property runs ────────────────────────
    final runs = <List<String>>[];
    int i = 0;
    while (i < tileSource.length) {
      final tid = tileSource[i]['id']!;
      if (!isProp(i) || manual.contains(tid)) {
        i++;
        continue;
      }
      final run = <String>[tid];
      i++;
      while (i < tileSource.length) {
        final next = tileSource[i]['id']!;
        if (!isProp(i) || manual.contains(next)) break;
        run.add(next);
        i++;
      }
      if (run.isNotEmpty) runs.add(run);
    }
    if (runs.isEmpty) return;

    // ── 2. Merge runs separated by single-tile gaps (rule 4) ────
    final merged = <List<String>>[];
    int ri = 0;
    while (ri < runs.length) {
      final cluster = <String>[...runs[ri]];
      ri++;
      while (ri < runs.length) {
        // Count gap between last tile of cluster and first of next run
        final lastId = cluster.last;
        final nextId = runs[ri].first;
        int gap = 0;
        bool counting = false;
        for (final t in tileSource) {
          if (t['id'] == lastId) {
            counting = true;
            continue;
          }
          if (t['id'] == nextId) break;
          if (counting) gap++;
        }
        final total = cluster.length + runs[ri].length;
        if (gap != 1 || total < 3) break;
        cluster.addAll(runs[ri]);
        ri++;
      }
      merged.add(cluster);
    }

    // ── 3. Set linked_targets (max 5 per group) ─────────────────
    for (final group in merged) {
      final g = group.length > 5 ? group.sublist(0, 5) : group;
      if (g.length < 2) continue;
      for (final tid in g) {
        final prop = properties.firstWhere(
          (p) => p['tile_id'] == tid,
          orElse: () => <String, dynamic>{},
        );
        if (prop.isNotEmpty) {
          prop['linked_targets'] =
              g.where((id) => id != tid).toList();
        }
      }
    }
  }

  /// Build a [GameStateData] from a raw state JSON map.
  /// Optionally override player tile positions (used during animation).
  GameStateData _buildGameState(Map<String, dynamic> rawState,
      {String lastEvent = '', Map<String, int> diceResult = const {},
      Map<int, String>? positionOverrides}) {
    final playersList = BridgeClient.parsePlayers(rawState);
    final tokens = playersList
        .map((p) {
          final idx = _playerIndex(p.id);
          final tileId = positionOverrides?.containsKey(idx) == true
              ? positionOverrides![idx]!
              : p.position;
          return PlayerTokenViewModel(
            id: p.id,
            name: p.name,
            tileId: tileId,
            color: _playerColors[idx % _playerColors.length],
            cash: p.cash,
          );
        })
        .toList();

    return GameStateData(
      players: tokens,
      rawState: rawState,
      lastEvent: lastEvent,
      eventLog: _gameState?.eventLog ?? [],
      diceResult: diceResult,
    );
  }

  int _playerIndex(String playerId) {
    return int.tryParse(playerId.replaceAll('player_', '')) ?? 0;
  }

  Color _playerColorForOwner(String playerId) {
    final playerColors = [
      const Color(0xFFD32F2F),
      const Color(0xFF1976D2),
      const Color(0xFF388E3C),
      const Color(0xFFFBC02D),
      const Color(0xFF8E24AA),
      const Color(0xFFFF6F00),
    ];
    return playerColors[_playerIndex(playerId) % playerColors.length];
  }

  void _addLog(String message) {
    final updatedLog = List<String>.from(_gameState.eventLog)
      ..insert(0, message);
    setState(() {
      _gameState = _gameState.copyWith(eventLog: updatedLog);
    });
  }

  // ---- Game actions --------------------------------------------------------

  Future<void> _onRoll() async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.roll(),
      currentState: _currentState,
    );
    final dice1 = (response.event['dice1'] as num?)?.toInt() ?? 0;
    final dice2 = (response.event['dice2'] as num?)?.toInt() ?? 0;
    final steps = dice1 + dice2;

    // ---- Dice rolling animation ------------------------------------------
    _isRollingDice = true;
    for (var i = 0; i < 8; i++) {
      await Future.delayed(const Duration(milliseconds: 60));
      if (!mounted) return;
      setState(() {
        _animDice1 = 1 + (i * 3 + 1) % 6;
        _animDice2 = 1 + (i * 7 + 3) % 6;
      });
    }
    // Show final dice values
    setState(() {
      _animDice1 = dice1;
      _animDice2 = dice2;
      _isRollingDice = false;
    });

    // Compute the animation path (intermediate tile IDs)
    final rawTiles = (_currentState['board'] as Map<String, dynamic>?)?
        ['tiles'] as List<dynamic>? ?? [];
    final activeIdx = _gameState.activePlayerIndex;
    final currentPos = _gameState.players[activeIdx].tileId;
    final currentTileIdx = rawTiles.indexWhere((t) => t['id'] == currentPos);

    final path = <String>[];
    if (rawTiles.isNotEmpty) {
      for (var i = 1; i <= steps; i++) {
        final idx = (currentTileIdx + i) % rawTiles.length;
        path.add(rawTiles[idx]['id'] as String);
      }
    }

    // Animate: hop through each intermediate tile
    if (path.isNotEmpty) {
      _isAnimating = true;
      for (var i = 0; i < path.length; i++) {
        await Future.delayed(const Duration(milliseconds: 150));
        if (!mounted) return;
        setState(() {
          _animatedPositions[activeIdx] = path[i];
          _gameState = _buildGameState(
            _currentState,
            lastEvent: 'Rolled $dice1 + $dice2',
            diceResult: {'dice1': dice1, 'dice2': dice2},
            positionOverrides: Map.of(_animatedPositions),
          );
        });
      }
      _isAnimating = false;
      _animatedPositions.clear();
    }

    // Apply final state from the engine
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: 'Rolled $dice1 + $dice2',
        diceResult: {'dice1': dice1, 'dice2': dice2},
      );
    });
    _addLog('Rolled $dice1 + $dice2 = ${dice1 + dice2}');

    // Resolve special tile effects
    final playerPos =
        _currentState['players'][_gameState.activePlayerIndex]['position'];
    await _resolveTileEffect(playerPos);

    // Record which tile the player just landed on (buy/upgrade only allowed
    // on the turn they first arrive).
    _landedTileIdThisTurn = playerPos;

    // Decrement rolls remaining; if single die shows 6, grant re-roll
    _rollsRemainingThisTurn--;
    // Single die mode: die face = dice1 (simulated as dice1%6+1)
    final dieFace = dice1; // already the displayed face value
    if (dieFace == 6) {
      _rollsRemainingThisTurn++;
      _addLog('Rolled a 6! Extra roll granted.');
    }
    setState(() {}); // refresh button state

    // Check if player landed on a purchasable or own upgradable property
    final property = _findPropertyAtTile(playerPos);
    if (property != null) {
      final owner = property['owner'] as String?;
      final playerId = _gameState.players[_gameState.activePlayerIndex].id;
      if (owner == null) {
        _showBuyPropertyDialog(playerPos, property);
      } else if (owner == playerId) {
        final maxLevel = (_currentState['max_upgrade_level'] as num?)?.toInt() ?? 3;
        final currentLevel = (property['upgrade_level'] as num?)?.toInt() ?? 0;
        if (maxLevel > 0 && currentLevel < maxLevel) {
          _showUpgradePropertyDialog(playerPos, property);
        }
      }
    }
  }

  /// Resolve the effect of the tile the active player landed on.
  /// Mirrors [crate::effects::EffectResolver::resolve_special_tile].
  Future<void> _resolveTileEffect(String tileId) async {
    final rawTiles = (_currentState['board'] as Map<String, dynamic>?)?
        ['tiles'] as List<dynamic>? ?? [];
    final tileData = rawTiles.cast<Map<String, dynamic>>().firstWhere(
      (t) => t['id'] == tileId,
      orElse: () => <String, dynamic>{},
    );
    if (tileData.isEmpty) return;

    final kind = tileData['kind'] as String? ?? '';
    final name = tileData['name'] as String? ?? tileId;

    switch (kind) {
      case 'Start':
        _addLog('Landed on Start');
        break;

      case 'Chance':
        await _showChanceCardDialog();
        break;

      case 'Bank':
        // Income Tax / Luxury Tax / Free Parking
        if (tileId == 'tax_1') {
          // Income Tax: pay $200
          _deductCash(_gameState.activePlayerIndex, 200);
          _addLog('Paid Income Tax: -\$200');
        } else if (tileId == 'tax_2') {
          // Luxury Tax: pay $100
          _deductCash(_gameState.activePlayerIndex, 100);
          _addLog('Paid Luxury Tax: -\$100');
        } else {
          // Free Parking: bonus $200
          _addCash(_gameState.activePlayerIndex, 200);
          _addLog('Free Parking bonus: +\$200');
        }
        break;

      case 'Jail':
        if (tileId == 'go_to_jail') {
          // Send to jail
          _sendToJail(_gameState.activePlayerIndex);
          _addLog('Go to Jail!');
        } else {
          // Just visiting
          _addLog('Just visiting Jail');
        }
        break;

      case 'CardShop':
        await _showCardShopDialog();
        break;

      case 'Lottery':
        await _showLotteryPickerDialog();
        break;

      default:
        break;
    }
  }

  Future<void> _onBuyCard(String cardId, int price) async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.buyCard(cardId, price),
      currentState: _currentState,
    );
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(response.state, lastEvent: 'Bought $cardId');
    });
    _addLog('Bought card: $cardId');
  }

  Future<void> _onUseCard(String cardId) async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand(type: 'UseCard', params: {'card_id': cardId}),
      currentState: _currentState,
    );
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(response.state, lastEvent: 'Used $cardId');
    });
    _addLog('Used card: $cardId');
  }

  Future<void> _onBuyLotteryTicket(int number) async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand(
          type: 'BuyLotteryTicket', params: {'number': number}),
      currentState: _currentState,
    );
    setState(() {
      _currentState = response.state;
      _gameState =
          _buildGameState(response.state, lastEvent: 'Lottery #$number');
    });
    _addLog('Bought lottery ticket #$number');
  }

  Future<void> _showCardShopDialog() async {
    final player = _gameState.players[_gameState.activePlayerIndex];
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => CardShopDialog(
        playerCash: player.cash,
        onBuy: (cardId, price) => _onBuyCard(cardId, price),
      ),
    );
  }

  void _showCardInventoryDialog() {
    final player = _gameState.players[_gameState.activePlayerIndex];
    final ownedCards = BridgeClient.parsePlayers(_currentState)
        .firstWhere((p) => p.id == player.id)
        .ownedCards;
    showDialog(
      context: context,
      builder: (ctx) => CardInventoryDialog(
        ownedCardIds: ownedCards,
        onUse: (cardId) => _onUseCard(cardId),
      ),
    );
  }

  Future<void> _showLotteryPickerDialog() async {
    // In simulation mode, show a simple UI with default values
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => LotteryPickerDialog(
        jackpot: 500,
        ticketPrice: 50,
        nextDrawTurn: 15,
        alreadyPicked: false,
        onPick: (number) => _onBuyLotteryTicket(number),
      ),
    );
  }

  void _deductCash(int playerIdx, int amount) {
    setState(() {
      final players = List<Map<String, dynamic>>.from(
          _currentState['players'] as List<dynamic>? ?? []);
      if (playerIdx < players.length) {
        final player = Map<String, dynamic>.from(players[playerIdx]);
        player['cash'] = ((player['cash'] as num?)?.toInt() ?? 0) - amount;
        players[playerIdx] = player;
        _currentState['players'] = players;
        _gameState = _buildGameState(_currentState, lastEvent: '-\$$amount');
      }
    });
  }

  void _addCash(int playerIdx, int amount) {
    setState(() {
      final players = List<Map<String, dynamic>>.from(
          _currentState['players'] as List<dynamic>? ?? []);
      if (playerIdx < players.length) {
        final player = Map<String, dynamic>.from(players[playerIdx]);
        player['cash'] = ((player['cash'] as num?)?.toInt() ?? 0) + amount;
        players[playerIdx] = player;
        _currentState['players'] = players;
        _gameState = _buildGameState(_currentState, lastEvent: '+\$$amount');
      }
    });
  }

  void _sendToJail(int playerIdx) {
    setState(() {
      final players = List<Map<String, dynamic>>.from(
          _currentState['players'] as List<dynamic>? ?? []);
      if (playerIdx < players.length) {
        final player = Map<String, dynamic>.from(players[playerIdx]);
        player['position'] = 'jail';
        player['jail_turns'] = 3;
        players[playerIdx] = player;
        _currentState['players'] = players;
        _gameState = _buildGameState(_currentState, lastEvent: 'Sent to jail');
      }
    });
  }

  Future<void> _showChanceCardDialog() async {
    final messages = [
      'Advance to Go. Collect \$200',
      'Bank error in your favor. Collect \$200',
      'Doctor\'s fee. Pay \$50',
      'Go to Jail. Go directly to Jail',
      'Holiday fund matures. Collect \$100',
      'Income tax refund. Collect \$20',
      'Pay hospital fees of \$100',
      'Receive \$25 consultancy fee',
      'You are assessed for street repairs: \$40 per house',
      'You have won a crossword competition. Collect \$100',
    ];
    final msg = messages[DateTime.now().millisecondsSinceEpoch % messages.length];
    final isGood = msg.startsWith('Advance') ||
        msg.startsWith('Bank') ||
        msg.startsWith('Holiday') ||
        msg.startsWith('Income') ||
        msg.startsWith('Receive') ||
        msg.startsWith('You have won');

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Chance Card'),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (!isGood) {
      // Pay the fee if applicable
      if (msg.contains('\$50')) {
        _deductCash(_gameState.activePlayerIndex, 50);
      } else if (msg.contains('\$100') && !msg.contains('collect')) {
        _deductCash(_gameState.activePlayerIndex, 100);
      } else if (msg.contains('\$40')) {
        _deductCash(_gameState.activePlayerIndex, 40);
      }
    } else {
      if (msg.contains('\$200') && !msg.contains('assessed')) {
        _addCash(_gameState.activePlayerIndex, 200);
      } else if (msg.contains('\$100')) {
        _addCash(_gameState.activePlayerIndex, 100);
      } else if (msg.contains('\$20')) {
        _addCash(_gameState.activePlayerIndex, 20);
      } else if (msg.contains('\$25')) {
        _addCash(_gameState.activePlayerIndex, 25);
      }
    }
    if (msg.contains('Go to Jail')) {
      _sendToJail(_gameState.activePlayerIndex);
    }
    _addLog('Chance: $msg');
  }

  Future<void> _onEndTurn() async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.endTurn(),
      currentState: _currentState,
    );
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: 'Turn ended',
      );
      _rollsRemainingThisTurn = 1;
      _landedTileIdThisTurn = null;
    });
    _addLog(
        'Turn ${_gameState.currentTurn} — Player ${_gameState.activePlayerIndex + 1}\'s turn');
  }

  Future<void> _onBuyProperty(String tileId) async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.buyProperty(tileId),
      currentState: _currentState,
    );
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: 'Bought $tileId',
      );
    });
    _addLog('Player bought $tileId');
  }

  Future<void> _onUpgradeProperty(String tileId) async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.upgradeProperty(tileId),
      currentState: _currentState,
    );
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: 'Upgraded $tileId',
      );
    });
    _addLog('Player upgraded $tileId');
  }

  /// Find a property definition at the given tile position.
  Map<String, dynamic>? _findPropertyAtTile(String tileId) {
    final properties =
        (_currentState['board'] as Map<String, dynamic>)['properties']
            as List<dynamic>?;
    if (properties == null) return null;
    for (final p in properties) {
      if ((p as Map<String, dynamic>)['tile_id'] == tileId) {
        return p as Map<String, dynamic>;
      }
    }
    return null;
  }

  int _playerPropertyCount(String playerId) {
    final properties =
        (_currentState['board'] as Map<String, dynamic>)['properties']
            as List<dynamic>?;
    if (properties == null) return 0;
    return properties
        .where((p) => (p as Map<String, dynamic>)['owner'] == playerId)
        .length;
  }

  // ---- Dialogs -------------------------------------------------------------

  void _showBuyPropertyDialog(String tileId, Map<String, dynamic> property) {
    final price = (property['base_price'] as num).toInt();
    final player = _gameState.players[_gameState.activePlayerIndex];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Buy Property'),
        content: Text(
          'Would you like to buy this property for \$$price?\n\n'
          'Your cash: \$${player.cash}',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Start auction instead
              _showAuctionDialog(tileId, price);
            },
            child: const Text('Auction'),
          ),
          FilledButton(
            onPressed: price <= player.cash
                ? () {
                    Navigator.of(ctx).pop();
                    _onBuyProperty(tileId);
                  }
                : null,
            child: const Text('Buy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Skip'),
          ),
        ],
      ),
    );
  }

  void _showUpgradePropertyDialog(String tileId, Map<String, dynamic> property) {
    final currentLevel = (property['upgrade_level'] as num?)?.toInt() ?? 0;
    final basePrice = (property['base_price'] as num).toInt();
    final base = (property['rent'] as List<dynamic>?)?.isNotEmpty == true
        ? ((property['rent'] as List<dynamic>).first as num).toInt()
        : basePrice;
    // upgrade_cost = base * (1 + current_level) / 2
    final cost = base * (1 + currentLevel) ~/ 2;
    final player = _gameState.players[_gameState.activePlayerIndex];
    final canAfford = player.cash >= cost;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Upgrade Property'),
        content: Text(
          'Current level: $currentLevel\n'
          'Upgrade cost: \$$cost\n\n'
          'Your cash: \$${player.cash}',
        ),
        actions: [
          FilledButton(
            onPressed: canAfford
                ? () {
                    Navigator.of(ctx).pop();
                    _onUpgradeProperty(tileId);
                  }
                : null,
            child: const Text('Upgrade'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Skip'),
          ),
        ],
      ),
    );
  }

  void _showAuctionDialog(String tileId, int startingBid) {
    final controller = TextEditingController(text: startingBid.toString());

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Auction'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Property auction started!'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Your bid',
                prefixText: '\$',
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Pass'),
          ),
          FilledButton(
            onPressed: () {
              final bid = int.tryParse(controller.text) ?? startingBid;
              Navigator.of(ctx).pop();
              _addLog('Auction bid: \$$bid for $tileId');
            },
            child: const Text('Bid'),
          ),
        ],
      ),
    );
  }

  void _showTradeDialog() {
    final activePlayerId = _gameState.players[_gameState.activePlayerIndex].id;

    final playerControllers = <int, TextEditingController>{};
    for (var i = 0; i < _gameState.numPlayers; i++) {
      if (_gameState.players[i].id != activePlayerId) {
        playerControllers[i] = TextEditingController();
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('Trade'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: [
                  const Text('Select a player and offer:'),
                  const SizedBox(height: 12),
                  ...playerControllers.entries.map((entry) {
                    final player = _gameState.players[entry.key];
                    return Card(
                      child: ListTile(
                        title: Text('With ${player.name}'),
                        subtitle: TextField(
                          controller: entry.value,
                          decoration: const InputDecoration(
                            labelText: 'Cash offer',
                            prefixText: '\$',
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _addLog('Trade proposed');
                },
                child: const Text('Propose Trade'),
              ),
            ],
          );
        },
      ),
    );
  }

  // (Replaced by _showCardShopDialog above)

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _GameSettingsDialog(
        configProvider: _configProvider,
        initialPlayerCount: _gameState.numPlayers,
        onStart: (count, playerNames, aiFlags) {
          Navigator.of(ctx).pop();
          setState(() {
            _currentState = _buildInitialState(count);
            // Apply custom names and AI flags
            final players =
                _currentState['players'] as List<Map<String, dynamic>>;
            for (var i = 0; i < count && i < playerNames.length; i++) {
              players[i]['name'] = playerNames[i];
              players[i]['is_ai'] = aiFlags[i];
            }
            _currentState['players'] = players;
            _gameState = _buildGameState(_currentState,
                lastEvent: 'Game reset');
          });
          _addLog('Game restarted with $count players');
        },
      ),
    );
  }

  // ---- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final activePlayer =
        _gameState.players.isNotEmpty &&
                _gameState.activePlayerIndex < _gameState.players.length
            ? _gameState.players[_gameState.activePlayerIndex]
            : null;

    // Convert raw tiles to BoardTileViewModel for the board
    final rawTiles = (_currentState['board'] as Map<String, dynamic>?)?
            ['tiles'] as List<dynamic>? ??
        [];
    final tiles = rawTiles
        .map((t) => BoardTileViewModel(
              id: t['id'] as String,
              name: t['name'] as String? ??
                  t['name_key'] as String? ??
                  t['id'] as String,
              kind: t['kind'] as String? ?? 'Unknown',
            ))
        .toList();

    // Determine player property owners for display
    final propertyOwners = <String, String>{};
    final rawProperties =
        (_currentState['board'] as Map<String, dynamic>?)?
                ['properties'] as List<dynamic>? ??
            [];
    for (final p in rawProperties) {
      final owner = (p as Map<String, dynamic>)['owner'] as String?;
      if (owner != null) {
        propertyOwners[p['tile_id'] as String] = owner;
      }
    }

    final boardViewModel = BoardViewModel(
      mapName: _useComplexBoard ? 'Complex L-Board' : 'Classic',
      tiles: tiles,
      players: _gameState.players,
      activePlayerIndex: _gameState.activePlayerIndex,
      propertyOwners: propertyOwners,
      perimeterPositions: _useComplexBoard ? _complexPositions : null,
    );

    return GameStateWidget(
      data: _gameState,
      onUpdate: (data) => setState(() => _gameState = data),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('saMonopoly'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Game Settings',
              onPressed: _showSettingsDialog,
            ),
          ],
        ),
        body: SafeArea(
          child: Row(
            children: [
              // ---- Isometric Board (left side) ------------------------------
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Stack(
                    children: [
                      IsometricBoardWidget(
                        viewModel: boardViewModel,
                      ),
                      // Minimap overlay
                      Positioned(
                        top: 4,
                        right: 4,
                        child: MinimapWidget(
                          viewModel: boardViewModel,
                          gridSize: _useComplexBoard && boardViewModel.perimeterPositions != null
                              ? boardViewModel.perimeterPositions!
                                  .fold< int>(0, (m, p) => p.$1 > m ? p.$1 : m) + 1
                              : (tiles.length >= 4
                                  ? ((tiles.length - 4) ~/ 4) + 2
                                  : 11),
                          tileWidth: 60,
                          tileHeight: 60,
                          ownerColors: propertyOwners.map(
                            (k, v) => MapEntry(k, _playerColorForOwner(v)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ---- Right sidebar (player info, dice, controls, log) --------
              SizedBox(
                width: 220,
                child: Column(
                  children: [
                    // Player info
                    _buildPlayerInfoBar(activePlayer!),
                    const Divider(height: 1),
                    // Dice display
                    _buildDiceDisplay(),
                    const Divider(height: 1),
                    // Action buttons
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: _buildActionButtons(activePlayer!),
                    ),
                    const Divider(height: 1),
                    // Event log
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: _buildEventLog(),
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

  Widget _buildPlayerInfoBar(PlayerTokenViewModel activePlayer) {
    return Container(
      padding: const EdgeInsets.all(8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Active player avatar and name
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                backgroundColor: activePlayer.color,
                radius: 14,
                child: Text(
                  activePlayer.name.isNotEmpty
                      ? activePlayer.name[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  activePlayer.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Cash
          Text(
            '\$${activePlayer.cash}',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: Colors.green,
            ),
          ),
          const SizedBox(height: 2),
          // Turn + properties
          Text(
            'Turn ${_gameState.currentTurn} | ${_playerPropertyCount(activePlayer.id)} props',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildDiceDisplay() {
    // Use animated values during rolling, otherwise use actual result
    final dice1 = _isRollingDice ? _animDice1 : (_gameState.diceResult['dice1'] ?? 0);
    final dice2 = _isRollingDice ? _animDice2 : (_gameState.diceResult['dice2'] ?? 0);
    final show = _isRollingDice || _gameState.diceResult.isNotEmpty;
    return SizedBox(
      height: 60,
      child: show
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _diceFace(dice1),
                  const SizedBox(width: 8),
                  _diceFace(dice2),
                  const SizedBox(width: 10),
                  Text(
                    '= ${dice1 + dice2}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _diceFace(int value) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade400),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(2, 2),
          ),
        ],
      ),
      child: Center(
        child: Text(
          '$value',
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons(PlayerTokenViewModel activePlayer) {
    final isMyTurn = _gameState.activePlayerIndex ==
        _gameState.players.indexOf(activePlayer);
    final canAct = isMyTurn && !_isAnimating;
    final canRoll = canAct && _rollsRemainingThisTurn > 0;
    
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Roll dice (1 per turn, re-roll only on 6)
        FilledButton.icon(
          onPressed: canRoll ? _onRoll : null,
          icon: const Icon(Icons.casino, size: 18),
          label: Text(_rollsRemainingThisTurn > 1
              ? 'Roll ($_rollsRemainingThisTurn)'
              : 'Roll'),
        ),
        const SizedBox(height: 4),
        // Buy / Upgrade property — only allowed on the turn the player
        // first arrives at this tile (prevents camping and re-upgrading).
        OutlinedButton.icon(
          onPressed: (isMyTurn && _landedTileIdThisTurn != null) ? () {
            final pos = _gameState
                .players[_gameState.activePlayerIndex]
                .tileId;
            // Only allow if the player is still on the tile they just landed on
            if (pos != _landedTileIdThisTurn) {
              _addLog('You must roll to reach this tile first');
              return;
            }
            final prop = _findPropertyAtTile(pos);
            if (prop != null) {
              final owner = prop['owner'] as String?;
              final playerId = _gameState.players[_gameState.activePlayerIndex].id;
              if (owner == null) {
                _showBuyPropertyDialog(pos, prop);
              } else if (owner == playerId) {
                final maxLevel = (_currentState['max_upgrade_level'] as num?)?.toInt() ?? 3;
                final currentLevel = (prop['upgrade_level'] as num?)?.toInt() ?? 0;
                if (maxLevel > 0 && currentLevel < maxLevel) {
                  _showUpgradePropertyDialog(pos, prop);
                } else {
                  _addLog('Property already at max level');
                }
              } else {
                _addLog('This property belongs to another player');
              }
            } else {
              _addLog('No property here');
            }
          } : null,
          icon: const Icon(Icons.build, size: 18),
          label: const Text('Buy / Upgrade'),
        ),
        const SizedBox(height: 4),
        // Trade
        OutlinedButton.icon(
          onPressed: () => _showTradeDialog(),
          icon: const Icon(Icons.swap_horiz, size: 18),
          label: const Text('Trade'),
        ),
        const SizedBox(height: 4),
        // Card inventory
        OutlinedButton.icon(
          onPressed: () => _showCardInventoryDialog(),
          icon: const Icon(Icons.inventory_2, size: 18),
          label: const Text('Inventory'),
        ),
        const SizedBox(height: 4),
        // End turn
        FilledButton.tonalIcon(
          onPressed: canAct ? _onEndTurn : null,
          icon: const Icon(Icons.skip_next, size: 18),
          label: const Text('End Turn'),
        ),
      ],
    );
  }

  Widget _buildEventLog() {
    final events = _gameState.eventLog;
    return ListView.builder(
      controller: _logScrollController,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      itemCount: events.length,
      itemBuilder: (context, index) {
        return Text(
          events[index],
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey.shade600,
                fontSize: 11,
              ),
        );
      },
    );
  }

  /// Compact row: action buttons on the left, event log on the right.
  Widget _buildControlsAndLog(PlayerTokenViewModel activePlayer) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
      child: Row(
        children: [
          // Action buttons
          Expanded(
            flex: 3,
            child: _buildActionButtons(activePlayer),
          ),
          const SizedBox(width: 8),
          // Event log (compact)
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 60,
              child: _buildEventLog(),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Game settings dialog
// ============================================================================

class _GameSettingsDialog extends StatefulWidget {
  final ConfigProvider configProvider;
  final int initialPlayerCount;
  final void Function(
      int count, List<String> names, List<bool> aiFlags) onStart;

  const _GameSettingsDialog({
    required this.configProvider,
    required this.initialPlayerCount,
    required this.onStart,
  });

  @override
  State<_GameSettingsDialog> createState() => _GameSettingsDialogState();
}

class _GameSettingsDialogState extends State<_GameSettingsDialog>
    with SingleTickerProviderStateMixin {
  late int _playerCount;
  late List<TextEditingController> _nameControllers;
  late List<bool> _aiFlags;
  late TabController _tabController;

  // ── App config controllers ───────────────────────────────────────────────
  late TextEditingController _languageCtrl;
  late TextEditingController _themeCtrl;

  // ── Game config controllers ──────────────────────────────────────────────
  late TextEditingController _startCashCtrl;
  late TextEditingController _maxPlayersCtrl;
  late TextEditingController _passBonusCtrl;
  late TextEditingController _jailTurnsCtrl;
  late TextEditingController _hospitalTurnsCtrl;
  late TextEditingController _maxUpgradeCtrl;
  bool _extensionUpgradeEnabled = false;
  bool _groupRentEnabled = false;
  bool _stockMarketEnabled = false;
  bool _lotteryEnabled = false;
  bool _auctionEnabled = true;
  bool _mortgageEnabled = true;
  bool _tradeEnabled = true;

  // ── Network config controllers ───────────────────────────────────────────
  late TextEditingController _hostCtrl;
  late TextEditingController _portCtrl;
  bool _tlsEnabled = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    final app = widget.configProvider.app;
    final game = widget.configProvider.game;
    final network = widget.configProvider.network;

    _playerCount = widget.initialPlayerCount;
    _nameControllers = List.generate(
      _playerCount,
      (i) => TextEditingController(text: 'Player ${i + 1}'),
    );
    _aiFlags = List.generate(
      _playerCount,
      (i) => i > 0,
    );

    _languageCtrl = TextEditingController(text: app.language);
    _themeCtrl = TextEditingController(text: app.theme);
    _startCashCtrl =
        TextEditingController(text: game.startingCash.toString());
    _maxPlayersCtrl =
        TextEditingController(text: game.maxPlayers.toString());
    _passBonusCtrl =
        TextEditingController(text: game.passStartBonus.toString());
    _jailTurnsCtrl =
        TextEditingController(text: game.jailEscapeTurns.toString());
    _hospitalTurnsCtrl =
        TextEditingController(text: game.hospitalRecoveryTurns.toString());
    _maxUpgradeCtrl =
        TextEditingController(text: game.maxUpgradeLevel.toString());
    _extensionUpgradeEnabled = game.extensionUpgradeEnabled;
    _groupRentEnabled = game.groupRentEnabled;
    _stockMarketEnabled = game.stockMarketEnabled;
    _lotteryEnabled = game.lotteryEnabled;
    _auctionEnabled = game.auctionEnabled;
    _mortgageEnabled = game.mortgageEnabled;
    _tradeEnabled = game.tradeEnabled;
    _hostCtrl = TextEditingController(text: network.host);
    _portCtrl = TextEditingController(text: network.port.toString());
    _tlsEnabled = network.tls;
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final c in _nameControllers) {
      c.dispose();
    }
    _languageCtrl.dispose();
    _themeCtrl.dispose();
    _startCashCtrl.dispose();
    _maxPlayersCtrl.dispose();
    _passBonusCtrl.dispose();
    _jailTurnsCtrl.dispose();
    _hospitalTurnsCtrl.dispose();
    _maxUpgradeCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  void _updatePlayerCount(int count) {
    setState(() {
      if (count > _playerCount) {
        for (var i = _playerCount; i < count; i++) {
          _nameControllers.add(TextEditingController(text: 'Player ${i + 1}'));
          _aiFlags.add(true);
        }
      } else if (count < _playerCount) {
        for (var i = _playerCount - 1; i >= count; i--) {
          _nameControllers[i].dispose();
          _nameControllers.removeAt(i);
          _aiFlags.removeAt(i);
        }
      }
      _playerCount = count;
    });
  }

  void _saveConfig() {
    widget.configProvider.updateApp(AppConfig(
      language: _languageCtrl.text,
      theme: _themeCtrl.text,
    ));
    widget.configProvider.updateGame(GameConfig(
      startingCash: int.tryParse(_startCashCtrl.text) ?? 1500,
      maxPlayers: int.tryParse(_maxPlayersCtrl.text) ?? 4,
      passStartBonus: int.tryParse(_passBonusCtrl.text) ?? 200,
      jailEscapeTurns: int.tryParse(_jailTurnsCtrl.text) ?? 3,
      hospitalRecoveryTurns: int.tryParse(_hospitalTurnsCtrl.text) ?? 2,
      maxUpgradeLevel: int.tryParse(_maxUpgradeCtrl.text) ?? 3,
      extensionUpgradeEnabled: _extensionUpgradeEnabled,
      groupRentEnabled: _groupRentEnabled,
      stockMarketEnabled: _stockMarketEnabled,
      lotteryEnabled: _lotteryEnabled,
      auctionEnabled: _auctionEnabled,
      mortgageEnabled: _mortgageEnabled,
      tradeEnabled: _tradeEnabled,
    ));
    widget.configProvider.updateNetwork(NetworkConfig(
      host: _hostCtrl.text,
      port: int.tryParse(_portCtrl.text) ?? 9000,
      tls: _tlsEnabled,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 380,
        height: 440,
        child: Column(
          children: [
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Players'),
                Tab(text: 'Rules'),
                Tab(text: 'Network'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // ── Tab 1: Players ─────────────────────────────────────
                  _buildPlayersTab(),
                  // ── Tab 2: Game Rules ──────────────────────────────────
                  _buildRulesTab(),
                  // ── Tab 3: Network ─────────────────────────────────────
                  _buildNetworkTab(),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            _saveConfig();
            widget.onStart(
              _playerCount,
              _nameControllers.map((c) => c.text).toList(),
              _aiFlags,
            );
          },
          child: const Text('Start Game'),
        ),
      ],
    );
  }

  // ── Tab builders ─────────────────────────────────────────────────────────

  Widget _buildPlayersTab() {
    return ListView(
      children: [
        // Player count
        Row(
          children: [
            const Text('Players:'),
            const Spacer(),
            IconButton(
              onPressed: _playerCount > 2
                  ? () => _updatePlayerCount(_playerCount - 1)
                  : null,
              icon: const Icon(Icons.remove_circle_outline),
            ),
            Text(
              '$_playerCount',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            IconButton(
              onPressed: _playerCount < 6
                  ? () => _updatePlayerCount(_playerCount + 1)
                  : null,
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
        const Divider(),
        for (var i = 0; i < _playerCount; i++) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        backgroundColor:
                            _playerColors[i % _playerColors.length],
                        radius: 12,
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _nameControllers[i],
                          decoration: const InputDecoration(
                            labelText: 'Name',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('AI Player'),
                    subtitle: Text(
                        _aiFlags[i] ? 'Computer controlled' : 'Human'),
                    value: _aiFlags[i],
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setState(() => _aiFlags[i] = v),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ],
    );
  }

  Widget _buildRulesTab() {
    return ListView(
      children: [
        TextField(
          controller: _startCashCtrl,
          decoration: const InputDecoration(
            labelText: 'Starting Cash (\$)',
            isDense: true,
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passBonusCtrl,
          decoration: const InputDecoration(
            labelText: 'Pass Start Bonus (\$)',
            isDense: true,
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _jailTurnsCtrl,
          decoration: const InputDecoration(
            labelText: 'Jail Turns',
            isDense: true,
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _hospitalTurnsCtrl,
          decoration: const InputDecoration(
            labelText: 'Hospital Turns',
            isDense: true,
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _maxUpgradeCtrl,
          decoration: const InputDecoration(
            labelText: 'Max Upgrade Level (0 = disabled)',
            isDense: true,
            helperText: 'Rent & cost calculated by formula',
            helperMaxLines: 1,
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          title: const Text('Utility Upgrades'),
          subtitle: const Text('Allow upgrading Electric Co / Water Works'),
          value: _extensionUpgradeEnabled,
          dense: true,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(() => _extensionUpgradeEnabled = v),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          title: const Text('Group Rent'),
          subtitle: const Text('Sum rent when full group owned'),
          value: _groupRentEnabled,
          dense: true,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(() => _groupRentEnabled = v),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          title: const Text('Stock Market'),
          value: _stockMarketEnabled,
          dense: true,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(() => _stockMarketEnabled = v),
        ),
        SwitchListTile(
          title: const Text('Lottery'),
          value: _lotteryEnabled,
          dense: true,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(() => _lotteryEnabled = v),
        ),
        SwitchListTile(
          title: const Text('Auctions'),
          value: _auctionEnabled,
          dense: true,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(() => _auctionEnabled = v),
        ),
        SwitchListTile(
          title: const Text('Mortgages'),
          value: _mortgageEnabled,
          dense: true,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(() => _mortgageEnabled = v),
        ),
        SwitchListTile(
          title: const Text('Trading'),
          value: _tradeEnabled,
          dense: true,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(() => _tradeEnabled = v),
        ),
      ],
    );
  }

  Widget _buildNetworkTab() {
    return ListView(
      children: [
        TextField(
          controller: _hostCtrl,
          decoration: const InputDecoration(
            labelText: 'Host',
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _portCtrl,
          decoration: const InputDecoration(
            labelText: 'Port',
            isDense: true,
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          title: const Text('TLS'),
          value: _tlsEnabled,
          dense: true,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(() => _tlsEnabled = v),
        ),
      ],
    );
  }
}

/// Pre-defined player colours matching BoardPainter
const List<Color> _playerColors = [
  Color(0xFFD32F2F),
  Color(0xFF1976D2),
  Color(0xFF388E3C),
  Color(0xFFFBC02D),
  Color(0xFF8E24AA),
  Color(0xFFFF6F00),
];
