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

  /// Create a new game from map JSON + player configs.
  /// This is handled specially by the bridge (not through the normal
  /// command pipeline) and returns a full GameState without requiring
  /// a prior state.
  factory BridgeCommand.createGame(
    Map<String, dynamic> mapJson,
    List<Map<String, dynamic>> players, {
    int seed = 0,
  }) =>
      BridgeCommand(
        type: 'core:command:create_game',
        params: {
          'map': mapJson,
          'players': players,
          'seed': seed,
        },
      );

  /// Execute one complete turn for the current AI-controlled active player.
  /// All game logic runs on the Rust side; Flutter merely displays the events.
  factory BridgeCommand.processAiTurn() =>
      const BridgeCommand(type: 'core:command:process_ai_turn');

  /// Get the LLM context + prompt for the current game state.
  /// Returns structured context and a human-readable prompt for LLM decision-making.
  factory BridgeCommand.llmContext({String? playerId}) =>
      BridgeCommand(
        type: 'core:command:llm_context',
        params: {if (playerId != null) 'player_id': playerId},
      );

  /// Evaluate an AI decision using the strategic engine (no state mutation).
  ///
  /// Supported actions:
  /// - `buy`: decide whether to buy a property → `{decision: "buy"|"pass", score: N}`
  /// - `upgrade_target`: find best property to upgrade → `{target: "tile_id"|null, score: N}`
  /// - `score`: get a numerical score for a property → `{score: N}`
  factory BridgeCommand.aiEvaluate({
    required String action,
    String? tileId,
    String? playerId,
  }) =>
      BridgeCommand(
        type: 'core:command:ai_evaluate',
        params: {
          'action': action,
          if (tileId != null) 'tile_id': tileId,
          if (playerId != null) 'player_id': playerId,
        },
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
typedef SaEngineGetConstantsNative = Pointer<Utf8> Function();
typedef SaEngineGetConstantsDart = Pointer<Utf8> Function();
typedef SaEngineFreeStringNative = Void Function(Pointer<Utf8>);
typedef SaEngineFreeStringDart = void Function(Pointer<Utf8>);

// Map loading FFI bindings
typedef SaEngineLoadMapNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineLoadMapDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineScanMapsNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineScanMapsDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineGetThumbnailNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineGetThumbnailDart = Pointer<Utf8> Function(Pointer<Utf8>);

// Session sync FFI bindings
typedef SaEngineSyncDiffNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineSyncDiffDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineSyncApplyNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineSyncApplyDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineSyncConflictNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineSyncConflictDart = Pointer<Utf8> Function(Pointer<Utf8>);

// Config FFI bindings
typedef SaEngineConfigLoadNative = Pointer<Utf8> Function();
typedef SaEngineConfigLoadDart = Pointer<Utf8> Function();
typedef SaEngineConfigSaveNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineConfigSaveDart = Pointer<Utf8> Function(Pointer<Utf8>);

// Save/Load FFI bindings
typedef SaEngineSaveGameNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineSaveGameDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineLoadGameNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineLoadGameDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineListSavesNative = Pointer<Utf8> Function();
typedef SaEngineListSavesDart = Pointer<Utf8> Function();
typedef SaEngineDeleteSaveNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaEngineDeleteSaveDart = Pointer<Utf8> Function(Pointer<Utf8>);

/// Loads the Rust shared library and binds the native functions.
class RustEngineBinding {
  static RustEngineBinding? _instance;

  /// Get or create the global RustEngineBinding singleton.
  factory RustEngineBinding() {
    _instance ??= RustEngineBinding._();
    return _instance!;
  }

  RustEngineBinding._() {
    _init();
  }

  late final DynamicLibrary _lib;
  late final SaEngineExecuteDart _execute;
  SaEnginePluginCtlDart? _pluginCtl;
  SaEngineGetConstantsDart? _getConstants;
  late final SaEngineFreeStringDart _freeString;
  SaEngineLoadMapDart? _loadMap;
  SaEngineScanMapsDart? _scanMaps;
  SaEngineGetThumbnailDart? _getThumbnail;
  SaEngineConfigLoadDart? _configLoad;
  SaEngineConfigSaveDart? _configSave;
  SaEngineSaveGameDart? _saveGame;
  SaEngineLoadGameDart? _loadGame;
  SaEngineListSavesDart? _listSaves;
  SaEngineDeleteSaveDart? _deleteSave;
  SaEngineSyncDiffDart? _syncDiff;
  SaEngineSyncApplyDart? _syncApply;
  SaEngineSyncConflictDart? _syncConflict;
  bool _available = false;
  /// Raw JSON string from sa_engine_get_constants, or null if unavailable.
  String? _constantsJson;

  void _init() {
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
      // Map loading FFI functions
      try {
        _loadMap = _lib
            .lookupFunction<SaEngineLoadMapNative, SaEngineLoadMapDart>(
                'sa_engine_load_map');
        _scanMaps = _lib
            .lookupFunction<SaEngineScanMapsNative, SaEngineScanMapsDart>(
                'sa_engine_scan_maps');
        _getThumbnail = _lib
            .lookupFunction<SaEngineGetThumbnailNative, SaEngineGetThumbnailDart>(
                'sa_engine_get_thumbnail');
      } catch (_) {
        debugPrint('sa_engine_map functions not available');
      }
      // Config FFI functions
      try {
        _configLoad = _lib.lookupFunction<SaEngineConfigLoadNative,
            SaEngineConfigLoadDart>('sa_engine_config_load');
        _configSave = _lib.lookupFunction<SaEngineConfigSaveNative,
            SaEngineConfigSaveDart>('sa_engine_config_save');
        debugPrint('Config FFI functions loaded');
      } catch (_) {
        debugPrint('sa_engine_config_* functions not available');
      }
      // Save/Load FFI functions
      try {
        _saveGame = _lib.lookupFunction<SaEngineSaveGameNative, SaEngineSaveGameDart>(
            'sa_engine_save_game');
        _loadGame = _lib.lookupFunction<SaEngineLoadGameNative, SaEngineLoadGameDart>(
            'sa_engine_load_game');
        _listSaves = _lib.lookupFunction<SaEngineListSavesNative, SaEngineListSavesDart>(
            'sa_engine_list_saves');
        _deleteSave = _lib.lookupFunction<SaEngineDeleteSaveNative, SaEngineDeleteSaveDart>(
            'sa_engine_delete_save');
        debugPrint('Save/Load FFI functions loaded');
      } catch (_) {
        debugPrint('sa_engine_save/load functions not available');
      }
      // Session sync FFI functions
      try {
        _syncDiff = _lib.lookupFunction<SaEngineSyncDiffNative, SaEngineSyncDiffDart>(
            'sa_engine_sync_diff');
        debugPrint('Session sync FFI function loaded');
      } catch (_) {
        debugPrint('sa_engine_sync_diff not available');
      }
      try {
        _syncApply = _lib.lookupFunction<SaEngineSyncApplyNative, SaEngineSyncApplyDart>(
            'sa_engine_sync_apply');
        debugPrint('sa_engine_sync_apply loaded');
      } catch (_) {
        debugPrint('sa_engine_sync_apply not available');
      }
      try {
        _syncConflict = _lib.lookupFunction<SaEngineSyncConflictNative, SaEngineSyncConflictDart>(
            'sa_engine_sync_conflict');
        debugPrint('sa_engine_sync_conflict loaded');
      } catch (_) {
        debugPrint('sa_engine_sync_conflict not available');
      }
      // Load game constants from Rust engine
      try {
        _getConstants = _lib
            .lookupFunction<SaEngineGetConstantsNative, SaEngineGetConstantsDart>(
                'sa_engine_get_constants');
        final constantsPtr = _getConstants!();
        _constantsJson = constantsPtr.toDartString();
        _freeString(constantsPtr);
        debugPrint('Game constants loaded from Rust engine');
      } catch (_) {
        debugPrint('sa_engine_get_constants not available');
      }
      _available = true;
      debugPrint('Rust engine FFI bridge initialized successfully');
    } catch (e) {
      debugPrint('Failed to load Rust engine: $e');
      _available = false;
    }
  }

  bool get isAvailable => _available;

  /// Raw JSON string from sa_engine_get_constants, or null if unavailable.
  String? get constantsJson => _constantsJson;

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

  /// Load a map from a file path (.smap or .json). Returns MapDefinition JSON.
  String? loadMap(String path) {
    if (!_available || _loadMap == null) return null;
    final inputPtr = path.toNativeUtf8();
    final resultPtr = _loadMap!(inputPtr);
    calloc.free(inputPtr);
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  /// Scan a directory for map files. Returns JSON array of map metadata.
  String? scanMaps(String dirPath) {
    if (!_available || _scanMaps == null) return null;
    final inputPtr = dirPath.toNativeUtf8();
    final resultPtr = _scanMaps!(inputPtr);
    calloc.free(inputPtr);
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  /// Get thumbnail from a .smap file. Returns JSON with base64 PNG or error.
  String? getThumbnail(String path) {
    if (!_available || _getThumbnail == null) return null;
    final inputPtr = path.toNativeUtf8();
    final resultPtr = _getThumbnail!(inputPtr);
    calloc.free(inputPtr);
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  /// Load configuration from the Rust engine's FileConfigStore.
  /// Returns JSON of the entire ConfigDocument, or error JSON.
  String? configLoad() {
    if (!_available || _configLoad == null) return null;
    final resultPtr = _configLoad!();
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  /// Save configuration to the Rust engine's FileConfigStore.
  /// Input: JSON string of the entire ConfigDocument.
  /// Returns `{"ok": true}` or `{"ok": false, "error": "..."}`.
  String? configSave(String configJson) {
    if (!_available || _configSave == null) return null;
    final inputPtr = configJson.toNativeUtf8();
    final resultPtr = _configSave!(inputPtr);
    calloc.free(inputPtr);
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  // ── Save/Load FFI methods ──────────────────────────────────────────────────

  /// Save a game state to disk via the Rust engine.
  /// Input: JSON string `{"file_name": "...", "state": {...}}`.
  /// Returns `{"ok": true}` or `{"ok": false, "error": "..."}`.
  String? saveGame(String payloadJson) {
    if (!_available || _saveGame == null) return null;
    final inputPtr = payloadJson.toNativeUtf8();
    final resultPtr = _saveGame!(inputPtr);
    calloc.free(inputPtr);
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  /// Load a game state from disk via the Rust engine.
  /// Input: save file name (e.g. `"mygame.sav"`).
  /// Returns full SaveGame JSON (`{"version": "...", "state": {...}}`)
  /// or `{"ok": false, "error": "..."}`.
  String? loadGame(String fileName) {
    if (!_available || _loadGame == null) return null;
    final inputPtr = fileName.toNativeUtf8();
    final resultPtr = _loadGame!(inputPtr);
    calloc.free(inputPtr);
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  /// List all save files via the Rust engine.
  /// Returns JSON array of `[{"file_name": "...", "path": "..."}]`.
  String? listSaves() {
    if (!_available || _listSaves == null) return null;
    final resultPtr = _listSaves!();
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  /// Delete a save file via the Rust engine.
  /// Input: save file name (e.g. `"mygame.sav"`).
  /// Returns `{"ok": true}` or `{"ok": false, "error": "..."}`.
  String? deleteSave(String fileName) {
    if (!_available || _deleteSave == null) return null;
    final inputPtr = fileName.toNativeUtf8();
    final resultPtr = _deleteSave!(inputPtr);
    calloc.free(inputPtr);
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  // ── Session sync FFI methods ──────────────────────────────────────────────

  /// Compute a state diff for network sync via the Rust engine.
  /// Input: JSON string `{"before": GameState, "after": GameState}`.
  /// Returns: JSON diff string, or null if unavailable.
  String? syncDiff(String payloadJson) {
    if (!_available || _syncDiff == null) return null;
    final inputPtr = payloadJson.toNativeUtf8();
    final resultPtr = _syncDiff!(inputPtr);
    calloc.free(inputPtr);
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  /// Apply a diff to a GameState via the Rust engine.
  /// Input: JSON string `{"state": GameState, "diff": {...}}`.
  /// Returns: JSON of the patched GameState, or null if unavailable.
  String? syncApply(String payloadJson) {
    if (!_available || _syncApply == null) return null;
    final inputPtr = payloadJson.toNativeUtf8();
    final resultPtr = _syncApply!(inputPtr);
    calloc.free(inputPtr);
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  /// Check for revision conflict via the Rust engine.
  /// Input: JSON string `{"local_rev": u64, "remote_rev": u64}`.
  /// Returns: `{"conflict": true/false}`, or null if unavailable.
  String? syncConflict(String payloadJson) {
    if (!_available || _syncConflict == null) return null;
    final inputPtr = payloadJson.toNativeUtf8();
    final resultPtr = _syncConflict!(inputPtr);
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

  /// Get the underlying Rust engine binding for direct FFI access.
  RustEngineBinding get engine => _engine;

  /// Game constants loaded from the Rust engine, or null if unavailable.
  Map<String, dynamic>? get gameConstants {
    final json = _engine.constantsJson;
    if (json == null) return null;
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

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

  /// Call the strategic AI evaluation engine (no state mutation).
  ///
  /// Returns the raw JSON result from the Rust engine.
  /// Example: `{action: "buy", decision: "buy", score: 75, tile_id: "prop_1"}`
  Future<Map<String, dynamic>> evaluateAi({
    required String action,
    String? tileId,
    String? playerId,
    required Map<String, dynamic> currentState,
  }) async {
    if (!_engine.isAvailable) {
      throw Exception('Rust engine not available');
    }

    // Auto-inject player_id from active player if not provided
    var pid = playerId;
    if (pid == null) {
      final players = (currentState['players'] as List<dynamic>?) ?? [];
      final idx = (currentState['active_player_index'] as num?)?.toInt() ?? 0;
      if (idx < players.length) {
        final player = players[idx] as Map<String, dynamic>;
        pid = player['id'] as String?;
      }
    }

    final cmd = BridgeCommand.aiEvaluate(
      action: action,
      tileId: tileId,
      playerId: pid,
    );
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
    return decoded;
  }

  // ── Map loading FFI proxy methods ──────────────────────────────────────────

  /// Load a map from a file path (.smap or .json). Returns MapDefinition JSON.
  String? loadMap(String path) => _engine.loadMap(path);

  /// Scan a directory for map files. Returns JSON array of map metadata.
  String? scanMaps(String dirPath) => _engine.scanMaps(dirPath);

  /// Get thumbnail from a .smap file. Returns JSON with base64 PNG or error.
  String? getThumbnail(String path) => _engine.getThumbnail(path);

  // ── Config FFI proxy methods ───────────────────────────────────────────────

  /// Load configuration from the Rust engine's FileConfigStore.
  /// Returns JSON of the entire ConfigDocument, or error JSON.
  String? configLoad() => _engine.configLoad();

  /// Save configuration to the Rust engine's FileConfigStore.
  /// Input: JSON string of the entire ConfigDocument.
  /// Returns `{"ok": true}` or `{"ok": false, "error": "..."}`.
  String? configSave(String configJson) => _engine.configSave(configJson);

  // ── Save/Load FFI proxy methods ────────────────────────────────────────────

  /// Save a game state to disk via the Rust engine.
  /// Input: JSON string `{"file_name": "...", "state": {...}}`.
  /// Returns `{"ok": true}` or `{"ok": false, "error": "..."}`.
  String? saveGame(String payloadJson) => _engine.saveGame(payloadJson);

  /// Load a game state from disk via the Rust engine.
  /// Input: save file name (e.g. `"mygame.sav"`).
  /// Returns full SaveGame JSON or error.
  String? loadGame(String fileName) => _engine.loadGame(fileName);

  /// List all save files via the Rust engine.
  /// Returns JSON array of save metadata.
  String? listSaves() => _engine.listSaves();

  /// Delete a save file via the Rust engine.
  /// Returns `{"ok": true}` or `{"ok": false, "error": "..."}`.
  String? deleteSave(String fileName) => _engine.deleteSave(fileName);

  // ── Session sync FFI proxy methods ─────────────────────────────────────────

  /// Compute a state diff for network sync via the Rust engine.
  /// Input: JSON string `{"before": GameState, "after": GameState}`.
  /// Returns: JSON diff string, or null if unavailable.
  String? syncDiff(String payloadJson) => _engine.syncDiff(payloadJson);

  /// Apply a diff to a GameState via the Rust engine.
  /// Input: JSON string `{"state": GameState, "diff": {...}}`.
  /// Returns: JSON of the patched GameState, or null if unavailable.
  String? syncApply(String payloadJson) => _engine.syncApply(payloadJson);

  /// Check for revision conflict via the Rust engine.
  /// Input: JSON string `{"local_rev": u64, "remote_rev": u64}`.
  /// Returns: `{"conflict": true/false}`, or null if unavailable.
  String? syncConflict(String payloadJson) => _engine.syncConflict(payloadJson);

  /// Get the LLM context + prompt for the current game state.
  /// Returns `{context: LlmContext, prompt: String, player_id: String}`.
  /// The prompt can be sent to an LLM API for decision-making.
  ///
  /// [eventLog] — optional list of recent action log entries to include
  /// in the LLM context so it knows what happened in recent turns.
  Future<Map<String, dynamic>> getLlmContext({
    String? playerId,
    required Map<String, dynamic> currentState,
    List<String>? eventLog,
  }) async {
    if (!_engine.isAvailable) {
      throw Exception('Rust engine not available');
    }

    var pid = playerId;
    if (pid == null) {
      final players = (currentState['players'] as List<dynamic>?) ?? [];
      final idx = (currentState['active_player_index'] as num?)?.toInt() ?? 0;
      if (idx < players.length) {
        final player = players[idx] as Map<String, dynamic>;
        pid = player['id'] as String?;
      }
    }

    // Build params including player_id and optional event_log
    final params = <String, dynamic>{'player_id': pid};
    if (eventLog != null && eventLog.isNotEmpty) {
      params['event_log'] = eventLog;
    }

    final cmd = BridgeCommand(
      type: 'core:command:llm_context',
      params: params,
    );
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
    return decoded;
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
