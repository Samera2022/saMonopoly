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
  //
  // Names follow Rust's namespaced convention: "core:command:<name>"
  // This eliminates the need for a command-type mapping layer.

  factory BridgeCommand.roll() =>
      const BridgeCommand(type: 'core:command:roll');

  factory BridgeCommand.buyProperty(String tileId) => BridgeCommand(
        type: 'core:command:buy_property',
        params: {'tile_id': tileId},
      );

  factory BridgeCommand.upgradeProperty(String tileId) => BridgeCommand(
        type: 'core:command:upgrade_property',
        params: {'tile_id': tileId},
      );

  factory BridgeCommand.endTurn() =>
      const BridgeCommand(type: 'core:command:end_turn');

  factory BridgeCommand.payRent(String tileId) => BridgeCommand(
        type: 'core:command:pay_rent',
        params: {'tile_id': tileId},
      );

  factory BridgeCommand.buyCard(String cardId, int price) => BridgeCommand(
        type: 'core:command:buy_card',
        params: {'card_id': cardId, 'price': price},
      );

  factory BridgeCommand.useCard(String cardId) => BridgeCommand(
        type: 'core:command:use_card',
        params: {'card_id': cardId},
      );

  factory BridgeCommand.payBail() =>
      const BridgeCommand(type: 'core:command:pay_bail');

  factory BridgeCommand.buyLotteryTicket(int number) => BridgeCommand(
        type: 'core:command:buy_lottery_ticket',
        params: {'number': number},
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
        type: 'core:command:trade',
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
        type: 'core:command:auction',
        params: {'tile_id': tileId, 'starting_bid': startingBid},
      );

  factory BridgeCommand.bid(String playerId, int amount) => BridgeCommand(
        type: 'core:command:bid',
        params: {'player_id': playerId, 'amount': amount},
      );

  factory BridgeCommand.mortgage(String tileId) => BridgeCommand(
        type: 'core:command:mortgage',
        params: {'tile_id': tileId},
      );

  factory BridgeCommand.redeem(String tileId) => BridgeCommand(
        type: 'core:command:redeem',
        params: {'tile_id': tileId},
      );

  factory BridgeCommand.sellShares(String playerId, int shares) =>
      BridgeCommand(
        type: 'core:command:sell_shares',
        params: {'player_id': playerId, 'shares': shares},
      );

  factory BridgeCommand.configGet() =>
      const BridgeCommand(type: 'core:command:config_get');

  factory BridgeCommand.configSet(
          String section, Map<String, dynamic> value) =>
      BridgeCommand(
        type: 'core:command:config_set',
        params: {'section': section, 'value': value},
      );
}

/// Bridge request – matches [crate::bridge::BridgeRequest] on the Rust side.
class BridgeRequest {
  final BridgeCommand command;
  final Map<String, dynamic> state;

  const BridgeRequest({required this.command, required this.state});

  /// Serialize to the Rust [crate::bridge::BridgeRequest] format:
  /// `{"command_type": "Roll", "source": "core", "payload": {...params}, "state": {...}}`
  Map<String, dynamic> toJson() {
    final cmd = command;
    final params = cmd.params ?? <String, dynamic>{};
    return {
      'command_type': cmd.type,
      'source': 'core',
      'payload': params,
      'state': state,
    };
  }

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
///
/// Rust returns `{"events": [{"event_type": "...", ...}], "state": {...}}`.
/// The first event is extracted and exposed as `event` for backward
/// compatibility with existing Flutter UI code.
class BridgeResponse {
  /// The first (or only) event from the Rust response.
  final Map<String, dynamic> event;
  /// All raw events from the Rust response (for callers that need the full list).
  final List<Map<String, dynamic>> allEvents;
  final Map<String, dynamic> state;

  const BridgeResponse({
    required this.event,
    this.allEvents = const [],
    required this.state,
  });

