import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'board_view.dart';
import 'home_screen.dart';
import 'network_service.dart';
import 'save_manager.dart';
import 'save_manager.dart';
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
      home: const HomeScreen(),
    );
  }
}

// ============================================================================
// Game screen – orchestrates the board, player panel, and action buttons
// ============================================================================

class GameScreen extends StatefulWidget {
  final int? initialPlayerCount;
  final List<String>? playerNames;
  final List<bool>? aiFlags;
  /// Team ID for each player (null = no team). Indexed as 'team_0'..'team_3'.
  final List<String?>? teamIds;
  /// Map ID from the map selection screen. When 'classic', uses the 40-tile
  /// classic board; otherwise falls through to the complex/L-shaped board.
  final String? mapId;
  /// Raw game state to load from a save file. When set, this state is used
  /// directly instead of building a fresh initial state.
  final Map<String, dynamic>? initialState;
  /// Network service for host/client game synchronization.
  /// When non-null, the game runs in networked mode.
  final NetworkService? networkService;

  const GameScreen({
    super.key,
    this.initialPlayerCount,
    this.playerNames,
    this.aiFlags,
    this.teamIds,
    this.mapId,
    this.initialState,
    this.networkService,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final BridgeClient _bridgeClient = BridgeClient();
  final ContentPackLoader _loader = const ContentPackLoader();
  final ScrollController _logScrollController = ScrollController();

  // ---- Network state -------------------------------------------------------
  NetworkService? _networkService;
  StreamSubscription<Map<String, dynamic>>? _netGameSub;

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

  /// Persists the last dice result across state rebuilds.
  /// Set after a successful roll, cleared on End Turn.
  /// Ensures dice values remain visible until the turn advances.
  Map<String, int> _lastDiceResult = {};

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

  /// When non-null, the property detail overlay is shown for this tile.
  /// Using state-based overlay instead of showDialog for instant response.
  String? _detailTileId;

  /// Whether the current active player is controlled by this client.
  ///
  /// - **Offline**: always `true` (no restrictions).
  /// - **Host**: controls player_0 (`activePlayerIndex == 0`).
  /// - **Client**: controls any other player (`activePlayerIndex > 0`).
  bool get _isLocalPlayersTurn {
    if (_networkService == null) return true; // Offline mode: no restriction
    if (_networkService!.isHost) {
      // Host controls player_0
      return _gameState.activePlayerIndex == 0;
    } else {
      // Client controls other players
      return _gameState.activePlayerIndex > 0;
    }
  }

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
  /// Controlled by [widget.mapId]: 'classic' → false (use classic 40-tile),
  /// anything else → true (use complex L-shaped test board).
  late bool _useComplexBoard;

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
  /// The 40-tile classic Monopoly board with reserved expansion slots.
  ///
  /// Tiles with kind "Reserved" are pass-through tiles (no effect) that can
  /// be dynamically replaced with `Lottery` or `StockMarket` tiles when those
  /// sub-systems are enabled via game config.
  final List<Map<String, String>> _defaultTiles = const [
    // ── Bottom row (Start → Jail) ─────────────────────────────────────
    {'id': 'start',     'name': 'Start',             'kind': 'Start'},
    {'id': 'prop_1',    'name': 'Mediterranean Ave',  'kind': 'OrdinaryProperty'},
    {'id': 'chance_1',  'name': 'Chance',             'kind': 'Chance'},
    {'id': 'prop_2',    'name': 'Baltic Ave',         'kind': 'OrdinaryProperty'},
    {'id': 'tax_1',     'name': 'Income Tax',         'kind': 'Bank'},
    {'id': 'rr_1',      'name': 'Reading RR',         'kind': 'OrdinaryProperty'},
    {'id': 'prop_3',    'name': 'Oriental Ave',       'kind': 'OrdinaryProperty'},
    {'id': 'lottery_1', 'name': 'Lottery',            'kind': 'Lottery'},
    {'id': 'prop_4',    'name': 'Vermont Ave',        'kind': 'OrdinaryProperty'},
    {'id': 'prop_5',    'name': 'Connecticut Ave',    'kind': 'OrdinaryProperty'},
    // ── Right column (Jail → Free Parking) ────────────────────────────
    {'id': 'jail',      'name': 'Jail',               'kind': 'Jail'},
    {'id': 'prop_6',    'name': 'St. Charles Pl',     'kind': 'OrdinaryProperty'},
    {'id': 'util_1',    'name': 'Electric Co',        'kind': 'ExtensionProperty'},
    {'id': 'prop_7',    'name': 'States Ave',         'kind': 'OrdinaryProperty'},
    {'id': 'prop_8',    'name': 'Virginia Ave',       'kind': 'OrdinaryProperty'},
    {'id': 'rr_2',      'name': 'Penn RR',            'kind': 'OrdinaryProperty'},
    {'id': 'prop_9',    'name': 'St. James Pl',       'kind': 'OrdinaryProperty'},
    {'id': 'chance_3',  'name': 'Chance',             'kind': 'Chance'},
    {'id': 'prop_10',   'name': 'Tennessee Ave',      'kind': 'OrdinaryProperty'},
    {'id': 'prop_11',   'name': 'New York Ave',       'kind': 'OrdinaryProperty'},
    // ── Top row (Free Parking → Go To Jail) ──────────────────────────
    {'id': 'park',      'name': 'Free Parking',       'kind': 'Bank'},
    {'id': 'prop_12',   'name': 'Kentucky Ave',       'kind': 'OrdinaryProperty'},
    {'id': 'chance_4',  'name': 'Chance',             'kind': 'Chance'},
    {'id': 'prop_13',   'name': 'Indiana Ave',        'kind': 'OrdinaryProperty'},
    {'id': 'prop_14',   'name': 'Illinois Ave',       'kind': 'OrdinaryProperty'},
    {'id': 'rr_3',      'name': 'B&O RR',             'kind': 'OrdinaryProperty'},
    {'id': 'prop_15',   'name': 'Atlantic Ave',       'kind': 'OrdinaryProperty'},
    {'id': 'card_shop_1','name': 'Card Shop',         'kind': 'CardShop'},
    {'id': 'util_2',    'name': 'Water Works',        'kind': 'ExtensionProperty'},
    {'id': 'prop_17',   'name': 'Marvin Gardens',     'kind': 'OrdinaryProperty'},
    // ── Left column (Go To Jail → Start) ─────────────────────────────
    {'id': 'go_to_jail','name': 'Go To Jail',         'kind': 'Jail'},
    {'id': 'prop_18',   'name': 'Pacific Ave',        'kind': 'OrdinaryProperty'},
    {'id': 'prop_19',   'name': 'N. Carolina Ave',    'kind': 'OrdinaryProperty'},
    {'id': 'chance_5',  'name': 'Chance',             'kind': 'Chance'},
    {'id': 'prop_20',   'name': 'Pennsylvania Ave',   'kind': 'OrdinaryProperty'},
    {'id': 'rr_4',      'name': 'Short Line',         'kind': 'OrdinaryProperty'},
    {'id': 'reserve_1', 'name': 'Expansion Slot',     'kind': 'Bank'},   // → StockMarket
    {'id': 'prop_21',   'name': 'Park Place',         'kind': 'OrdinaryProperty'},
    {'id': 'tax_2',     'name': 'Luxury Tax',         'kind': 'Bank'},
    {'id': 'prop_22',   'name': 'Boardwalk',          'kind': 'OrdinaryProperty'},
  ];

  final SaveManager _saveManager = SaveManager();

  @override
  void initState() {
    super.initState();
    _pack = sampleClassicPack();

    // Map selection: 'classic' uses the 40-tile board, anything else uses
    // the complex L-shaped test board for development/testing.
    _useComplexBoard = widget.mapId != 'classic';

    _networkService = widget.networkService;

    // ────────────────────────────────────────────────────────────────────────
    // Network mode: host or client
    // ────────────────────────────────────────────────────────────────────────
    if (widget.networkService != null) {
      final net = widget.networkService!;

      // Subscribe to network messages
      _netGameSub = net.messages.listen(_onNetworkMessage);

      if (net.isHost) {
        // ── Host: build state locally, broadcast game_start ────────────
        if (widget.initialState != null) {
          _currentState = Map<String, dynamic>.from(widget.initialState!);
        } else {
          final playerCount = widget.initialPlayerCount ?? 2;
          _currentState = _buildInitialState(playerCount, teamIds: widget.teamIds);

          if (widget.playerNames != null || widget.aiFlags != null) {
            final players = _currentState['players'] as List<Map<String, dynamic>>;
            for (var i = 0; i < players.length && i < playerCount; i++) {
              if (widget.playerNames != null && i < widget.playerNames!.length) {
                players[i]['name'] = widget.playerNames![i];
              }
              if (widget.aiFlags != null && i < widget.aiFlags!.length) {
                players[i]['is_ai'] = widget.aiFlags![i];
              }
            }
            _currentState['players'] = players;
          }
        }
        _gameState = _buildGameState(_currentState, lastEvent: 'Game started (host)');
        _landedTileIdThisTurn = null;
        _addLog('Game started (host mode)');

        // Broadcast initial state to all connected clients
        net.sendMessage({
          'type': 'game_start',
          'state': _currentState,
        });
      } else {
        // ── Client: wait for game_start from host ──────────────────────
        _landedTileIdThisTurn = null;
        if (widget.initialState != null) {
          // State was already provided via game_start message from lobby
          _currentState = Map<String, dynamic>.from(widget.initialState!);
          _gameState = _buildGameState(_currentState, lastEvent: 'Game started (client)');
          _addLog('Game started (client mode)');
        } else {
          // State will arrive via game_start message on the network stream
          _currentState = {};
          _gameState = const GameStateData();
          _addLog('Waiting for host to start game...');
        }
      }
      return;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Offline mode (original logic)
    // ────────────────────────────────────────────────────────────────────────
    if (widget.initialState != null) {
      // ── Load from save ──────────────────────────────────────────────
      _currentState = Map<String, dynamic>.from(widget.initialState!);
      _gameState = _buildGameState(_currentState, lastEvent: 'Game restored');
      _landedTileIdThisTurn = null;
      final mapLabel = _useComplexBoard ? 'Complex L‑board' : 'Classic';
      _addLog('Game restored from save ($mapLabel) with ${_gameState.numPlayers} players');
    } else {
      // ── Fresh game ──────────────────────────────────────────────────
      final playerCount = widget.initialPlayerCount ?? 2;
      _currentState = _buildInitialState(playerCount, teamIds: widget.teamIds);
      _gameState = _buildGameState(_currentState);
      _landedTileIdThisTurn = null;

      // Apply custom player names and AI flags if provided
      if (widget.playerNames != null || widget.aiFlags != null) {
        final players = _currentState['players'] as List<Map<String, dynamic>>;
        for (var i = 0; i < players.length && i < playerCount; i++) {
          if (widget.playerNames != null && i < widget.playerNames!.length) {
            players[i]['name'] = widget.playerNames![i];
          }
          if (widget.aiFlags != null && i < widget.aiFlags!.length) {
            players[i]['is_ai'] = widget.aiFlags![i];
          }
        }
        _currentState['players'] = players;
        _gameState = _buildGameState(_currentState, lastEvent: 'Game initialized');
      }

      final mapLabel = _useComplexBoard ? 'Complex L‑board' : 'Classic';
      _addLog('Game started ($mapLabel) with ${_gameState.numPlayers} players');
    }
  }

  /// Handle incoming network messages.
  void _onNetworkMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    final isHost = _networkService?.isHost ?? false;
    switch (type) {
      // ── Two-phase roll animation protocol ──────────────────────────────
      case 'roll_start':
        if (isHost) {
          if (!_isRollingDice) _handleRemoteRollStart();
          _networkService?.sendMessage(message);
        } else {
          if (!_isRollingDice) _handleRemoteRollStart();
        }
        break;

      case 'roll_end':
        final dice1 = (message['dice1'] as num?)?.toInt() ?? 0;
        final dice2 = (message['dice2'] as num?)?.toInt() ?? 0;
        final state = message['state'] as Map<String, dynamic>?;
        final event = message['event'] as Map<String, dynamic>?;
        if (state != null) {
          if (isHost) {
            _handleRemoteRollEnd(dice1, dice2, state, event);
            _networkService?.sendMessage(message);
          } else {
            _handleRemoteRollEnd(dice1, dice2, state, event);
          }
        }
        break;

      // ── Two-phase movement animation protocol ──────────────────────────
      case 'move_start':
        final playerIdx = message['player_index'] as int? ?? 0;
        final tilePath = message['tile_path'] as List<dynamic>? ?? [];
        if (tilePath.isNotEmpty) {
          if (isHost) {
            _handleRemoteMoveStart(playerIdx, tilePath);
            _networkService?.sendMessage(message);
          } else {
            // Skip rebroadcast echo if we are the roller (already animating)
            if (!_isAnimating) {
              _handleRemoteMoveStart(playerIdx, tilePath);
            }
          }
        }
        break;

      case 'move_end':
        final moveState = message['state'] as Map<String, dynamic>?;
        // Both host and client: finalize movement (clear animation flags).
        // Host additionally rebroadcasts to other clients.
        _handleRemoteMoveEnd(moveState);
        if (isHost) {
          _networkService?.sendMessage(message);
        }
        break;

      // ── State sync for non-roll actions ────────────────────────────────
      case 'state_sync':
        final state = message['state'] as Map<String, dynamic>?;
        final event = message['event'] as Map<String, dynamic>?;
        if (state != null) {
          debugPrint('[NetSync] Received state_sync (isHost: $isHost)');

          if (isHost) {
            // ── Host received state from a client ─────────────────────
            setState(() {
              _currentState = state;
              _gameState = _buildGameState(state, lastEvent: 'State synced');
            });
            // Rebroadcast to all other clients
            _networkService?.sendMessage({
              'type': 'state_sync',
              'state': state,
              'event': event,
            });
          } else {
            // ── Client received state from host ───────────────────────
            // Note: dice rolls use roll_start/roll_end protocol; state_sync
            // here only carries non-roll updates (EndTurn, BuyProperty, etc.)
            setState(() {
              _currentState = state;
              _gameState = _buildGameState(state, lastEvent: 'State synced');
            });
          }
        } else {
          debugPrint('[NetSync] state_sync with null state');
        }
        break;

      case 'game_start':
        final state = message['state'] as Map<String, dynamic>?;
        if (state != null && mounted) {
          setState(() {
            _currentState = state;
            _gameState = _buildGameState(state, lastEvent: 'Game started (client)');
          });
          _addLog('Game started via network');
        }
        break;
    }
  }

  // ── Two-phase roll animation helpers ─────────────────────────────────────

  /// Broadcast that a dice roll animation has started.
  void _broadcastRollStart() {
    final net = widget.networkService;
    if (net == null || !mounted) return;
    net.sendMessage({
      'type': 'roll_start',
      'player_index': _gameState.activePlayerIndex,
    });
  }

  /// Broadcast the final dice result after animation completes.
  void _broadcastRollEnd(int dice1, int dice2, BridgeResponse response) {
    final net = widget.networkService;
    if (net == null || !mounted) return;
    net.sendMessage({
      'type': 'roll_end',
      'dice1': dice1,
      'dice2': dice2,
      'state': response.state,
      'event': response.event,
    });
  }

  /// Start dice animation on this client (called when roll_start arrives).
  void _handleRemoteRollStart() {
    if (!mounted) return;
    setState(() {
      _isRollingDice = true;
      _isAnimating = true;
    });
    // Run a continuous animation loop until roll_end arrives
    _runRemoteDiceAnimation();
  }

  /// Continuously animate dice face values until roll_end stops it.
  Future<void> _runRemoteDiceAnimation() async {
    var frame = 0;
    while (_isRollingDice && mounted) {
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted || !_isRollingDice) return;
      setState(() {
        _animDice1 = 1 + (frame * 3 + 1) % 6;
        _animDice2 = 1 + (frame * 7 + 3) % 6;
      });
      frame++;
    }
  }

  /// Show final dice result + apply state (called when roll_end arrives).
  /// Clears animation flags; move_start (if any) will re-set them.
  ///
  /// IMPORTANT: The roll state has the player at the *destination* tile.
  /// We override the token position back to the pre-roll position so it
  /// doesn't visually snap to the target before the movement animation.
  void _handleRemoteRollEnd(
      int dice1, int dice2, Map<String, dynamic> state, Map<String, dynamic>? event) {
    if (!mounted) return;
    _lastDiceResult = {'dice1': dice1, 'dice2': dice2};

    // Keep the active player's token at the pre-roll position until
    // move_start begins the hop animation.
    final activeIdx = (state['active_player_index'] as num?)?.toInt() ?? 0;
    final preRollPos = _gameState.players.isNotEmpty &&
            activeIdx < _gameState.players.length
        ? _gameState.players[activeIdx].tileId
        : null;
    final overrides = preRollPos != null
        ? {activeIdx: preRollPos}
        : <int, String>{};

    setState(() {
      _animDice1 = dice1;
      _animDice2 = dice2;
      _currentState = state;
      _gameState = _buildGameState(
        state,
        lastEvent: 'Rolled $dice1 + $dice2',
        diceResult: {'dice1': dice1, 'dice2': dice2},
        positionOverrides: overrides,
      );
      _isRollingDice = false;
      _isAnimating = false; // cleared here; move_start re-sets if movement follows
    });
  }

  // ── Two-phase movement animation protocol ────────────────────────────────
  // move_start → all clients begin token hop animation through the tile path
  // move_end   → all clients snap token to final position

  /// Broadcast that the active player's token has started moving.
  void _broadcastMoveStart(int playerIndex, List<String> tilePath) {
    final net = widget.networkService;
    if (net == null || !mounted) return;
    net.sendMessage({
      'type': 'move_start',
      'player_index': playerIndex,
      'tile_path': tilePath,
    });
  }

  /// Broadcast that the token has finished moving.
  void _broadcastMoveEnd() {
    final net = widget.networkService;
    if (net == null || !mounted) return;
    net.sendMessage({
      'type': 'move_end',
      'state': _currentState,
    });
  }

  /// Animate token hopping on a remote client (called when move_start arrives).
  Future<void> _handleRemoteMoveStart(
      int playerIndex, List<dynamic> tilePath) async {
    if (!mounted || tilePath.isEmpty) return;
    for (var i = 0; i < tilePath.length; i++) {
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;
      setState(() {
        _animatedPositions[playerIndex] = tilePath[i] as String;
        _gameState = _buildGameState(
          _currentState,
          lastEvent: 'Token moving…',
          positionOverrides: Map.of(_animatedPositions),
        );
      });
    }
    // Keep _isAnimating true until move_end clears it
  }

  /// Finalize movement on a remote client (called when move_end arrives).
  void _handleRemoteMoveEnd(Map<String, dynamic>? state) {
    if (!mounted) return;
    setState(() {
      if (state != null) {
        _currentState = state;
        _gameState = _buildGameState(state, lastEvent: 'Movement done');
      }
      _animatedPositions.clear();
      _isAnimating = false;
    });
  }

  /// After executing a game action, sync the resulting state to network peers.
  ///
  /// - **Host**: broadcasts to all connected clients.
  /// - **Client**: sends state to the host, which updates itself and rebroadcasts
  ///   to all other clients.
  ///
  /// This ensures every node in the session sees the same authoritative state.
  void _syncAfterAction(BridgeResponse response) {
    final net = widget.networkService;
    if (net == null || !mounted) return;
    debugPrint('[NetSync] Syncing after action (isHost: ${net.isHost})');
    net.sendMessage({
      'type': 'state_sync',
      'state': response.state,
      'event': response.event,
    });
  }

  /// Sync the current local state to network peers without a BridgeResponse.
  /// Used after tile-effect resolution that modifies state directly in Dart.
  void _syncCurrentState({String eventType = 'TileEffect'}) {
    final net = widget.networkService;
    if (net == null || !mounted) return;
    net.sendMessage({
      'type': 'state_sync',
      'state': _currentState,
      'event': {'event_type': eventType},
    });
  }

  @override
  void dispose() {
    _netGameSub?.cancel();
    _networkService?.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  // ---- State builders ------------------------------------------------------

  /// Build the initial GameState JSON map for [numPlayers] players.
  /// [teamIds] assigns each player to a team (null = no team).
  Map<String, dynamic> _buildInitialState(int numPlayers, {List<String?>? teamIds}) {
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
        'team_id': teamIds != null && i < teamIds.length ? teamIds[i] : null,
      },
    );

    // Classic Monopoly property prices (tile_id → base_price)
    const prices = <String, int>{
      'prop_1': 60,   'prop_2': 60,
      'rr_1': 200,    'rr_2': 200,    'rr_3': 200,    'rr_4': 200,
      'prop_3': 100,  'prop_4': 100,  'prop_5': 120,
      'prop_6': 140,  'prop_7': 140,  'prop_8': 160,
      'prop_9': 180,  'prop_10': 180, 'prop_11': 200,
      'prop_12': 220, 'prop_13': 220, 'prop_14': 240,
      'prop_15': 260, 'prop_16': 260, 'prop_17': 280,
      'prop_18': 300, 'prop_19': 300, 'prop_20': 320,
      'prop_21': 350, 'prop_22': 400,
      'util_1': 150,  'util_2': 150,
    };
    // Color groups for group rent (tile_id → [linked_targets...])
    const groups = <String, List<String>>{
      'prop_1':  ['prop_2'],
      'prop_2':  ['prop_1'],
      'prop_3':  ['prop_4', 'prop_5'],
      'prop_4':  ['prop_3', 'prop_5'],
      'prop_5':  ['prop_3', 'prop_4'],
      'prop_6':  ['prop_7', 'prop_8'],
      'prop_7':  ['prop_6', 'prop_8'],
      'prop_8':  ['prop_6', 'prop_7'],
      'rr_1':    ['rr_2', 'rr_3', 'rr_4'],
      'rr_2':    ['rr_1', 'rr_3', 'rr_4'],
      'rr_3':    ['rr_1', 'rr_2', 'rr_4'],
      'rr_4':    ['rr_1', 'rr_2', 'rr_3'],
      'prop_9':  ['prop_10', 'prop_11'],
      'prop_10': ['prop_9', 'prop_11'],
      'prop_11': ['prop_9', 'prop_10'],
      'prop_12': ['prop_13', 'prop_14'],
      'prop_13': ['prop_12', 'prop_14'],
      'prop_14': ['prop_12', 'prop_13'],
      // prop_16 replaced by card_shop_1 — Yellow group now has 2 members
      'prop_15': ['prop_17'],
      'prop_17': ['prop_15'],
      'prop_18': ['prop_19', 'prop_20'],
      'prop_19': ['prop_18', 'prop_20'],
      'prop_20': ['prop_18', 'prop_19'],
      'prop_21': ['prop_22'],
      'prop_22': ['prop_21'],
    };

    // Build properties from tiles using classic pricing
    final properties = <Map<String, dynamic>>[];
    for (final tile in tileSource) {
      final tid = tile['id'];
      final price = prices[tid] ?? 0;
      if (tile['kind'] == 'OrdinaryProperty' && price > 0) {
        properties.add({
          'tile_id': tid,
          'name_key': 'prop.$tid',
          'kind': 'Ordinary',
          'base_price': price,
          'rent': <int>[],
          'upgrade_level': 0,
          'owner': null,
          'is_mortgaged': false,
          'linked_targets': groups[tid] ?? <String>[],
        });
      } else if (tile['kind'] == 'ExtensionProperty' && price > 0) {
        properties.add({
          'tile_id': tid,
          'name_key': 'prop.$tid',
          'kind': 'Extension',
          'base_price': price,
          'rent': <int>[],
          'upgrade_level': 0,
          'owner': null,
          'is_mortgaged': false,
          'linked_targets': <String>[],
        });
      }
    }

    // ── Auto-link rent for the complex L‑shaped board ────────────
    if (_useComplexBoard) {
      _computeAutoLinks(
        tileSource,
        properties,
        _complexPositions,
      );
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
      'max_upgrade_level': 3,
      'extension_upgrade_enabled': true,
      'group_rent_enabled': true,
      'lottery_state': null,
      'bail_abuse_count': 0,
    };
  }

