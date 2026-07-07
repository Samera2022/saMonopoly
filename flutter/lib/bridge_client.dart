import 'dart:convert';
import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:ffi/ffi.dart';

// ============================================================================
// Bridge models – mirroring the Rust structures in
// crates/application/src/bridge.rs
// ============================================================================

/// Bridge command – matches [crate::commands::GameCommand] on the Rust side.
class BridgeCommand {
  final String type;
  final Map<String, dynamic>? params;

  const BridgeCommand({required this.type, this.params});

  /// Serialize to Rust's serde-externally-tagged enum format.
  /// - Unit variant (no params): just the string, e.g. `"Roll"`
  /// - Struct variant (has params): `{ "VariantName": { ...params } }`
  dynamic toJson() {
    final p = params;
    if (p == null || p.isEmpty) {
      return type; // unit variant → just the string
    }
    return {type: p}; // struct variant → { "Type": { ... } }
  }

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
    // Handle Rust serde external tagging: event comes as
    // {"VariantName": {dice1: ..., dice2: ...}} instead of flat fields.
    // Flatten it so the rest of Flutter code can read fields directly.
    var event = json['event'];
    if (event is Map<String, dynamic>) {
      final keys = event.keys.toList();
      if (keys.length == 1) {
        final inner = event[keys.first];
        if (inner is Map<String, dynamic>) {
          final flat = Map<String, dynamic>.from(inner);
          flat['event_type'] = keys.first;
          event = flat;
        }
      }
    }
    return BridgeResponse(
      event: event as Map<String, dynamic>,
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
// Native FFI bindings to the Rust engine (libsa_monopoly_application.so)
// ============================================================================

typedef SaEngineExecuteNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineExecuteDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineFreeStringNative = Void Function(Pointer<Utf8>);
typedef SaEngineFreeStringDart = void Function(Pointer<Utf8>);

/// Loads the Rust shared library and binds the native functions.
class RustEngineBinding {
  late final DynamicLibrary _lib;
  late final SaEngineExecuteDart _execute;
  late final SaEngineFreeStringDart _freeString;
  bool _available = false;

  RustEngineBinding() {
    try {
      // Try common library paths
      final libraryPaths = [
        // Debug builds
        'target/debug/libsa_monopoly_application.so',
        '../target/debug/libsa_monopoly_application.so',
        '/home/samera2022/Projects/saMonopoly/target/debug/libsa_monopoly_application.so',
        // Release builds
        'target/release/libsa_monopoly_application.so',
        '../target/release/libsa_monopoly_application.so',
        '/home/samera2022/Projects/saMonopoly/target/release/libsa_monopoly_application.so',
      ];

      DynamicLibrary? lib;
      for (final path in libraryPaths) {
        try {
          lib = DynamicLibrary.open(path);
          debugPrint('Rust engine loaded from: $path');
          break;
        } catch (_) {
          // Try next path
        }
      }

      if (lib == null) {
        debugPrint('Rust engine library not found, will use simulation');
        _available = false;
        return;
      }

      _lib = lib;
      _execute = _lib
          .lookupFunction<SaEngineExecuteNative, SaEngineExecuteDart>(
              'sa_engine_execute');
      _freeString = _lib
          .lookupFunction<SaEngineFreeStringNative, SaEngineFreeStringDart>(
              'sa_engine_free_string');
      _available = true;
      debugPrint('Rust engine FFI bridge initialized successfully');
    } catch (e) {
      debugPrint('Failed to load Rust engine: $e');
      _available = false;
    }
  }

  bool get isAvailable => _available;

  /// Execute a command JSON string against the Rust engine.
  /// Returns the response JSON string.
  String? execute(String jsonPayload) {
    if (!_available) return null;

    final inputPtr = jsonPayload.toNativeUtf8();
    final resultPtr = _execute(inputPtr);
    calloc.free(inputPtr);

    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }
}

// ============================================================================
// BridgeClient – main API consumed by the Flutter UI
// ============================================================================

class BridgeClient {
  final RustEngineBinding _engine;

  BridgeClient({RustEngineBinding? engine})
      : _engine = engine ?? RustEngineBinding();

  /// Serialise a [BridgeRequest] into its JSON wire format.
  String buildRequest(BridgeRequest request) {
    return request.toJsonString();
  }

  /// Deserialise a JSON response string back into a [BridgeResponse].
  BridgeResponse parseResponse(String response) {
    return BridgeResponse.fromJsonString(response);
  }

  /// Execute a command against the Rust engine (native FFI) or fall back
  /// to the Dart simulation if the shared library is not available.
  Future<BridgeResponse> executeCommand({
    required BridgeCommand command,
    required Map<String, dynamic> currentState,
  }) async {
    final request = BridgeRequest(command: command, state: currentState);
    final jsonPayload = buildRequest(request);

    // Try native Rust engine first
    if (_engine.isAvailable) {
      final responseText = _engine.execute(jsonPayload);
      if (responseText != null) {
        try {
          final decoded = jsonDecode(responseText);
          if (decoded is Map<String, dynamic>) {
            if (decoded.containsKey('error')) {
              debugPrint('Rust engine error: ${decoded['error']}');
            } else if (decoded.containsKey('event') && decoded.containsKey('state')) {
              return BridgeResponse.fromJson(decoded);
            }
          }
        } catch (e) {
          debugPrint('Failed to parse Rust engine response: $e');
        }
      }
    }

    // Fall back to Dart simulation
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
        // Mask to 48 bits for JSON-safe round-trip (matching Rust BridgeRng).
        state['seed'] = seed & 0xFFFFFFFFFFFF;

        // ─── Go To Jail helper ─────────────────────────────────────────────────
        // Sets jail_turns to 3 + bail_abuse_count and moves player to jail tile.
        void _sendToJail(Map<String, dynamic> st, int abuseCount) {
          final idx = st['active_player_index'] as int? ?? 0;
          final pl = List<Map<String, dynamic>>.from(
              (st['players'] as List<dynamic>?)?.cast() ?? []);
          if (idx < pl.length) {
            final p = Map<String, dynamic>.from(pl[idx]);
            final total = 3 + abuseCount;
            p['jail_turns'] = total;
            // Find jail tile
            final tiles = (st['board'] as Map<String, dynamic>?)?
                ['tiles'] as List<dynamic>? ?? [];
            final jailTile = tiles.cast<Map<String, dynamic>>().firstWhere(
                (t) => t['id'] == 'jail',
                orElse: () => const <String, dynamic>{});
            if (jailTile.isNotEmpty) {
              p['position'] = jailTile['id'];
            }
            pl[idx] = p;
            st['players'] = pl;
          }
        }

        final steps = dice1 + dice2;
        final isSeven = dice1 + dice2 == 7;
        final activeIdx = state['active_player_index'] as int? ?? 0;
        final players = List<Map<String, dynamic>>.from(
            (state['players'] as List<dynamic>?)?.cast() ?? []);
        if (activeIdx < players.length) {
          final player = Map<String, dynamic>.from(players[activeIdx]);
          final jailTurns = (player['jail_turns'] as num?)?.toInt() ?? 0;
          final hospitalTurns = (player['hospital_turns'] as num?)?.toInt() ?? 0;

          if (hospitalTurns > 0) {
            // Hospital: just decrement and skip (no dice shown).
            player['hospital_turns'] = hospitalTurns - 1;
            players[activeIdx] = player;
            state['players'] = players;
            event['event_type'] = 'CommandRejected';
            event['reason'] = 'player_in_hospital';
            break;
          }

          if (jailTurns > 0) {
            if (isSeven) {
              // Rolled 7 → released! Move normally.
              player['jail_turns'] = 0;
              final tiles = (state['board'] as Map<String, dynamic>?)?
                      ['tiles'] as List<dynamic>? ??
                  [];
              final currentPos = tiles.indexWhere(
                  (t) => t['id'] == player['position']);
              final newIdx = (currentPos + steps) %
                  (tiles.length > 0 ? tiles.length : 1);
              if (tiles.isNotEmpty) {
                player['position'] = tiles[newIdx]['id'];
              }
              players[activeIdx] = player;
              state['players'] = players;
              event['event_type'] = 'DiceRolled';
              event['dice1'] = dice1;
              event['dice2'] = dice2;
              event['is_seven'] = true;
              event['consecutive'] = 0;
              event['player_id'] = player['id'];
              event['to_tile'] = player['position'];
            } else {
              // Failed roll — stay jailed, decrement.
              player['jail_turns'] = jailTurns - 1;
              players[activeIdx] = player;
              state['players'] = players;
              final stillJailed = player['jail_turns'] > 0;
              if (stillJailed) {
                event['event_type'] = 'DiceRolled';
                event['dice1'] = dice1;
                event['dice2'] = dice2;
                event['is_seven'] = false;
              } else {
                event['event_type'] = 'PlayerReleasedFromJail';
                event['player_id'] = player['id'];
              }
            }
            break;
          }

          // Normal roll (not in jail/hospital)
          final tiles = (state['board'] as Map<String, dynamic>?)?
                  ['tiles'] as List<dynamic>? ??
              [];
          final currentPos = tiles.indexWhere(
              (t) => t['id'] == player['position']);
          final newIdx = (currentPos + steps) %
              (tiles.length > 0 ? tiles.length : 1);
          if (tiles.isNotEmpty) {
            player['position'] = tiles[newIdx]['id'];
          }
          players[activeIdx] = player;
          state['players'] = players;
          event['event_type'] = 'DiceRolled';
          event['dice1'] = dice1;
          event['dice2'] = dice2;
          event['is_seven'] = isSeven;
          event['consecutive'] = 0;
          event['player_id'] = player['id'];
          event['to_tile'] = player['position'];

          // ═══ DiceStats 插件模拟 ═══════════════════════════════════
          // Track roll count in state so the plugin appears active
          int rollCount = (state['_plugin_dice_stats_rolls'] as num?)?.toInt() ?? 0;
          rollCount++;
          state['_plugin_dice_stats_rolls'] = rollCount;
          final sum = dice1 + dice2;
          event['_plugin_msg'] = '[DiceStats] 第${rollCount}次掷骰: ${dice1}+${dice2}=${sum}';
          // ═════════════════════════════════════════════════════════

          // ═══ TreasureHunt 插件模拟 ════════════════════════════════
          // If landed on a chance tile, grant bonus cash
          final landedTileId = player['position'] as String;
          final landedTile = tiles.cast<Map<String, dynamic>>().firstWhere(
            (t) => t['id'] == landedTileId,
            orElse: () => const <String, dynamic>{},
          );
          if (landedTile['kind'] == 'chance' || landedTile['tile_type'] == 'Chance') {
            final reward = 50 + (rollCount * 13) % 151;
            final p = Map<String, dynamic>.from(players[activeIdx]);
            p['cash'] = ((p['cash'] as num?)?.toInt() ?? 0) + reward;
            players[activeIdx] = p;
            state['players'] = players;
            event['_plugin_msg_treasure'] = '[TreasureHunt] 玩家 ${player['id']} 获得 \$${reward} 宝藏！';
          }
          // ══════════════════════════════════════════════════════════
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
            player['cash'] =
                ((player['cash'] as num?)?.toInt() ?? 0) - price;
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
        event['tile_id'] =
            request.command.params?['tile_id'] as String? ?? '';
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
            final currentLevel =
                (prop['upgrade_level'] as num?)?.toInt() ?? 0;
            final basePrice = (prop['base_price'] as num).toInt();
            // Upgrade cost = base_price * (1 + level) / 3
            final cost = basePrice * (1 + currentLevel) ~/ 3;
            // Deduct cost from active player
            final upPlayers = List<Map<String, dynamic>>.from(
                (state['players'] as List<dynamic>?)?.cast() ?? []);
            final activeIdx = state['active_player_index'] as int? ?? 0;
            if (activeIdx < upPlayers.length) {
              final player = Map<String, dynamic>.from(upPlayers[activeIdx]);
              player['cash'] =
                  ((player['cash'] as num?)?.toInt() ?? 0) - cost;
              upPlayers[activeIdx] = player;
              state['players'] = upPlayers;
            }
            // Increment level
            prop['upgrade_level'] = currentLevel + 1;
            event['name'] =
                'upgrade_property:$tileId:${currentLevel + 1}';
            break;
          }
        }
        break;

      case 'Mortgage':
        event['tile_id'] =
            request.command.params?['tile_id'] as String? ?? '';
        event['amount'] = 100;
        break;

      case 'Redeem':
        event['tile_id'] =
            request.command.params?['tile_id'] as String? ?? '';
        event['amount'] = 110;
        break;

      case 'Auction':
        event['tile_id'] =
            request.command.params?['tile_id'] as String? ?? '';
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

      case 'PayBail': {
        final idx = state['active_player_index'] as int? ?? 0;
        int paidAmount = 0;
        final pl = List<Map<String, dynamic>>.from(
            (state['players'] as List<dynamic>?)?.cast() ?? []);
        if (idx < pl.length) {
          final p = Map<String, dynamic>.from(pl[idx]);
          final jailTurns = (p['jail_turns'] as num?)?.toInt() ?? 0;
          paidAmount = jailTurns * 50;
          p['cash'] = ((p['cash'] as num?)?.toInt() ?? 0) - paidAmount;
          p['jail_turns'] = 0;
          pl[idx] = p;
          state['players'] = pl;
        }
        final abuseCount = (state['bail_abuse_count'] as num?)?.toInt() ?? 0;
        state['bail_abuse_count'] = abuseCount + 1;
        event['event_type'] = 'BailPaid';
        event['player_id'] = _activePlayerId(state);
        event['amount'] = paidAmount;
        break;
      }

      case 'BuyCard':
        final cardId =
            request.command.params?['card_id'] as String? ?? '';
        final price = request.command.params?['price'] as int? ?? 0;
        event['card_id'] = cardId;
        event['price'] = price;
        // Deduct cash and add card to active player's inventory
        final bcPlayers = List<Map<String, dynamic>>.from(
            (state['players'] as List<dynamic>?)?.cast() ?? []);
        final bcIdx = state['active_player_index'] as int? ?? 0;
        if (bcIdx < bcPlayers.length) {
          final player = Map<String, dynamic>.from(bcPlayers[bcIdx]);
          player['cash'] =
              ((player['cash'] as num?)?.toInt() ?? 0) - price;
          final ownedCards = List<String>.from(
              (player['owned_cards'] as List<dynamic>?)
                      ?.cast<String>() ??
                  []);
          ownedCards.add(cardId);
          player['owned_cards'] = ownedCards;
          bcPlayers[bcIdx] = player;
          state['players'] = bcPlayers;
        }
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
        final useCardId =
            request.command.params?['card_id'] as String? ?? '';
        event['event_type'] = 'CardUsed';
        event['player_id'] = _activePlayerId(state);
        event['card_id'] = useCardId;
        // Remove the card from active player's inventory
        final ucPlayers = List<Map<String, dynamic>>.from(
            (state['players'] as List<dynamic>?)?.cast() ?? []);
        final ucIdx = state['active_player_index'] as int? ?? 0;
        if (ucIdx < ucPlayers.length) {
          final player = Map<String, dynamic>.from(ucPlayers[ucIdx]);
          final ownedCards = List<String>.from(
              (player['owned_cards'] as List<dynamic>?)
                      ?.cast<String>() ??
                  []);
          ownedCards.remove(useCardId);
          player['owned_cards'] = ownedCards;
          ucPlayers[ucIdx] = player;
          state['players'] = ucPlayers;
        }
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
