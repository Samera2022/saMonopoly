import 'dart:convert';

// ============================================================================
// Bridge models – mirroring the Rust structures in
// crates/application/src/bridge.rs
// ============================================================================

/// Bridge command – matches [crate::commands::GameCommand] on the Rust side.
class BridgeCommand {
  final String type;
  final Map<String, dynamic>? params;

  const BridgeCommand({required this.type, this.params});

  Map<String, dynamic> toJson() => {
        'type': type,
        if (params != null) ...params!,
      };

  // ---- Convenience constructors -------------------------------------------

  factory BridgeCommand.roll() => const BridgeCommand(type: 'Roll');

  factory BridgeCommand.buyProperty(String tileId) => BridgeCommand(
        type: 'BuyProperty',
        params: {'tile_id': tileId},
      );

  factory BridgeCommand.upgradeProperty(String tileId) => BridgeCommand(
        type: 'UpgradeProperty',
        params: {'tile_id': tileId},
      );

  factory BridgeCommand.endTurn() => const BridgeCommand(type: 'EndTurn');

  factory BridgeCommand.payRent(String tileId) => BridgeCommand(
        type: 'PayRent',
        params: {'tile_id': tileId},
      );

  factory BridgeCommand.buyCard(String cardId, int price) => BridgeCommand(
        type: 'BuyCard',
        params: {'card_id': cardId, 'price': price},
      );

  factory BridgeCommand.trade({
    required String fromPlayerId,
    required String toPlayerId,
    String? offeredProperty,
    int offeredCash = 0,
    String? requestedProperty,
    int requestedCash = 0,
  }) =>
      BridgeCommand(
        type: 'Trade',
        params: {
          'from_player_id': fromPlayerId,
          'to_player_id': toPlayerId,
          'offered_property': offeredProperty,
          'offered_cash': offeredCash,
          'requested_property': requestedProperty,
          'requested_cash': requestedCash,
        },
      );

  factory BridgeCommand.auction(String tileId, int startingBid) =>
      BridgeCommand(
        type: 'Auction',
        params: {'tile_id': tileId, 'starting_bid': startingBid},
      );

  factory BridgeCommand.bid(String playerId, int amount) => BridgeCommand(
        type: 'Bid',
        params: {'player_id': playerId, 'amount': amount},
      );

  factory BridgeCommand.mortgage(String tileId) => BridgeCommand(
        type: 'Mortgage',
        params: {'tile_id': tileId},
      );

  factory BridgeCommand.redeem(String tileId) => BridgeCommand(
        type: 'Redeem',
        params: {'tile_id': tileId},
      );

  factory BridgeCommand.sellShares(String playerId, int shares) =>
      BridgeCommand(
        type: 'SellShares',
        params: {'player_id': playerId, 'shares': shares},
      );

  factory BridgeCommand.configGet() =>
      const BridgeCommand(type: 'ConfigGet');

  factory BridgeCommand.configSet(String section, Map<String, dynamic> value) =>
      BridgeCommand(
        type: 'ConfigSet',
        params: {'section': section, 'value': value},
      );
}

/// Bridge request – matches [crate::bridge::BridgeRequest] on the Rust side.
class BridgeRequest {
  final BridgeCommand command;
  final Map<String, dynamic> state;

  const BridgeRequest({required this.command, required this.state});

  Map<String, dynamic> toJson() => {
        'command': command.toJson(),
        'state': state,
      };

  String toJsonString() => jsonEncode(toJson());

  factory BridgeRequest.fromJson(Map<String, dynamic> json) {
    final cmdJson = json['command'] as Map<String, dynamic>;
    final cmdType = cmdJson['type'] as String;
    final cmdParams = Map<String, dynamic>.from(cmdJson)
      ..remove('type');
    return BridgeRequest(
      command: BridgeCommand(type: cmdType, params: cmdParams),
      state: json['state'] as Map<String, dynamic>,
    );
  }
}

/// Bridge response – matches [crate::bridge::BridgeResponse] on the Rust side.
class BridgeResponse {
  final Map<String, dynamic> event;
  final Map<String, dynamic> state;

  const BridgeResponse({required this.event, required this.state});