  /// Auto-link rent computation — split by board edges first.
  ///
  /// Rule 1: groups only form within the same board edge (same direction).
  /// We split the path at direction changes (detected via grid positions),
  /// then process each edge independently.
  void _computeAutoLinks(
      List<Map<String, String>> tileSource,
      List<Map<String, dynamic>> properties,
      List<(int, int)> positions) {
    bool isProp(int ti) =>
        ti < tileSource.length &&
        properties.any((p) => p['tile_id'] == tileSource[ti]['id']);

    final manual = properties
        .where((p) => (p['linked_targets'] as List).isNotEmpty)
        .map((p) => p['tile_id'] as String)
        .toSet();

    // ── 0. Split path into edges at direction changes ──────────
    // A direction change occurs when (Δrow, Δcol) differs between
    // consecutive tile pairs.
    final edges = <List<int>>[]; // each edge is a list of tile indices
    if (positions.length < 2) return;

    var currentEdge = <int>[0];
    for (int i = 1; i < positions.length; i++) {
      final pr = positions[i - 1].$1, pc = positions[i - 1].$2;
      final cr = positions[i].$1, cc = positions[i].$2;
      final dr = cr - pr, dc = cc - pc;

      if (i < positions.length - 1) {
        final nr = positions[i + 1].$1, nc = positions[i + 1].$2;
        final ndr = nr - cr, ndc = nc - cc;
        if (ndr != dr || ndc != dc) {
          // Direction changes at tile i → end current edge here
          currentEdge.add(i);
          edges.add(List.from(currentEdge));
          currentEdge = <int>[i];
          continue;
        }
      }
      currentEdge.add(i);
    }
    if (currentEdge.isNotEmpty) edges.add(currentEdge);

    // ── 1..3. Process each edge independently ───────────────────
    for (final edge in edges) {
      final edgeRuns = <List<String>>[];

      // Find contiguous property runs within this edge
      int ei = 0;
      while (ei < edge.length) {
        final ti = edge[ei];
        final tid = tileSource[ti]['id']!;
        if (!isProp(ti) || manual.contains(tid)) {
          ei++;
          continue;
        }
        final run = <String>[tid];
        ei++;
        while (ei < edge.length) {
          final nti = edge[ei];
          final nid = tileSource[nti]['id']!;
          if (!isProp(nti) || manual.contains(nid)) break;
          run.add(nid);
          ei++;
        }
        if (run.isNotEmpty) edgeRuns.add(run);
      }

      // Merge runs within this edge (gap=1, total≥3)
      final merged = <List<String>>[];
      int ri = 0;
      while (ri < edgeRuns.length) {
        final cluster = <String>[...edgeRuns[ri]];
        ri++;
        while (ri < edgeRuns.length) {
          final lastId = cluster.last;
          final nextId = edgeRuns[ri].first;
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
          final total = cluster.length + edgeRuns[ri].length;
          if (gap != 1 || total < 3) break;
          cluster.addAll(edgeRuns[ri]);
          ri++;
        }
        merged.add(cluster);
      }

      // Set linked_targets (max 5)
      for (final group in merged) {
        final g = group.length > 5 ? group.sublist(0, 5) : group;
        if (g.length < 2) continue;
        for (final tid in g) {
          final prop = properties.firstWhere(
            (p) => p['tile_id'] == tid,
            orElse: () => <String, dynamic>{},
          );
          if (prop.isNotEmpty) {
            prop['linked_targets'] = g.where((id) => id != tid).toList();
          }
        }
      }
    }
  }

