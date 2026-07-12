import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

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
import 'game_constants.dart';
import 'isometric_board.dart';
import 'lottery_dialog.dart';
import 'plugin_state.dart';
import 'event_dispatcher.dart';

// ============================================================================
// Event log entry types
// ============================================================================

/// A single event log entry with visual metadata (icon, color).
class EventLogEntry {
  final String message;
  final String category;

  const EventLogEntry(this.message, {this.category = 'system'});

  static const _iconMap = <String, IconData>{
    'roll': Icons.casino,
    'move': Icons.directions_walk,
    'money': Icons.attach_money,
    'property': Icons.home,
    'card': Icons.style,
    'jail': Icons.lock,
    'hospital': Icons.local_hospital,
    'turn': Icons.repeat,
    'trade': Icons.swap_horiz,
    'auction': Icons.gavel,
    'win': Icons.emoji_events,
    'bankrupt': Icons.money_off,
    'system': Icons.info_outline,
  };

  static const _colorMap = <String, Color>{
    'roll': Color(0xFFFF9800),
    'move': Color(0xFF2196F3),
    'money': Color(0xFF4CAF50),
    'property': Color(0xFF9C27B0),
    'card': Color(0xFFE91E63),
    'jail': Color(0xFFF44336),
    'hospital': Color(0xFFFF5722),
    'turn': Color(0xFF9E9E9E),
    'trade': Color(0xFF00BCD4),
    'auction': Color(0xFFFF6F00),
    'win': Color(0xFFFFD700),
    'bankrupt': Color(0xFF795548),
    'system': Color(0xFFB0BEC5),
  };

  IconData get icon => _iconMap[category] ?? Icons.info_outline;
  Color get color => _colorMap[category] ?? const Color(0xFFB0BEC5);

  /// Infer category from common event message patterns.
  static String inferCategory(String msg) {
    if (msg.startsWith('Rolled')) return 'roll';
    if (msg.startsWith('moved') || msg.startsWith('player_')) return 'move';
    if (msg.contains('tax') || msg.contains('bonus') || msg.contains('paid') || msg.contains('bail') || msg.contains('rent')) return 'money';
    if (msg.startsWith('Bought') || msg.startsWith('Upgraded') || msg.startsWith('Mortgaged') || msg.startsWith('Redeemed')) return 'property';
    if (msg.contains('card') || msg.contains('Card') || msg.contains('Drew')) return 'card';
    if (msg.contains('jail') || msg.contains('Jail')) return 'jail';
    if (msg.contains('hospital') || msg.contains('Hospital')) return 'hospital';
    if (msg.startsWith('Turn')) return 'turn';
    if (msg.contains('trade') || msg.contains('Trade')) return 'trade';
    if (msg.contains('auction') || msg.contains('Auction')) return 'auction';
    if (msg.contains('win') || msg.contains('Win') || msg.contains('won')) return 'win';
    if (msg.contains('bankrupt') || msg.contains('Bankrupt')) return 'bankrupt';
    return 'system';
  }
}

// ============================================================================
// Game state management (simple InheritedWidget)
// ============================================================================

/// Top-level game state exposed through the widget tree.
class GameStateData {
  final List<PlayerTokenViewModel> players;
  final Map<String, dynamic> rawState;
  final String lastEvent;
  final List<EventLogEntry> eventLog;
  final Map<String, int> diceResult;
  /// Plugin activity messages (shown in purple in the event log)
  final List<String> pluginMessages;

  const GameStateData({
    this.players = const [],
    this.rawState = const {},
    this.lastEvent = '',
    this.eventLog = const [],
    this.diceResult = const {},
    this.pluginMessages = const [],
  });