  factory BridgeResponse.fromJson(Map<String, dynamic> json) {
    // Rust returns `events` as an array of flattened event objects
    final eventsList = (json['events'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>() ??
        [];
    final firstEvent = eventsList.isNotEmpty
        ? eventsList.first
        : <String, dynamic>{'event_type': 'unknown'};
    return BridgeResponse(
      event: firstEvent,
      allEvents: eventsList,
      state: Map<String, dynamic>.from(json['state'] as Map<String, dynamic>),
    );
  }

  factory BridgeResponse.fromJsonString(String jsonString) {
    final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
    return BridgeResponse.fromJson(decoded);
  }

  Map<String, dynamic> toJson() => {
        'events': allEvents,
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
typedef SaEnginePluginCtlNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEnginePluginCtlDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineFreeStringNative = Void Function(Pointer<Utf8>);
typedef SaEngineFreeStringDart = void Function(Pointer<Utf8>);

/// Loads the Rust shared library and binds the native functions.
class RustEngineBinding {
  late final DynamicLibrary _lib;
  late final SaEngineExecuteDart _execute;
  SaEnginePluginCtlDart? _pluginCtl;
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
        debugPrint('Rust engine library not found');
        _available = false;
        return;
      }

      _lib = lib;
      _execute = _lib
          .lookupFunction<SaEngineExecuteNative, SaEngineExecuteDart>(
              'sa_engine_execute');
      // sa_engine_plugin_ctl is optional — not all builds include it
      try {
        _pluginCtl = _lib
            .lookupFunction<SaEnginePluginCtlNative, SaEnginePluginCtlDart>(
                'sa_engine_plugin_ctl');
      } catch (_) {
        debugPrint('sa_engine_plugin_ctl not available (optional)');
      }
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

  /// Call the Rust PluginController to enable/disable a plugin.
  /// Returns the new enabled state, or null on failure.
  bool? pluginCtl(String pluginId, bool enable) {
    if (!_available || _pluginCtl == null) return null;
    final payload = '{"plugin_id":"$pluginId","enable":$enable}';
    final inputPtr = payload.toNativeUtf8();
    final resultPtr = _pluginCtl!(inputPtr);
    calloc.free(inputPtr);
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    try {
      final json = jsonDecode(result) as Map<String, dynamic>;
      if (json['ok'] == true) {
        return json['enabled'] as bool;
      }
    } catch (_) {}
    return null;
  }
}

// ============================================================================
// BridgeClient – main API consumed by the Flutter UI
// ============================================================================

class BridgeClient {
  final RustEngineBinding _engine;

  BridgeClient({RustEngineBinding? engine})
      : _engine = engine ?? RustEngineBinding();

  /// Get the underlying Rust engine binding for direct FFI access.
  RustEngineBinding get engine => _engine;

  /// Serialise a [BridgeRequest] into its JSON wire format.
  String buildRequest(BridgeRequest request) {
    return request.toJsonString();
  }

  /// Deserialise a JSON response string back into a [BridgeResponse].
  BridgeResponse parseResponse(String response) {
    return BridgeResponse.fromJsonString(response);
  }

  /// Execute a command against the Rust engine (native FFI).
  /// Throws an exception if the Rust engine is not available or fails.
  ///
  /// Automatically injects `player_id` from the active player in [currentState]
  /// if the command's payload does not already contain it.
  Future<BridgeResponse> executeCommand({
    required BridgeCommand command,
    required Map<String, dynamic> currentState,
  }) async {
    if (!_engine.isAvailable) {
      throw Exception('Rust engine not available');
    }

    // Auto-inject player_id from the active player if not already present
    var cmd = command;
    final params = command.params ?? <String, dynamic>{};
    if (!params.containsKey('player_id')) {
      final players = (currentState['players'] as List<dynamic>?) ?? [];
      final idx = (currentState['active_player_index'] as num?)?.toInt() ?? 0;
      if (idx < players.length) {
        final player = players[idx] as Map<String, dynamic>;
        final pid = player['id'] as String?;
        if (pid != null) {
          final mergedParams = Map<String, dynamic>.from(params);
          mergedParams['player_id'] = pid;
          cmd = BridgeCommand(type: cmd.type, params: mergedParams);
        }
      }
    }

    final request = BridgeRequest(command: cmd, state: currentState);
    final jsonPayload = buildRequest(request);
    final responseText = _engine.execute(jsonPayload);
    if (responseText == null) {
      throw Exception('Rust engine returned null');
    }

    final decoded = jsonDecode(responseText);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Rust engine returned non-map response');
    }
    if (decoded.containsKey('error')) {
      throw Exception('Rust engine error: ${decoded['error']}');
    }
    if (!decoded.containsKey('events') || !decoded.containsKey('state')) {
      throw Exception('Rust engine response missing events/state fields');
    }
    return BridgeResponse.fromJson(decoded);
  }

  /// Parse a list of players from a GameState JSON map.
  static List<PlayerViewModel> parsePlayers(Map<String, dynamic> state) {
    final playersList = (state['players'] as List<dynamic>?)
            ?.map((e) => PlayerViewModel.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    return playersList;
  }
}