  /// Build a [GameStateData] from a raw state JSON map.
  /// Optionally override player tile positions (used during animation).
  /// Restore display names on tiles that lost them during Rust engine round-trip
  /// (Rust's `Tile` only has `name_key`, not `name`).
  void _injectTileNames(Map<String, dynamic> rawState) {
    final tiles = (rawState['board'] as Map<String, dynamic>?)?
        ['tiles'] as List<dynamic>?;
    if (tiles == null) return;
    final names = _tileNames;
    for (final t in tiles) {
      if (t is Map<String, dynamic>) {
        final id = t['id'] as String?;
        if (id != null && t['name'] == null) {
          t['name'] = names[id] ?? id;
        }
      }
    }
  }

  GameStateData _buildGameState(Map<String, dynamic> rawState,
      {String lastEvent = '', Map<String, int> diceResult = const {},
      Map<int, String>? positionOverrides}) {
    _injectTileNames(rawState);
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
    // 1. Broadcast roll_start to all peers immediately
    _broadcastRollStart();

    // 2. Start local dice animation (shows random faces until roll_end)
    setState(() {
      _isRollingDice = true;
      _isAnimating = true;
    });

    // 3. Execute FFI command to get authoritative dice values
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.roll(),
      currentState: _currentState,
    );

    final eventType = response.event['event_type'] as String? ?? '';