  factory BridgeResponse.fromJson(Map<String, dynamic> json) {
    return BridgeResponse(
      event: json['event'] as Map<String, dynamic>,
      state: json['state'] as Map<String, dynamic>,
    );
  }

  factory BridgeResponse.fromJsonString(String jsonString) {
    final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
    return BridgeResponse.fromJson(decoded);
  }

  Map<String, dynamic> toJson() => {
        'event': event,
        'state': state,
      };

  String toJsonString() => jsonEncode(toJson());
}

// ============================================================================
// Player tile position helper
// ============================================================================

/// Lightweight player view extracted from a serialised GameState.
class PlayerViewModel {
  final String id;
  final String name;
  final int cash;
  final String position;
  final bool isAi;
  final bool isInJail;
  final bool isInHospital;
  final List<String> ownedCards;
  final int stockShares;

  const PlayerViewModel({
    required this.id,
    required this.name,
    required this.cash,
    required this.position,
    required this.isAi,
    this.isInJail = false,
    this.isInHospital = false,
    this.ownedCards = const [],
    this.stockShares = 0,
  });

  factory PlayerViewModel.fromJson(Map<String, dynamic> json) {
    return PlayerViewModel(
      id: json['id'] as String,
      name: json['name'] as String,
      cash: (json['cash'] as num).toInt(),
      position: json['position'] as String,
      isAi: json['is_ai'] as bool? ?? false,
      isInJail: ((json['jail_turns'] as num?)?.toInt() ?? 0) > 0,
      isInHospital: ((json['hospital_turns'] as num?)?.toInt() ?? 0) > 0,
      ownedCards: (json['owned_cards'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      stockShares: (json['stock_shares'] as num?)?.toInt() ?? 0,
    );
  }
}

// ============================================================================
// BridgeClient – main API consumed by the Flutter UI
// ============================================================================

class BridgeClient {
  final NativeTransportPlaceholder _transport;

  const BridgeClient({NativeTransportPlaceholder? transport})
      : _transport = transport ?? const NativeTransportPlaceholder();

  /// Serialise a [BridgeRequest] into its JSON wire format.
  String buildRequest(BridgeRequest request) {
    return request.toJsonString();
  }

  /// Deserialise a JSON response string back into a [BridgeResponse].
  BridgeResponse parseResponse(String response) {
    return BridgeResponse.fromJsonString(response);
  }

  /// Execute a command against the (simulated) Rust engine.
  ///
  /// When the native FFI bridge is not connected, this method simulates an
  /// engine round-trip by mutating the provided state snapshot locally so the
  /// UI can still be exercised during development.
  Future<BridgeResponse> executeCommand({
    required BridgeCommand command,
    required Map<String, dynamic> currentState,
  }) async {
    final request = BridgeRequest(command: command, state: currentState);
    final jsonPayload = buildRequest(request);

    // Attempt native transport first.
    try {
      final responseText = await _transport.execute(jsonPayload);
      if (!responseText.contains('not connected yet')) {
        return BridgeResponse.fromJsonString(responseText);
      }
    } catch (_) {
      // Fall through to simulation.
    }

    // ---- Simulation mode ------------------------------------------------
    return _simulateEngineResponse(request);
  }

  /// Simulate the Rust engine locally.
  ///
  /// This provides a realistic emulation of [EngineBridge::execute] so the
  /// Flutter UI can be developed and tested without the actual Rust FFI layer.
  BridgeResponse _simulateEngineResponse(BridgeRequest request) {
    final state = _deepClone(request.state);
    final commandType = request.command.type;

    // Determine the event based on command type.
    final event = <String, dynamic>{
      'event_type': commandType,
    };

    // Apply command-specific mutations to the state clone.
    switch (commandType) {
      case 'Roll':
        // Use XorShift64 to generate two independent pseudorandom dice
        // values, mirroring the Rust engine's approach.
        int seed = (state['seed'] as num?)?.toInt() ?? 42;
        // Advance RNG state for dice1
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        final dice1 = (seed & 0x7fffffff) % 6 + 1;
        // Advance RNG state for dice2
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        final dice2 = (seed & 0x7fffffff) % 6 + 1;
        state['seed'] = seed;

        final steps = dice1 + dice2;
        final activeIdx = state['active_player_index'] as int? ?? 0;
        final players = List<Map<String, dynamic>>.from(
            (state['players'] as List<dynamic>?)?.cast() ?? []);
        if (activeIdx < players.length) {
          final player = Map<String, dynamic>.from(players[activeIdx]);
          final tiles = (state['board'] as Map<String, dynamic>?)?
                  ['tiles'] as List<dynamic>? ??
              [];
          final currentPos = tiles.indexWhere(
              (t) => t['id'] == player['position']);
          final newIdx = (currentPos + steps) % (tiles.length > 0 ? tiles.length : 1);
          if (tiles.isNotEmpty) {
            player['position'] = tiles[newIdx]['id'];
          }
          players[activeIdx] = player;
          state['players'] = players;
          event['dice1'] = dice1;
          event['dice2'] = dice2;
          event['player_id'] = player['id'];
          event['to_tile'] = player['position'];
        }
        break;

      case 'BuyProperty':
        final tileId = request.command.params?['tile_id'] as String? ?? '';
        event['tile_id'] = tileId;
        event['player_id'] = _activePlayerId(state);
        // Find the property and get its price
        final properties = List<Map<String, dynamic>>.from(
            ((state['board'] as Map<String, dynamic>?)?
                    ['properties'] as List<dynamic>?)
                ?.cast() ?? []);
        int? price;
        for (final prop in properties) {
          if (prop['tile_id'] == tileId) {
            price = (prop['base_price'] as num?)?.toInt();
            prop['owner'] = _activePlayerId(state);
            break;
          }
        }
        // Deduct the price from the active player's cash
        if (price != null && price > 0) {
          final players = List<Map<String, dynamic>>.from(
              (state['players'] as List<dynamic>?)?.cast() ?? []);
          final activeIdx = state['active_player_index'] as int? ?? 0;
          if (activeIdx < players.length) {
            final player = Map<String, dynamic>.from(players[activeIdx]);
            player['cash'] = ((player['cash'] as num?)?.toInt() ?? 0) - price;
            players[activeIdx] = player;
            state['players'] = players;
          }
        }
        break;

      case 'EndTurn':
        final numPlayers =
            (state['players'] as List<dynamic>?)?.length ?? 1;
        final currentIdx = state['active_player_index'] as int? ?? 0;
        state['active_player_index'] = (currentIdx + 1) % numPlayers;
        state['current_turn'] =
            ((state['current_turn'] as num?)?.toInt() ?? 0) + 1;
        break;

      case 'PayRent':
        event['tile_id'] = request.command.params?['tile_id'] as String? ?? '';
        event['amount'] = 50;
        break;

      case 'UpgradeProperty':
        final tileId = request.command.params?['tile_id'] as String? ?? '';
        event['tile_id'] = tileId;
        event['event_type'] = 'CommandAccepted';
        // Find the property and apply the upgrade
        final upProperties = List<Map<String, dynamic>>.from(
            ((state['board'] as Map<String, dynamic>?)?
                    ['properties'] as List<dynamic>?)
                ?.cast() ?? []);
        for (final prop in upProperties) {
          if (prop['tile_id'] == tileId) {
            final currentLevel = (prop['upgrade_level'] as num?)?.toInt() ?? 0;
            final basePrice = (prop['base_price'] as num).toInt();
            final base = (prop['rent'] as List<dynamic>?)?.isNotEmpty == true
                ? ((prop['rent'] as List<dynamic>).first as num).toInt()
                : basePrice;
            final cost = base * (1 + currentLevel) ~/ 2;
            // Deduct cost from active player
            final upPlayers = List<Map<String, dynamic>>.from(
                (state['players'] as List<dynamic>?)?.cast() ?? []);
            final activeIdx = state['active_player_index'] as int? ?? 0;
            if (activeIdx < upPlayers.length) {
              final player = Map<String, dynamic>.from(upPlayers[activeIdx]);
              player['cash'] = ((player['cash'] as num?)?.toInt() ?? 0) - cost;
              upPlayers[activeIdx] = player;
              state['players'] = upPlayers;
            }
            // Increment level
            prop['upgrade_level'] = currentLevel + 1;
            event['name'] = 'upgrade_property:$tileId:${currentLevel + 1}';
            break;
          }
        }
        break;

      case 'Mortgage':
        event['tile_id'] = request.command.params?['tile_id'] as String? ?? '';
        event['amount'] = 100;
        break;

      case 'Redeem':
        event['tile_id'] = request.command.params?['tile_id'] as String? ?? '';
        event['amount'] = 110;
        break;

      case 'Auction':
        event['tile_id'] = request.command.params?['tile_id'] as String? ?? '';
        event['starting_bid'] =
            request.command.params?['starting_bid'] as int? ?? 0;
        break;

      case 'Bid':
        event['player_id'] =
            request.command.params?['player_id'] as String? ?? '';
        event['amount'] = request.command.params?['amount'] as int? ?? 0;
        break;

      case 'Trade':
        event['from_player_id'] =
            request.command.params?['from_player_id'] as String? ?? '';
        event['to_player_id'] =
            request.command.params?['to_player_id'] as String? ?? '';
        break;

      case 'BuyCard':
        event['card_id'] =
            request.command.params?['card_id'] as String? ?? '';
        event['price'] = request.command.params?['price'] as int? ?? 0;
        break;

      case 'SellShares':
        event['player_id'] =
            request.command.params?['player_id'] as String? ?? '';
        event['shares'] = request.command.params?['shares'] as int? ?? 0;
        break;

      case 'BuyLotteryTicket':
        final number = request.command.params?['number'] as int? ?? 1;
        event['event_type'] = 'LotteryTicketBought';
        event['player_id'] = _activePlayerId(state);
        event['number'] = number;
        event['ticket_price'] = 50;
        // Deduct ticket price
        final ltPlayers = List<Map<String, dynamic>>.from(
            (state['players'] as List<dynamic>?)?.cast() ?? []);
        final ltIdx = state['active_player_index'] as int? ?? 0;
        if (ltIdx < ltPlayers.length) {
          final p = Map<String, dynamic>.from(ltPlayers[ltIdx]);
          p['cash'] = ((p['cash'] as num?)?.toInt() ?? 0) - 50;
          ltPlayers[ltIdx] = p;
          state['players'] = ltPlayers;
        }
        break;

      case 'UseCard':
        event['event_type'] = 'CardUsed';
        event['player_id'] = _activePlayerId(state);
        event['card_id'] =
            request.command.params?['card_id'] as String? ?? '';
        break;

      case 'ConfigGet':
        event['event_type'] = 'ConfigLoaded';
        break;

      case 'ConfigSet':
        event['event_type'] = 'ConfigUpdated';
        event['section'] =
            request.command.params?['section'] as String? ?? '';
        break;

      default:
        event['error'] = 'unknown_command';
    }

    return BridgeResponse(event: event, state: state);
  }

  /// Parse a list of players from a GameState JSON map.
  static List<PlayerViewModel> parsePlayers(Map<String, dynamic> state) {
    final playersList = (state['players'] as List<dynamic>?)
            ?.map((e) => PlayerViewModel.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    return playersList;
  }

  /// Helper: get the active player ID from a state map.
  String _activePlayerId(Map<String, dynamic> state) {
    final idx = state['active_player_index'] as int? ?? 0;
    final players = state['players'] as List<dynamic>? ?? [];
    if (idx < players.length) {
      return (players[idx] as Map<String, dynamic>)['id'] as String? ?? '';
    }
    return '';
  }

  /// Deep-clone a JSON-compatible Map (used by the simulator).
  Map<String, dynamic> _deepClone(Map<String, dynamic> original) {
    return Map<String, dynamic>.from(
      jsonDecode(jsonEncode(original)) as Map<String, dynamic>,
    );
  }
}

// ============================================================================
// Native transport placeholder
// ============================================================================

class NativeTransportPlaceholder {
  const NativeTransportPlaceholder();

  /// In production this would call into the Rust FFI layer.
  /// Currently returns a sentinel that triggers the simulated path.
  Future<String> execute(String payload) async {
    return '{"error":"native bridge not connected yet"}';
  }
}