  GameStateData copyWith({
    List<PlayerTokenViewModel>? players,
    Map<String, dynamic>? rawState,
    String? lastEvent,
    List<EventLogEntry>? eventLog,
    Map<String, int>? diceResult,
    List<String>? pluginMessages,
  }) {
    return GameStateData(
      players: players ?? this.players,
      rawState: rawState ?? this.rawState,
      lastEvent: lastEvent ?? this.lastEvent,
      eventLog: eventLog ?? this.eventLog,
      diceResult: diceResult ?? this.diceResult,
      pluginMessages: pluginMessages ?? this.pluginMessages,
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

  /// Whether the local player is currently executing a roll locally (via _onRoll).
  /// Used to guard against rebroadcast echo in _handleRemoteRollEnd.
  /// Unlike _isRollingDice, this is ONLY set by _onRoll, not by _handleRemoteRollStart,
  /// so remote roll_end messages are still processed correctly.
  bool _isRollInProgress = false;

  /// When non-null, the property detail overlay is shown for this tile.
  /// Using state-based overlay instead of showDialog for instant response.
  String? _detailTileId;

  /// Deferred roll log message for client-side animation sync.
  /// Stored during `roll_end` and shown after `move_end` completes.
  List<String>? _pendingRollLogs;

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

  final SaveManager _saveManager = SaveManager();

  @override
  void initState() {
    super.initState();
    // Attach Rust engine to PluginState for real enable/disable
    PluginState().attachEngine(_bridgeClient.engine);
    // Load game constants from Rust engine (if available)
    GameConstants.load(_bridgeClient);
    _pack = sampleClassicPack();

    // Map selection: 'classic' uses the 40-tile board, 'complex' uses
    // the complex L-shaped test board for development/testing.
    // All other maps (e.g. 'all_owned') use the classic 40-tile layout.
    _useComplexBoard = widget.mapId == 'complex';

    _networkService = widget.networkService;

    // ────────────────────────────────────────────────────────────────────────
    // Network mode: host or client
    // ────────────────────────────────────────────────────────────────────────
    if (widget.networkService != null) {
      final net = widget.networkService!;

      // Subscribe to network messages
      _netGameSub = net.messages.listen(_onNetworkMessage);

      // Register event subscribers for UI-trigger events (MUST be before any
      // roll command, regardless of host/client mode).
      _registerEventSubscriptions();

      if (net.isHost) {
        // ── Host: build state locally, broadcast game_start ────────────
        if (widget.initialState != null) {
          _currentState = Map<String, dynamic>.from(widget.initialState!);
        } else {
          _currentState = {};
          // Async init via Rust
          Future.microtask(() => _initGameFromRust());
        }
      } else {
        // ── Client: wait for game_start from host ──────────────────────
        _landedTileIdThisTurn = null;
        if (widget.initialState != null) {
          _currentState = Map<String, dynamic>.from(widget.initialState!);
          _gameState = _buildGameState(_currentState, lastEvent: 'Game started (client)');
          _addLog('Game started (client mode)');
        } else {
          _currentState = {};
          _gameState = const GameStateData();
          _addLog('Waiting for host to start game...');
        }
      }
      return;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Offline mode
    // ────────────────────────────────────────────────────────────────────────
    if (widget.initialState != null) {
      // ── Load from save ──────────────────────────────────────────────
      _currentState = Map<String, dynamic>.from(widget.initialState!);
      _gameState = _buildGameState(_currentState, lastEvent: 'Game restored');
      _landedTileIdThisTurn = null;
      final mapLabel = _useComplexBoard ? 'Complex L‑board' : 'Classic';
      _addLog('Game restored from save ($mapLabel) with ${_gameState.numPlayers} players');
    } else {
      // ── Fresh game via Rust engine ──────────────────────────────────
      _currentState = {};
      _gameState = const GameStateData();
      Future.microtask(() => _initGameFromRust());

      final mapLabel = _useComplexBoard ? 'Complex L‑board' : 'Classic';
      _addLog('Game started ($mapLabel) with ${_gameState.numPlayers} players');
    }

    // Register event subscribers for UI-trigger events
    _registerEventSubscriptions();
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
        // Skip if we are the roller (host processes via _onRoll directly)
        if (_isRollInProgress) break;
        final dice1 = (message['dice1'] as num?)?.toInt() ?? 0;
        final dice2 = (message['dice2'] as num?)?.toInt() ?? 0;
        final state = message['state'] as Map<String, dynamic>?;
        final event = message['event'] as Map<String, dynamic>?;
        final rollLogs = (message['action_logs'] as List<dynamic>?)?.cast<String>();
        if (state != null) {
          if (isHost) {
            // Host: add roll logs from client immediately (client will also
            // get them via relay on move_end, but host needs them now).
            if (rollLogs != null) {
              for (final log in rollLogs) { _addLog(log); }
            }
            _handleRemoteRollEnd(dice1, dice2, state, event);
            _networkService?.sendMessage(message);
          } else {
            // Client: defer ALL logs until movement animation completes
            _pendingRollLogs = rollLogs;
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
            // Skip rebroadcast echo if we are the roller (already animating
            // locally via _onRoll). Use _isRollInProgress to distinguish
            // local roll from remote roll — _isAnimating is now kept true
            // from roll_start through roll_end when movement follows.
            if (!_isRollInProgress) {
              _handleRemoteMoveStart(playerIdx, tilePath);
            }
          }
        }
        break;

      case 'move_end':
        // Skip if we are the roller (host processes via _onRoll directly)
        if (_isRollInProgress) break;
        final moveState = message['state'] as Map<String, dynamic>?;
        // Client: show ALL deferred roll logs after movement animation completes.
        if (!isHost && _pendingRollLogs != null) {
          for (final log in _pendingRollLogs!) { _addLog(log); }
          _pendingRollLogs = null;
        }
        _handleRemoteMoveEnd(moveState);
        if (isHost) {
          _networkService?.sendMessage(message);
        }
        break;

      // ── State sync for non-roll actions ────────────────────────────────
      case 'state_sync':
        final state = message['state'] as Map<String, dynamic>?;
        final event = message['event'] as Map<String, dynamic>?;
        final actionLogs = (message['action_logs'] as List<dynamic>?)?.cast<String>();
        final msgId = message['_msg_id'] as String?;
        // Deduplicate: skip if we've already processed this message (relay echo)
        if (msgId != null && _processedStateSyncIds.contains(msgId)) break;
        if (msgId != null) _processedStateSyncIds.add(msgId);

        if (state != null) {
          // Replay all action logs so all peers see the same messages
          if (actionLogs != null) {
            for (final log in actionLogs) { _addLog(log); }
          }

          final lastLog = (actionLogs != null && actionLogs.isNotEmpty)
              ? actionLogs.last
              : 'State synced';

          if (isHost) {
            // ── Host received state from a client ─────────────────────
            setState(() {
              _currentState = state;
              _gameState = _buildGameState(state, lastEvent: lastLog);
            });
            // Rebroadcast to all other clients (keep action_log + same msg_id)
            _networkService?.sendMessage({
              'type': 'state_sync',
              'state': state,
              'event': event,
              if (actionLogs != null) 'action_logs': actionLogs,
              '_msg_id': msgId,
            });
          } else {
            // ── Client received state from host ───────────────────────
            setState(() {
              _currentState = state;
              _gameState = _buildGameState(state, lastEvent: lastLog);
            });
          }
        }
        break;
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
  /// [actionLogs] is the list of log messages to sync to all peers.
  void _broadcastRollEnd(int dice1, int dice2, BridgeResponse response, {List<String>? actionLogs}) {
    final net = widget.networkService;
    if (net == null || !mounted) return;
    net.sendMessage({
      'type': 'roll_end',
      'dice1': dice1,
      'dice2': dice2,
      'state': response.state,
      'event': response.event,
      if (actionLogs != null) 'action_logs': actionLogs,
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
  /// Keeps _isAnimating true if movement will follow; clears it for jail rolls
  /// or rejected rolls (no movement phase).
  ///
  /// IMPORTANT: The roll state has the player at the *destination* tile.
  /// We override the token position back to the pre-roll position so it
  /// doesn't visually snap to the target before the movement animation.
  void _handleRemoteRollEnd(
      int dice1, int dice2, Map<String, dynamic> state, Map<String, dynamic>? event) {
    if (!mounted) return;
    // Ignore rebroadcast echo if we are currently executing a local roll.
    // This prevents the host's relay from overwriting our animation state.
    // NOTE: We use _isRollInProgress (not _isRollingDice) because _isRollingDice
    // is also set by _handleRemoteRollStart for remote dice animations.
    if (_isRollInProgress) return;
    _lastDiceResult = {'dice1': dice1, 'dice2': dice2};

    // Determine whether a movement animation will follow.
    // Movement is skipped when:
    // 1. The roll was rejected (e.g. player in hospital, already rolled).
    // 2. The player is in jail (jail roll to try to escape — no token move).
    final activeIdx = (state['active_player_index'] as num?)?.toInt() ?? 0;
    final eventType = event?['event_type'] as String? ?? '';
    final isRejected = eventType == 'core:command_rejected';
    final playersList = state['players'] as List<dynamic>? ?? [];
    final jailTurns = activeIdx < playersList.length
        ? ((playersList[activeIdx] as Map<String, dynamic>)['jail_turns'] as num?)?.toInt() ?? 0
        : 0;
    final isInJail = jailTurns > 0;
    final hasMovement = !isRejected && !isInJail;

    // Keep the active player's token at the pre-roll position until
    // move_start begins the hop animation.
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
      // Only clear animation flag when no movement will follow (jail/rejected).
      // Otherwise keep _isAnimating=true so the Roll button stays disabled
      // until move_end arrives.
      if (!hasMovement) {
        _isAnimating = false;
      }
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
    setState(() {
      _isAnimating = true; // Keep Roll button disabled during movement
    });
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
    // _isAnimating stays true; move_end will clear it
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

  /// Monotonically increasing counter for state_sync message IDs.
  int _stateSyncCounter = 0;
  /// Set of processed state_sync message IDs (deduplication for relay echoes).
  final Set<String> _processedStateSyncIds = {};

  /// After executing a game action, sync the resulting state to network peers.
  /// [actionLogs] is the list of log messages so all peers see the same logs.
  void _syncAfterAction(BridgeResponse response, {List<String>? actionLogs}) {
    final net = widget.networkService;
    if (net == null || !mounted) return;
    _stateSyncCounter++;
    // Prefix with isHost to avoid ID collisions between host and client
    // (both start counting from 1 independently).
    final prefix = net.isHost ? 'h' : 'c';
    final msgId = '${prefix}s$_stateSyncCounter';
    _processedStateSyncIds.add(msgId);
    net.sendMessage({
      'type': 'state_sync',
      'state': response.state,
      'event': response.event,
      if (actionLogs != null) 'action_logs': actionLogs,
      '_msg_id': msgId,
    });
  }

  /// Sync the current local state to network peers without a BridgeResponse.
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
    final entry = EventLogEntry(message, category: EventLogEntry.inferCategory(message));
    final updatedLog = List<EventLogEntry>.from(_gameState.eventLog)
      ..insert(0, entry);
    // Detect plugin messages and add to pluginMessages list
    List<String> updatedPluginMsgs = List.from(_gameState.pluginMessages);
    if (message.startsWith('[DiceStats]') || message.startsWith('[TreasureHunt]')) {
      updatedPluginMsgs.insert(0, message);
      if (updatedPluginMsgs.length > 20) updatedPluginMsgs.removeLast();
    }
    if (mounted) {
      setState(() {
        _gameState = _gameState.copyWith(
          eventLog: updatedLog,
          pluginMessages: updatedPluginMsgs,
        );
      });
    }
  }

  // ---- Game initialisation via Rust engine ---------------------------------

  /// Load map JSON from assets and send `create_game` to Rust.
  /// On success, updates `_currentState` and `_gameState`.
  Future<void> _initGameFromRust() async {
    try {
      // Use the mapId passed from map selection; fall back to 'classic'
      final mapId = widget.mapId ?? (_useComplexBoard ? 'complex' : 'classic');
      final mapJson = await rootBundle.loadString('assets/maps/$mapId.json');

      final mapData = jsonDecode(mapJson) as Map<String, dynamic>;
      final playerCount = widget.initialPlayerCount ?? 2;
      final players = List<Map<String, dynamic>>.generate(
        playerCount,
        (i) => {
          'id': 'player_$i',
          'name': (widget.playerNames != null && i < widget.playerNames!.length)
              ? widget.playerNames![i]
              : 'Player ${i + 1}',
          'cash': CommandConstants.startingCash,
          'position': 'start',
          'is_ai': widget.aiFlags != null && i < widget.aiFlags!.length
              ? widget.aiFlags![i]
              : i > 0,
          'is_llm_controlled': false,
          'jail_turns': 0,
          'hospital_turns': 0,
          'owned_cards': <String>[],
          'stock_shares': 0,
          'team_id': null,
        },
      );

      final response = await _bridgeClient.executeCommand(
        command: BridgeCommand.createGame(mapData, players,
            seed: DateTime.now().microsecondsSinceEpoch),
        currentState: {},
      );

      if (!mounted) return;
      setState(() {
        _currentState = response.state;
        _gameState = _buildGameState(response.state, lastEvent: 'Game started');
        _landedTileIdThisTurn = null;
      });
      // Broadcast game_start to connected network clients (host only)
      if (_networkService != null && _networkService!.isHost) {
        _networkService!.sendMessage({
          'type': 'game_start',
          'state': response.state,
        });
      }
      _addLog('Game started with ${_gameState.numPlayers} players');
    } catch (e) {
      _addLog('Rust init failed: $e');
      if (mounted) setState(() {});
      rethrow;
    }
  }

  // ---- Game restart via Rust engine ----------------------------------------

  /// Restart the game using Rust's `create_game` instead of Flutter-side
  /// `_buildInitialState`. Loads the map JSON from assets and sends it to
  /// the Rust engine together with player definitions.
  Future<void> _restartGame(
      int count, List<String> playerNames, List<bool> aiFlags) async {
    try {
      final mapId = widget.mapId ?? 'classic';
      final mapJson = await rootBundle.loadString('assets/maps/$mapId.json');
      final mapData = jsonDecode(mapJson) as Map<String, dynamic>;

      final players = List<Map<String, dynamic>>.generate(
        count,
        (i) => {
          'id': 'player_$i',
          'name': i < playerNames.length ? playerNames[i] : 'Player ${i + 1}',
          'cash': CommandConstants.startingCash,
          'position': 'start',
          'is_ai': i < aiFlags.length ? aiFlags[i] : i > 0,
          'is_llm_controlled': false,
          'jail_turns': 0,
          'hospital_turns': 0,
          'owned_cards': <String>[],
          'stock_shares': 0,
          'team_id': null,
        },
      );

      final response = await _bridgeClient.executeCommand(
        command: BridgeCommand.createGame(mapData, players,
            seed: DateTime.now().microsecondsSinceEpoch),
        currentState: {},
      );

      if (!mounted) return;
      setState(() {
        _currentState = response.state;
        _gameState = _buildGameState(response.state, lastEvent: 'Game restarted');
        _landedTileIdThisTurn = null;
      });
      _addLog('Game restarted with $count players');
    } catch (e) {
      _addLog('Restart failed: $e');
      if (mounted) setState(() {});
    }
  }

  // ---- Event dispatcher helper ---------------------------------------------

  /// Register event subscribers for UI-trigger events (CardShop, Lottery, Auction).
  /// These are invoked via the subscriber pattern instead of callback parameters.
  void _registerEventSubscriptions() {
    // ── 保留现有的 UI 动作订阅 ─────────────────────────────────────────
    EventDispatcher.subscribe(
      'core:card_shop_landed',
      EventSubscriber(handler: (event) => _showCardShopDialog(), isUiAction: true),
    );
    EventDispatcher.subscribe(
      'core:lottery_landed',
      EventSubscriber(handler: (event) => _showLotteryPickerDialog(), isUiAction: true),
    );
    EventDispatcher.subscribe(
      'core:auction_started_event',
      EventSubscriber(handler: (event) {
        final tid = event['tile_id'] as String? ?? '';
        final bid = (event['starting_bid'] as num?)?.toInt() ?? 0;
        _showAuctionDialog(tid, bid);
      }, isUiAction: true),
    );

    // ── 地产购买事件 → 日志由 _handleLog 处理，无需额外操作 ──────────

    // ── 玩家回合开始事件 → 日志由 _handleLog 处理 ─────────────────────

    // ── 新增：玩家进监狱事件 ───────────────────────────────────────────
    EventDispatcher.subscribe(
      'core:player_sent_to_jail_event',
      EventSubscriber(handler: (event) {
        final pid = event['player_id'] as String? ?? '';
        final turns = event['turns'] as int? ?? GameDefaults.baseJailTurns;
        _addLog('$pid sent to jail for $turns turns');
      }, isUiAction: true),
    );

    // ── 新增：玩家胜利事件 ─────────────────────────────────────────────
    EventDispatcher.subscribe(
      'core:player_won',
      EventSubscriber(handler: (event) {
        final pid = event['player_id'] as String? ?? '';
        _addLog('🎉 $pid wins the game!');
      }, isUiAction: true),
    );

    // ── 新增：玩家破产事件 ─────────────────────────────────────────────
    EventDispatcher.subscribe(
      'core:player_bankrupt_event',
      EventSubscriber(handler: (event) {
        final pid = event['player_id'] as String? ?? '';
        _addLog('$pid is bankrupt!');
      }, isUiAction: true),
    );
  }

  // ---- Game actions --------------------------------------------------------

  Future<void> _onRoll() async {
    // Mark local roll in progress to guard against rebroadcast echo
    _isRollInProgress = true;

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

    // 3b. Dispatch ALL events through EventDispatcher with deferred UI actions.
    //     UI-trigger subscribers (CardShop, Lottery, Auction) are collected into
    //     pendingUiActions and executed after the movement animation completes.
    final dispatchResult = EventDispatcher.dispatch(
      response: response,
      deferUiActions: true,
    );

    final dice1 = dispatchResult.dice1;
    final dice2 = dispatchResult.dice2;
    final steps = dice1 + dice2;
    final isJailRoll = dispatchResult.isJailRoll;
    final is_seven = dice1 + dice2 == 7;

    // Rejected / error: bail out without animation
    if (dispatchResult.hadError) {
      setState(() {
        _currentState = response.state;
        _gameState = _buildGameState(
          response.state,
          lastEvent: dispatchResult.lastLog,
        );
        _isRollingDice = false;
        _isAnimating = false;
      });
      _broadcastRollEnd(dice1, dice2, response,
          actionLogs: dispatchResult.logs);
      return;
    }

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

    // 6. Broadcast roll_end to network peers
    _broadcastRollEnd(dice1, dice2, response,
        actionLogs: dispatchResult.logs);

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

    _lastDiceResult = {'dice1': dice1, 'dice2': dice2};
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: dispatchResult.lastLog,
        diceResult: {'dice1': dice1, 'dice2': dice2},
        positionOverrides: {activeIdx: currentPos},
      );
      _isRollingDice = false;
      // Keep _isAnimating for the movement phase below
    });

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

    // ═══ 延迟，确保棋子移动动画播放完毕后再显示特殊地块UI ═══
    setState(() {}); // show final token position
    await Future.delayed(const Duration(milliseconds: 300));
    // ════════════════════════════════════════════════════════

    // ═══ 插件消息检测（动画完成后显示）══════════════════════
    // DiceStats 插件输出
    final pluginMsg = response.event['_plugin_msg'] as String?;
    if (pluginMsg != null) _addLog(pluginMsg);
    // TreasureHunt 插件输出
    final treasureMsg = response.event['_plugin_msg_treasure'] as String?;
    if (treasureMsg != null) _addLog(treasureMsg);
    // ════════════════════════════════════════════════════════

    // Execute deferred UI actions and display event logs
    // (runs after movement animation completes)
    for (final log in dispatchResult.logs) {
      _addLog(log);
    }
    for (final uiAction in dispatchResult.pendingUiActions) {
      uiAction.execute();
    }

    // 9. Determine current player position
    final playerPos =
        _currentState['players'][_gameState.activePlayerIndex]['position'];

    // 10. All tile effects resolved — now allow the Roll button
    _isAnimating = false;
    setState(() {}); // refresh UI + re-enable Roll button

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
        final maxLevel = (_currentState['max_upgrade_level'] as num?)?.toInt() ?? GameDefaults.maxUpgradeLevel;
        final currentLevel = (property['upgrade_level'] as num?)?.toInt() ?? 0;
        if (maxLevel > 0 && currentLevel < maxLevel) {
          _showUpgradePropertyDialog(playerPos, property);
        }
      } else {
        // Landed on another player's property → auto-pay rent
        await _autoPayRent(playerPos);
      }
    }
    // Local roll fully complete — allow remote roll_end to be processed
    _isRollInProgress = false;
  }

  /// Automatically pay rent when landing on a property owned by another player.
  /// Sends a `pay_rent` command to the Rust engine for authoritative deduction.
  Future<void> _autoPayRent(String tileId) async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.payRent(tileId),
      currentState: _currentState,
    );
    final r = EventDispatcher.dispatch(response: response);
    for (final log in r.logs) {
      _addLog(log);
    }
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: r.lastLog,
      );
    });
    _syncAfterAction(response, actionLogs: r.logs);
  }


  Future<void> _onBuyCard(String cardId, int price) async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.buyCard(cardId, price),
      currentState: _currentState,
    );
    final r = EventDispatcher.dispatch(response: response);
    for (final log in r.logs) {
      _addLog(log);
    }
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: r.lastLog,
      );
    });
    _syncAfterAction(response, actionLogs: r.logs);
  }

  /// Pay bail to get out of jail early.
  Future<void> _onPayBail() async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.payBail(),
      currentState: _currentState,
    );
    final r = EventDispatcher.dispatch(response: response);
    for (final log in r.logs) {
      _addLog(log);
    }
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: r.lastLog,
      );
    });
    _syncAfterAction(response, actionLogs: r.logs);
  }

  Future<void> _onUseCard(String cardId) async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.useCard(cardId),
      currentState: _currentState,
    );
    final r = EventDispatcher.dispatch(response: response);
    for (final log in r.logs) {
      _addLog(log);
    }
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(response.state, lastEvent: r.lastLog);
    });
    _syncAfterAction(response, actionLogs: r.logs);
  }

  Future<void> _onBuyLotteryTicket(int number) async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.buyLotteryTicket(number),
      currentState: _currentState,
    );
    final r = EventDispatcher.dispatch(response: response);
    for (final log in r.logs) {
      _addLog(log);
    }
    setState(() {
      _currentState = response.state;
      _gameState =
          _buildGameState(response.state, lastEvent: r.lastLog);
    });
    _syncAfterAction(response, actionLogs: r.logs);
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
        jackpot: LotteryConstants.baseJackpot,
        ticketPrice: LotteryConstants.baseTicketPrice,
        nextDrawTurn: LotteryConstants.drawCycle,
        alreadyPicked: false,
        onPick: (number) => _onBuyLotteryTicket(number),
      ),
    );
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
    final r = EventDispatcher.dispatch(response: response);
    for (final log in r.logs) {
      _addLog(log);
    }
    _lastDiceResult = {}; // Clear dice display on turn end
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: r.lastLog,
      );
      _rollsRemainingThisTurn = 1;
      _landedTileIdThisTurn = null;
    });
    _syncAfterAction(response, actionLogs: r.logs);
    // After ending the turn, if the next player is AI, auto-run their turn
    if (_isActivePlayerAi && mounted) {
      await _processAiTurn();
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // AI turn processing
  // ═══════════════════════════════════════════════════════════════════

  /// Check if the current active player is AI-controlled.
  /// For host: player_0 is local, everything else is remote/AI.
  /// For client: player_0 is remote, player_1+ is local.
  bool get _isActivePlayerAi {
    final players = _currentState['players'] as List<dynamic>? ?? [];
    final idx = _gameState.activePlayerIndex;
    if (idx >= players.length) return false;
    final player = players[idx] as Map<String, dynamic>?;
    return player?['is_ai'] == true || player?['is_llm_controlled'] == true;
  }

  /// Execute one complete turn for the AI-controlled active player.
  /// Called after a human's action causes the turn to pass to an AI player.
  Future<void> _processAiTurn() async {
    if (!_isActivePlayerAi || !mounted) return;

    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.processAiTurn(),
      currentState: _currentState,
    );

    // Dispatch all AI turn events through EventDispatcher.
    // UI actions (CardShop, Lottery, etc.) are deferred until after movement.
    final dispatchResult = EventDispatcher.dispatch(
      response: response,
      deferUiActions: true,
    );

    // Extract dice values for animation
    final dice1 = dispatchResult.dice1;
    final dice2 = dispatchResult.dice2;
    final steps = dice1 + dice2;
    final isJailRoll = dispatchResult.isJailRoll;

    if (dispatchResult.hadError) {
      setState(() {
        _currentState = response.state;
        _gameState = _buildGameState(
          response.state,
          lastEvent: dispatchResult.lastLog,
        );
      });
      return;
    }

    // Animate dice (same as _onRoll but without network broadcast)
    if (!isJailRoll && steps > 0) {
      setState(() {
        _isRollingDice = true;
        _isAnimating = true;
      });

      for (var i = 0; i < 8; i++) {
        await Future.delayed(const Duration(milliseconds: 60));
        if (!mounted) return;
        setState(() {
          _animDice1 = 1 + (i * 3 + 1) % 6;
          _animDice2 = 1 + (i * 7 + 3) % 6;
        });
      }
      setState(() {
        _animDice1 = dice1;
        _animDice2 = dice2;
      });
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
    }

    // Apply final state
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

    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: dispatchResult.lastLog,
        positionOverrides: {activeIdx: currentPos},
      );
      _isRollingDice = false;
    });

    if (isJailRoll) {
      _isAnimating = false;
    } else {
      // Animate movement
      if (movementPath.isNotEmpty) {
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
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // Display logs and execute deferred UI actions (dialogues etc.)
    for (final log in dispatchResult.logs) {
      _addLog(log);
    }
    for (final uiAction in dispatchResult.pendingUiActions) {
      uiAction.execute();
    }

    _isAnimating = false;
    setState(() {});

    // If another AI player is next, chain to them
    if (_isActivePlayerAi && mounted) {
      await _processAiTurn();
    }
  }

  Future<void> _onBuyProperty(String tileId) async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.buyProperty(tileId),
      currentState: _currentState,
    );
    final r = EventDispatcher.dispatch(response: response);
    for (final log in r.logs) {
      _addLog(log);
    }
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: r.lastLog,
      );
    });
    _syncAfterAction(response, actionLogs: r.logs);
  }

  Future<void> _onUpgradeProperty(String tileId) async {
    final response = await _bridgeClient.executeCommand(
      command: BridgeCommand.upgradeProperty(tileId),
      currentState: _currentState,
    );
    final r = EventDispatcher.dispatch(response: response);
    for (final log in r.logs) {
      _addLog(log);
    }
    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: r.lastLog,
      );
    });
    _syncAfterAction(response, actionLogs: r.logs);
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
    final currentRent = PropertyFormulas.rent(basePrice, level);
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
    final upgradeCost = PropertyFormulas.upgradeCost(basePrice, level);
    final maxLevel =
        (_currentState['max_upgrade_level'] as num?)?.toInt() ?? GameDefaults.maxUpgradeLevel;
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
    final cost = PropertyFormulas.upgradeCost(basePrice, currentLevel);
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
          _restartGame(count, playerNames, aiFlags);
        },
      ),
    );
  }

  // ---- Build ---------------------------------------------------------------

  /// Build a lookup map of tile_id → display name.
  /// Needed because the Rust `Tile` struct only has `name_key`, not `name`.
  Map<String, String> get _tileNames {
    // Classic 40-tile board display names
    const classicNames = <String, String>{
      'start': 'Start',
      'prop_1': 'Mediterranean Ave',
      'chance_1': 'Chance',
      'prop_2': 'Baltic Ave',
      'tax_1': 'Income Tax',
      'rr_1': 'Reading RR',
      'prop_3': 'Oriental Ave',
      'lottery_1': 'Lottery',
      'prop_4': 'Vermont Ave',
      'prop_5': 'Connecticut Ave',
      'jail': 'Jail',
      'prop_6': 'St. Charles Pl',
      'util_1': 'Electric Co',
      'prop_7': 'States Ave',
      'prop_8': 'Virginia Ave',
      'rr_2': 'Penn RR',
      'prop_9': 'St. James Pl',
      'chance_3': 'Chance',
      'prop_10': 'Tennessee Ave',
      'prop_11': 'New York Ave',
      'park': 'Free Parking',
      'prop_12': 'Kentucky Ave',
      'chance_4': 'Chance',
      'prop_13': 'Indiana Ave',
      'prop_14': 'Illinois Ave',
      'rr_3': 'B&O RR',
      'prop_15': 'Atlantic Ave',
      'card_shop_1': 'Card Shop',
      'util_2': 'Water Works',
      'prop_17': 'Marvin Gardens',
      'go_to_jail': 'Go To Jail',
      'prop_18': 'Pacific Ave',
      'prop_19': 'N. Carolina Ave',
      'chance_5': 'Chance',
      'prop_20': 'Pennsylvania Ave',
      'rr_4': 'Short Line',
      'reserve_1': 'Expansion Slot',
      'prop_21': 'Park Place',
      'tax_2': 'Luxury Tax',
      'prop_22': 'Boardwalk',
    };

    // Complex 16-tile L-shaped board display names
    const complexNames = <String, String>{
      'start': 'Start',
      'prop_1': 'Med Ave',
      'chance_1': 'Chance',
      'prop_2': 'Baltic Ave',
      'tax_1': 'Income Tax',
      'prop_3': 'Oriental Ave',
      'rr_1': 'Reading RR',
      'corner_1': '↱ Up Turn',
      'chance_2': 'Community',
      'corner_2': '↰ Left Turn',
      'prop_4': 'Vermont Ave',
      'prop_5': 'Conn Ave',
      'corner_3': '↖ Top',
      'util_1': 'Electric Co',
      'prop_6': 'St Charles',
      'corner_4': '↙ Down Turn',
    };

    return _useComplexBoard ? complexNames : classicNames;
  }

  @override
  Widget build(BuildContext context) {
    // Show loading screen while async init is in progress
    if (_gameState.players.isEmpty) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Initializing game...'),
            ],
          ),
        ),
      );
    }

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
          // Plugin activity indicator
          if (_gameState.pluginMessages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Container(
                    width: 6, height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFCE93D8),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _gameState.pluginMessages.first,
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.white.withOpacity(0.50),
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
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

    // Check if the active player is in jail (show bail button)
    final players = _currentState['players'] as List<dynamic>? ?? [];
    final activeIdx = _gameState.activePlayerIndex;
    final jailTurns = activeIdx < players.length
        ? ((players[activeIdx] as Map<String, dynamic>)['jail_turns'] as num?)?.toInt() ?? 0
        : 0;
    final isInJail = jailTurns > 0;
    final bailAmount = jailTurns * CommandConstants.bailPerTurn;

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
        if (isInJail) ...[
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: canAct ? _onPayBail : null,
            icon: const Icon(Icons.monetization_on, size: 18),
            label: Text('Pay Bail (\$$bailAmount)'),
          ),
        ],
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
          onPressed: (canAct && _rollsRemainingThisTurn <= 0) ? _onEndTurn : null,
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
        final entry = events[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(entry.icon, size: 14, color: entry.color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  entry.message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: entry.color.withOpacity(0.85),
                        fontSize: 11,
                      ),
                ),
              ),
            ],
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
      startingCash: int.tryParse(_startCashCtrl.text) ?? CommandConstants.startingCash,
      maxPlayers: int.tryParse(_maxPlayersCtrl.text) ?? CommandConstants.maxPlayers,
      passStartBonus: int.tryParse(_passBonusCtrl.text) ?? CommandConstants.passStartBonus,
      jailEscapeTurns: int.tryParse(_jailTurnsCtrl.text) ?? GameDefaults.baseJailTurns,
      hospitalRecoveryTurns: int.tryParse(_hospitalTurnsCtrl.text) ?? CommandConstants.hospitalRecoveryTurns,
      maxUpgradeLevel: int.tryParse(_maxUpgradeCtrl.text) ?? GameDefaults.maxUpgradeLevel,
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
              onPressed: _playerCount < CommandConstants.maxPlayers
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