    // Hospital: skip without dice
    if (eventType == 'CommandRejected') {
      final reason = response.event['reason'] as String? ?? '';
      if (reason == 'player_in_hospital') {
        setState(() {
          _currentState = response.state;
          _gameState = _buildGameState(
            response.state,
            lastEvent: 'In hospital (skip turn)',
          );
          _isRollingDice = false;
          _isAnimating = false;
        });
        _broadcastRollEnd(0, 0, response);
        _addLog('In hospital — turn skipped');
        return;
      }
    }

    // Read dice values from the response event
    final dice1 = (response.event['dice1'] as num?)?.toInt() ?? 0;
    final dice2 = (response.event['dice2'] as num?)?.toInt() ?? 0;
    final steps = dice1 + dice2;
    final is_seven = dice1 + dice2 == 7;

    // Detect jail-specific events:
    final isJailStillLocked =
        eventType == 'DiceRolled' && response.event['consecutive'] == null;
    final isJailReleased = eventType == 'PlayerReleasedFromJail';
    final isJailRoll = isJailStillLocked || isJailReleased;

    // 4. Continue dice animation with known values (total ~8 frames)
    for (var i = 0; i < 8; i++) {
      await Future.delayed(const Duration(milliseconds: 60));
      if (!mounted) return;
      setState(() {
        _animDice1 = 1 + (i * 3 + 1) % 6;
        _animDice2 = 1 + (i * 7 + 3) % 6;
      });
    }

