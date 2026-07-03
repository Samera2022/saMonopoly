import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'board_view.dart';
import 'bridge_client.dart';
import 'content_pack.dart';
import 'content_pack_loader.dart';

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
  late GameStateData _gameState;
  late ContentPackViewModel _pack;
  late Map<String, dynamic> _currentState;

  // Player colours
  static const List<Color> _playerColors = [
    Color(0xFFD32F2F),
    Color(0xFF1976D2),
    Color(0xFF388E3C),
    Color(0xFFFBC02D),
    Color(0xFF8E24AA),
    Color(0xFFFF6F00),
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
    _addLog('Game started with ${_gameState.numPlayers} players');
  }

  @override
  void dispose() {
    _logScrollController.dispose();
    super.dispose();
  }

  // ---- State builders ------------------------------------------------------

  /// Build the initial GameState JSON map for [numPlayers] players.
  Map<String, dynamic> _buildInitialState(int numPlayers) {
    final tiles = _defaultTiles
        .map((t) => {
              'id': t['id'],
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
    for (final tile in _defaultTiles) {
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
        });
      }
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
      'seed': 42,
      'decks': [],
      'stock_market': null,
      'active_auction': null,
      'consecutive_doubles': 0,
    };
  }

  /// Build a [GameStateData] from a raw state JSON map.
  GameStateData _buildGameState(Map<String, dynamic> rawState,
      {String lastEvent = '', Map<String, int> diceResult = const {}}) {
    final playersList = BridgeClient.parsePlayers(rawState);
    final tokens = playersList
        .map((p) => PlayerTokenViewModel(
              id: p.id,
              name: p.name,
              tileId: p.position,
              color: _playerColors[_playerIndex(p.id) % _playerColors.length],
              cash: p.cash,
            ))
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

    setState(() {
      _currentState = response.state;
      _gameState = _buildGameState(
        response.state,
        lastEvent: 'Rolled $dice1 + $dice2',
        diceResult: {'dice1': dice1, 'dice2': dice2},
      );
    });
    _addLog('Rolled $dice1 + $dice2 = ${dice1 + dice2}');

    // Check if player landed on a purchasable property
    final playerPos =
        _currentState['players'][_gameState.activePlayerIndex]['position'];
    final property = _findPropertyAtTile(playerPos);
    if (property != null && property['owner'] == null) {
      _showBuyPropertyDialog(playerPos, property);
    }
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

  void _showCardShopDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Card Shop'),
        content: const Text(
          'Available cards:\n'
          '• Get Out of Jail Free — \$50\n'
          '• Double Rent — \$30\n'
          '• Bonus \$200 — \$100\n'
          '• Skip Turn — \$20',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _addLog('Card purchased from shop');
            },
            child: const Text('Buy Card'),
          ),
        ],
      ),
    );
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _GameSettingsDialog(
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
              name: t['name_key'] as String? ??
                  t['id'] as String,
              kind: t['kind'] as String? ?? 'Unknown',
            ))
        .toList();

    final boardViewModel = BoardViewModel(
      mapName: 'Classic',
      tiles: tiles,
      players: _gameState.players,
      activePlayerIndex: _gameState.activePlayerIndex,
    );

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
          child: Column(
            children: [
              // ---- Player info bar -----------------------------------------
              _buildPlayerInfoBar(activePlayer!),

              // ---- Board ---------------------------------------------------
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: BoardWidget(
                    viewModel: boardViewModel,
                  ),
                ),
              ),

              // ---- Dice result display -------------------------------------
              if (_gameState.diceResult.isNotEmpty)
                _buildDiceDisplay(),

              // ---- Action buttons ------------------------------------------
              _buildActionButtons(activePlayer),

              // ---- Event log (compact) ------------------------------------
              _buildEventLog(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerInfoBar(PlayerTokenViewModel activePlayer) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          // Active player indicator
          CircleAvatar(
            backgroundColor: activePlayer.color,
            radius: 18,
            child: Text(
              activePlayer.name.isNotEmpty
                  ? activePlayer.name[0].toUpperCase()
                  : '?',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activePlayer.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  'Turn ${_gameState.currentTurn} | '
                  'Properties: ${_playerPropertyCount(activePlayer.id)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          // Cash display
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.attach_money, color: Colors.green, size: 18),
                Text(
                  '\$${activePlayer.cash}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.green,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // All player indicators
          ..._gameState.players.map((p) {
            final isActive = p.id == activePlayer.id;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: CircleAvatar(
                radius: 10,
                backgroundColor:
                    isActive ? p.color : p.color.withOpacity(0.3),
                child: Text(
                  p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
                  style: TextStyle(
                    color: isActive ? Colors.white : Colors.white60,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildDiceDisplay() {
    final dice1 = _gameState.diceResult['dice1'] ?? 0;
    final dice2 = _gameState.diceResult['dice2'] ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _diceFace(dice1),
          const SizedBox(width: 12),
          _diceFace(dice2),
          const SizedBox(width: 16),
          Text(
            '= ${dice1 + dice2}',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
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
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          // Roll dice
          Expanded(
            child: FilledButton.icon(
              onPressed: isMyTurn ? _onRoll : null,
              icon: const Icon(Icons.casino),
              label: const Text('Roll'),
            ),
          ),
          const SizedBox(width: 8),
          // Buy property
          Expanded(
            child: OutlinedButton.icon(
              onPressed: isMyTurn ? () {
                final pos = _gameState
                    .players[_gameState.activePlayerIndex]
                    .tileId;
                final prop = _findPropertyAtTile(pos);
                if (prop != null && prop['owner'] == null) {
                  _showBuyPropertyDialog(pos, prop);
                } else {
                  _addLog('No property to buy here');
                }
              } : null,
              icon: const Icon(Icons.shopping_cart),
              label: const Text('Buy'),
            ),
          ),
          const SizedBox(width: 8),
          // Trade
          IconButton(
            onPressed: () => _showTradeDialog(),
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Trade',
          ),
          // Card shop
          IconButton(
            onPressed: () => _showCardShopDialog(),
            icon: const Icon(Icons.style),
            tooltip: 'Card Shop',
          ),
          const SizedBox(width: 4),
          // End turn
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: isMyTurn ? _onEndTurn : null,
              icon: const Icon(Icons.skip_next),
              label: const Text('End Turn'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventLog() {
    final events = _gameState.eventLog;
    return Container(
      constraints: const BoxConstraints(maxHeight: 100),
      child: ListView.builder(
        controller: _logScrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: events.length,
        itemBuilder: (context, index) {
          return Text(
            events[index],
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey.shade600,
                ),
          );
        },
      ),
    );
  }
}

// ============================================================================
// Game settings dialog
// ============================================================================

class _GameSettingsDialog extends StatefulWidget {
  final int initialPlayerCount;
  final void Function(
      int count, List<String> names, List<bool> aiFlags) onStart;

  const _GameSettingsDialog({
    required this.initialPlayerCount,
    required this.onStart,
  });

  @override
  State<_GameSettingsDialog> createState() => _GameSettingsDialogState();
}

class _GameSettingsDialogState extends State<_GameSettingsDialog> {
  late int _playerCount;
  late List<TextEditingController> _nameControllers;
  late List<bool> _aiFlags;

  @override
  void initState() {
    super.initState();
    _playerCount = widget.initialPlayerCount;
    _nameControllers = List.generate(
      _playerCount,
      (i) => TextEditingController(text: 'Player ${i + 1}'),
    );
    _aiFlags = List.generate(
      _playerCount,
      (i) => i > 0, // default: first player human, rest AI
    );
  }

  @override
  void dispose() {
    for (final c in _nameControllers) {
      c.dispose();
    }
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Game Settings'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            // Player count
            Row(
              children: [
                const Text('Players:'),
                const Spacer(),
                IconButton(
                  onPressed:
                      _playerCount > 2 ? () => _updatePlayerCount(_playerCount - 1) : null,
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
                  onPressed:
                      _playerCount < 6 ? () => _updatePlayerCount(_playerCount + 1) : null,
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            const Divider(),

            // Player configurations
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
                            backgroundColor: _playerColors[
                                i % _playerColors.length],
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
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
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