    // 5. Show final dice values briefly before applying state
    setState(() {
      _animDice1 = dice1;
      _animDice2 = dice2;
    });
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;

    // 6. Broadcast roll_end with the authoritative result
    _broadcastRollEnd(dice1, dice2, response);

    // 7. Apply final state locally (position already updated by engine).
    //    Override the token position back to pre-roll so it doesn't
    //    visually snap to the destination before the hop animation.
    final activeIdx = _gameState.activePlayerIndex;
    final currentPos = _gameState.players[activeIdx].tileId;
    final rawTiles = (_currentState['board'] as Map<String, dynamic>?)?
        ['tiles'] as List<dynamic>? ?? [];
    final currentTileIdx = rawTiles.indexWhere((t) => t['id'] == currentPos);

    final movementPath = <String>[];
    if (!isJailRoll && rawTiles.isNotEmpty) {
      for (var i = 1; i <= steps; i++) {
        final idx = (currentTileIdx + i) % rawTiles.length;
        movementPath.add(rawTiles[idx]['id'] as String);
      }
    }

    final jailMsg = isJailStillLocked
        ? ' (jail — need 7)'
        : isJailReleased
            ? ' (released from jail!)'
            : '';
    _lastDiceResult = {'dice1': dice1, 'dice2': dice2};
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: 'Rolled $dice1 + $dice2${isJailRoll ? '\n$jailMsg' : ''}',
        diceResult: {'dice1': dice1, 'dice2': dice2},
        positionOverrides: {activeIdx: currentPos},
      );
      _isRollingDice = false;
      // Keep _isAnimating for the movement phase below
    });
    _addLog('Rolled $dice1 + $dice2 = ${dice1 + dice2}$jailMsg');

    // Skip tile effect + movement when stuck in jail (player didn't move).
    if (isJailRoll) {
      _isAnimating = false;
      return;
    }

    // ── 8. Movement animation (two-phase: move_start → hop → move_end) ──────
    if (movementPath.isNotEmpty) {
      _broadcastMoveStart(activeIdx, movementPath);
      _isAnimating = true;
      for (var i = 0; i < movementPath.length; i++) {
        await Future.delayed(const Duration(milliseconds: 150));
        if (!mounted) return;
        setState(() {
          _animatedPositions[activeIdx] = movementPath[i];
          _gameState = _buildGameState(
            _currentState,
            positionOverrides: Map.of(_animatedPositions),
          );
        });
      }
      _animatedPositions.clear();
      _broadcastMoveEnd();
    }
    _isAnimating = false;
    setState(() {}); // refresh UI after animating

    // 9. Resolve special tile effects
    final playerPos =
        _currentState['players'][_gameState.activePlayerIndex]['position'];
    await _resolveTileEffect(playerPos);
    // Sync tile-effect changes (tax, chance card, jail, etc.) to peers
    _syncCurrentState(eventType: 'TileEffect');

    // Record which tile the player just landed on (buy/upgrade only allowed
    // on the turn they first arrive).
    _landedTileIdThisTurn = playerPos;

    // Decrement rolls remaining; if sum of two dice equals 7, grant re-roll
    _rollsRemainingThisTurn--;
    final diceSum = dice1 + dice2;
    if (diceSum == 7) {
      _rollsRemainingThisTurn++;
      _addLog('Rolled 7! Extra roll granted.');
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
    final eventType = response.event['event_type'] as String? ?? '';
    final accepted = eventType == 'CardBought';
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: accepted ? 'Bought $cardId' : 'Purchase rejected',
      );
    });
    _syncAfterAction(response);
    if (accepted) {
      _addLog('Bought card: $cardId');
    } else {
      final reason = response.event['reason'] as String? ?? 'unknown';
      _addLog('Card purchase rejected: $reason');
    }
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
    _syncAfterAction(response);
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
    _syncAfterAction(response);
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

  /// Save the current game state to disk.
  Future<void> _onSaveGame() async {
    final name = await _saveManager.saveGame(state: _currentState);
    if (!mounted) return;
    if (name != null) {
      _addLog('Game saved: $name');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('游戏已保存: $name'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('保存失败'),
            backgroundColor: Colors.redAccent,
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Exit to home screen with confirmation.
  Future<void> _onExitToHome() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('返回主菜单'),
        content: const Text('确定要退出当前游戏吗？未保存的进度将丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    }
  }

  Future<void> _onEndTurn() async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.endTurn(),
      currentState: _currentState,
    );
    _lastDiceResult = {}; // Clear dice display on turn end
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: 'Turn ended',
      );
      _rollsRemainingThisTurn = 1;
      _landedTileIdThisTurn = null;
    });
    _syncAfterAction(response);
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
    _syncAfterAction(response);
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
    _syncAfterAction(response);
    _addLog('Player upgraded $tileId');
  }

  /// Show a detailed property information dialog using state-based overlay.
  void _showPropertyDetailDialog(String tileId) {
    setState(() {
      _detailTileId = tileId;
    });
  }

  /// Build the property detail overlay widget (used in the build method).
  Widget _buildPropertyOverlay() {
    final tileId = _detailTileId;

    final rawTiles = (_currentState['board'] as Map<String, dynamic>?)?
            ['tiles'] as List<dynamic>? ??
        [];
    final tileIdx = tileId != null
        ? rawTiles.indexWhere((t) => t['id'] == tileId)
        : 0;
    final tileData = tileIdx >= 0
        ? rawTiles[tileIdx] as Map<String, dynamic>
        : <String, dynamic>{};
    // After a Rust engine round-trip, the `name` field is stripped (Rust's Tile
    // only has `name_key`). Fall back to _tileNames for a human-readable label.
    final tileName = (tileData['name'] as String?) ??
        _tileNames[tileId ?? ''] ??
        tileId ??
        '';
    final tileKind = (tileData['kind'] as String?) ?? '';

    final properties = (_currentState['board'] as Map<String, dynamic>?)?
            ['properties'] as List<dynamic>? ??
        [];
    final propIdx = properties.indexWhere(
        (p) => (p as Map<String, dynamic>)['tile_id'] == tileId);
    final propData = propIdx >= 0
        ? properties[propIdx] as Map<String, dynamic>
        : <String, dynamic>{};
    final isProperty = propData.isNotEmpty;

    final ownerId = isProperty ? propData['owner'] as String? : null;
    String ownerLabel;
    Color ownerColor;
    if (ownerId != null) {
      final playerIdx = int.tryParse(ownerId.replaceAll('player_', '')) ?? 0;
      const colors = [
        Color(0xFFD32F2F), Color(0xFF1976D2), Color(0xFF388E3C),
        Color(0xFFFBC02D), Color(0xFF8E24AA), Color(0xFFFF6F00),
      ];
      ownerColor = colors[playerIdx % colors.length];
      final players = _gameState.players;
      ownerLabel = playerIdx < players.length
          ? players[playerIdx].name
          : 'Player $playerIdx';
    } else {
      ownerColor = Colors.grey;
      ownerLabel = isProperty ? 'Unowned' : 'N/A';
    }

    final level =
        isProperty ? ((propData['upgrade_level'] as num?)?.toInt() ?? 0) : 0;
    final basePrice =
        isProperty ? ((propData['base_price'] as num?)?.toInt() ?? 0) : 0;
    // Rent is always derived from base_price (formula: base_price * (1+level) / 10).
    // The separate `rent[]` array in map data is ignored for calculation; it exists
    // only for backward compatibility.
    final currentRent = basePrice * (1 + level) ~/ 10;
    int groupRent = 0;
    int groupCount = 1;
    final linkedTargets = isProperty
        ? (propData['linked_targets'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            <String>[]
        : <String>[];
    if (_currentState['group_rent_enabled'] == true &&
        linkedTargets.isNotEmpty && ownerId != null) {
      groupCount = 1;
      for (final target in linkedTargets) {
        final tIdx = properties.indexWhere(
            (p) => (p as Map<String, dynamic>)['tile_id'] == target);
        if (tIdx < 0) continue;
        final tp = properties[tIdx] as Map<String, dynamic>;
        if (tp['owner'] == ownerId) {
          final tl = (tp['upgrade_level'] as num?)?.toInt() ?? 0;
          final tb = (tp['base_price'] as num?)?.toInt() ?? 0;
          groupRent += tb * (1 + tl) ~/ 10;
          groupCount++;
        }
      }
      groupRent += currentRent;
    }
    // Upgrade cost formula: base_price * (1 + level) / 3
    final upgradeCost = basePrice * (1 + level) ~/ 3;
    final maxLevel =
        (_currentState['max_upgrade_level'] as num?)?.toInt() ?? 3;
    final canUpgrade = ownerId != null && level < maxLevel;

    Color tileColor;
    try {
      tileColor = BoardTileViewModel(id: tileId ?? '', name: tileName, kind: tileKind).color;
    } catch (_) {
      tileColor = Colors.grey;
    }

    return Material(
      color: Colors.black54,
      child: Center(
        child: GestureDetector(
          onTap: () => setState(() => _detailTileId = null),
          child: AlertDialog(
            title: Row(children: [
              Container(
                width: 14, height: 14,
                decoration: BoxDecoration(
                  color: tileColor,
                  shape: BoxShape.rectangle,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(tileName,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailRow('Type', tileKind),
                const Divider(height: 10),
                if (isProperty) ...[
                  _detailRow('Owner', ownerLabel,
                      valueColor: ownerId != null ? ownerColor : null),
                  _detailRow('Level', level > 0 ? '$level ★' : '0 (base)'),
                  const Divider(height: 10),
                  _detailRow('Base Price', '\$$basePrice'),
                  _detailRow('Rent (current)', '\$$currentRent',
                      valueColor: Colors.red.shade700),
                  if (groupRent > 0)
                    _detailRow('Group Rent (×$groupCount)',
                        '\$$groupRent', valueColor: Colors.deepOrange),
                  const Divider(height: 10),
                  _detailRow('Upgrade Cost',
                      canUpgrade ? '\$$upgradeCost' : 'Max level',
                      valueColor: canUpgrade ? Colors.green.shade700 : Colors.grey),
                  if (linkedTargets.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    const Text('Linked group:',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    ...linkedTargets.map((t) {
                      final tIdx = rawTiles.indexWhere((x) => x['id'] == t);
                      final td = tIdx >= 0 ? rawTiles[tIdx] as Map<String, dynamic> : null;
                      return Padding(
                        padding: const EdgeInsets.only(left: 12, bottom: 1),
                        child: Text('• ${td?['name'] ?? t}',
                            style: const TextStyle(fontSize: 12)),
                      );
                    }),
                  ],
                ] else ...[
                  _detailRow('Owner', 'N/A'),
                  const SizedBox(height: 4),
                  const Text('This tile is not a purchasable property.',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => setState(() => _detailTileId = null),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: valueColor ?? Colors.black87)),
          ),
        ],
      ),
    );
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
    // upgrade_cost = base_price * (1 + current_level) / 3
    final cost = basePrice * (1 + currentLevel) ~/ 3;
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

  /// Build a lookup map of tile_id → display name from the initial tile source.
  /// Needed because the Rust `Tile` struct only has `name_key`, not `name`.
  Map<String, String> get _tileNames {
    final tileSource = _useComplexBoard ? _complexTiles : _defaultTiles;
    final map = <String, String>{};
    for (final t in tileSource) {
      map[t['id']!] = t['name']!;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final activePlayer =
        _gameState.players.isNotEmpty &&
                _gameState.activePlayerIndex < _gameState.players.length
            ? _gameState.players[_gameState.activePlayerIndex]
            : null;

    final tileNames = _tileNames;

    // Convert raw tiles to BoardTileViewModel for the board
    final rawTiles = (_currentState['board'] as Map<String, dynamic>?)?
            ['tiles'] as List<dynamic>? ??
        [];
    final tiles = rawTiles
        .map((t) {
          final id = t['id'] as String;
          // Prefer the original display name from the tile source; fall back
          // to name_key or id when Rust strips the 'name' field after round-trip.
          final displayName = t['name'] as String? ??
              tileNames[id] ??
              t['name_key'] as String? ??
              id;
          return BoardTileViewModel(
            id: id,
            name: displayName,
            kind: t['kind'] as String? ?? 'Unknown',
          );
        })
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
      child: Stack(
        children: [
          Scaffold(
        appBar: AppBar(
          title: const Text('saMonopoly'),
          actions: [
            // Save game
            IconButton(
              icon: const Icon(Icons.save_rounded),
              tooltip: '保存游戏',
              onPressed: _onSaveGame,
            ),
            IconButton(
              icon: const Icon(Icons.home_rounded),
              tooltip: '返回主菜单',
              onPressed: _onExitToHome,
            ),
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
                        onTileTap: (result) => _showPropertyDetailDialog(result.tileId),
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
      // Pre-warm all dialog widget trees at startup via Offstage.
      // This eliminates first-tap rendering delay for dialogs.
      Offstage(
        offstage: _detailTileId == null,
        child: _buildPropertyOverlay(),
      ),
      // Trade dialog pre-warm
      Offstage(
        offstage: true,
        child: AlertDialog(
          title: const Text('Trade'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text('Select a player and offer:'),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    title: Text('With ${_gameState.players.isNotEmpty ? _gameState.players[0].name : ''}'),
                    subtitle: TextField(
                      controller: TextEditingController(),
                      decoration: const InputDecoration(
                        labelText: 'Cash offer',
                        prefixText: '\$',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: null, child: const Text('Cancel')),
            FilledButton(onPressed: null, child: const Text('Propose Trade')),
          ],
        ),
      ),
    ],
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
    // Use animated values during rolling, otherwise use persistent dice result
    final dice1 = _isRollingDice ? _animDice1 : (_lastDiceResult['dice1'] ?? 0);
    final dice2 = _isRollingDice ? _animDice2 : (_lastDiceResult['dice2'] ?? 0);
    final show = _isRollingDice || _lastDiceResult.isNotEmpty;
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
    final canAct = _isLocalPlayersTurn && !_isAnimating;
    final canRoll = canAct && _rollsRemainingThisTurn > 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: canRoll ? _onRoll : null,
          icon: const Icon(Icons.casino, size: 18),
          label: Text(_rollsRemainingThisTurn > 1
              ? 'Roll ($_rollsRemainingThisTurn)'
              : 'Roll'),
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: canAct ? () => _showTradeDialog() : null,
          icon: const Icon(Icons.swap_horiz, size: 18),
          label: const Text('Trade'),
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: canAct ? () => _showCardInventoryDialog() : null,
          icon: const Icon(Icons.inventory_2, size: 18),
          label: const Text('Inventory'),
        ),
        const SizedBox(height: 4),
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
  bool _extensionUpgradeEnabled = true;
  bool _groupRentEnabled = true;
  bool _stockMarketEnabled = true;
  bool _lotteryEnabled = true;
  bool _auctionEnabled = true;
  bool _mortgageEnabled = true;
  bool _tradeEnabled = true;

  // ── Network config controllers ───────────────────────────────────────────
  late TextEditingController _hostCtrl;
  late TextEditingController _portCtrl;
  bool _tlsEnabled = true;

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
