import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'bridge_client.dart';
import 'game_constants.dart';

/// Client-side configuration provider for saMonopoly.
///
/// Mirrors the Rust-side config types defined in
/// `crates/domain/src/config.rs`.
///
/// In standalone (simulation) mode, config is stored in local memory.
/// When the native FFI bridge is connected via [client], config is loaded
/// from and persisted to the Rust engine's FileConfigStore.
class ConfigProvider {
  /// Optional native bridge client for Rust engine persistence.
  final BridgeClient? _client;

  // ── In-memory defaults (used when native bridge is unavailable) ──────────

  AppConfig _app = const AppConfig();
  GameConfig _game = const GameConfig();
  AiConfig _ai = const AiConfig();
  LlmApiConfig _llmApi = const LlmApiConfig();
  NetworkConfig _network = const NetworkConfig();
  ContentConfig _content = const ContentConfig();

  /// Create a [ConfigProvider] optionally backed by a [BridgeClient].
  ///
  /// When [client] is provided, the constructor immediately loads persisted
  /// configuration from the Rust engine via [BridgeClient.configLoad].
  ConfigProvider({BridgeClient? client}) : _client = client {
    _loadFromEngine();
  }

  // ── Accessors ────────────────────────────────────────────────────────────

  AppConfig get app => _app;
  GameConfig get game => _game;
  AiConfig get ai => _ai;
  LlmApiConfig get llmApi => _llmApi;
  NetworkConfig get network => _network;
  ContentConfig get content => _content;

  // ── Mutation ─────────────────────────────────────────────────────────────

  void updateApp(AppConfig config) {
    _app = config;
    _persist('app', config.toJson());
  }

  void updateGame(GameConfig config) {
    _game = config;
    _persist('game', config.toJson());
  }

  void updateAi(AiConfig config) {
    _ai = config;
    _persist('ai', config.toJson());
  }

  void updateNetwork(NetworkConfig config) {
    _network = config;
    _persist('network', config.toJson());
  }

  void updateContent(ContentConfig config) {
    _content = config;
    _persist('content', config.toJson());
  }

  /// Reload LLM API config from Rust engine (picks up UI changes).
  ///
  /// Returns a [ConfigSaveResult] so callers can detect a failed reload
  /// instead of silently proceeding with stale or default configuration.
  ConfigSaveResult reloadLlmApi() {
    final client = _client;
    if (client == null) {
      return const ConfigSaveResult.failure('配置存储不可用');
    }
    final result = client.configLoad();
    if (result == null) {
      return const ConfigSaveResult.failure('无法从引擎加载配置');
    }
    try {
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      if (decoded['ok'] == false) {
        return ConfigSaveResult.failure(
            decoded['error'] as String? ?? '配置加载失败');
      }
      final sections = decoded['sections'] as Map<String, dynamic>?;
      if (sections != null && sections['llm_api'] != null) {
        _llmApi = LlmApiConfig.fromJson(sections['llm_api'] as Map<String, dynamic>);
        debugPrint('[Config] Reloaded LLM API config: ${_llmApi.a2cmEndpoint}');
      }
      return const ConfigSaveResult.success();
    } catch (e) {
      return ConfigSaveResult.failure('无法解析配置: $e');
    }
  }

  void updateLlmApi(LlmApiConfig config) {
    _llmApi = config;
    _persist('llm_api', config.toJson());
  }

  /// Persist related settings in one write so the UI cannot report a partial save.
  ConfigSaveResult updateSettings({
    required GameConfig game,
    required LlmApiConfig llmApi,
  }) {
    final previousGame = _game;
    final previousLlmApi = _llmApi;
    _game = game;
    _llmApi = llmApi;
    ConfigSaveResult result;
    try {
      result = _persistSections({
        'game': game.toJson(),
        'llm_api': llmApi.toJson(),
      });
    } catch (e) {
      // Persist/encode may throw (e.g. non-finite numbers). Keep the save
      // exception-atomic so failed saves never leave stale in-memory state.
      result = ConfigSaveResult.failure('配置保存异常: $e');
    }
    if (!result.success) {
      _game = previousGame;
      _llmApi = previousLlmApi;
    }
    return result;
  }

  // ── Engine persistence ──────────────────────────────────────────────────

  /// Load all sections from the Rust engine's FileConfigStore (if connected).
  /// Falls back to in-memory defaults if the engine is unavailable or returns
  /// invalid data.
  void _loadFromEngine() {
    final client = _client;
    if (client == null) return;

    final result = client.configLoad();
    if (result == null) return;

    try {
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      // If the result contains an "ok": false field, it's an error response.
      if (decoded['ok'] == false) {
        debugPrint('Config load error: ${decoded['error']}');
        return;
      }
      final sections = decoded['sections'] as Map<String, dynamic>?;
      if (sections == null) return;

      // Parse each known section if present.
      if (sections['app'] != null) {
        _app = AppConfig.fromJson(
            sections['app'] as Map<String, dynamic>);
      }
      if (sections['game'] != null) {
        _game = GameConfig.fromJson(
            sections['game'] as Map<String, dynamic>);
      }
      if (sections['ai'] != null) {
        _ai = AiConfig.fromJson(
            sections['ai'] as Map<String, dynamic>);
      }
      if (sections['network'] != null) {
        _network = NetworkConfig.fromJson(
            sections['network'] as Map<String, dynamic>);
      }
      if (sections['content'] != null) {
        _content = ContentConfig.fromJson(
            sections['content'] as Map<String, dynamic>);
      }
      if (sections['llm_api'] != null) {
        _llmApi = LlmApiConfig.fromJson(
            sections['llm_api'] as Map<String, dynamic>);
      }

      debugPrint('Config loaded from Rust engine');
    } catch (e) {
      debugPrint('Failed to parse config from engine: $e');
    }
  }

  /// Persist a config section to the Rust engine's FileConfigStore.
  ///
  /// Loads the full current document from the engine, merges the updated
  /// [section] with the new [value], and saves it back.  In standalone mode
  /// (no bridge client) this is a no-op.
  void _persist(String section, Map<String, dynamic> value) {
    _persistSections({section: value});
  }

  ConfigSaveResult _persistSections(
      Map<String, Map<String, dynamic>> updates) {
    final client = _client;
    if (client == null) {
      return const ConfigSaveResult.failure('配置存储不可用');
    }

    // Load the existing config document from the engine so we merge,
    // not overwrite, other sections.
    String? existingJson = client.configLoad();
    Map<String, dynamic> doc;
    if (existingJson != null) {
      try {
        doc = jsonDecode(existingJson) as Map<String, dynamic>;
      } catch (_) {
        doc = {'version': 1, 'sections': <String, dynamic>{}};
      }
    } else {
      doc = {'version': 1, 'sections': <String, dynamic>{}};
    }

    // Ensure sections map exists.
    doc['sections'] ??= <String, dynamic>{};
    (doc['sections'] as Map<String, dynamic>).addAll(updates);

    // Save the full document back.
    final jsonStr = jsonEncode(doc);
    final response = client.configSave(jsonStr);
    if (response == null) {
      return const ConfigSaveResult.failure('Rust 配置存储不可用');
    }
    try {
      final decoded = jsonDecode(response) as Map<String, dynamic>;
      if (decoded['ok'] == true) return const ConfigSaveResult.success();
      return ConfigSaveResult.failure(
          decoded['error'] as String? ?? '配置保存失败');
    } catch (e) {
      return ConfigSaveResult.failure('无法解析配置保存结果: $e');
    }
  }
}

class ConfigSaveResult {
  final bool success;
  final String? error;

  const ConfigSaveResult.success()
      : success = true,
        error = null;

  const ConfigSaveResult.failure(this.error) : success = false;
}

// ============================================================================
// AppConfig
// ============================================================================

class AppConfig {
  final String language;
  final String theme;
  final bool soundEnabled;
  final double animationSpeed;
  final double boardCameraZoom;

  const AppConfig({
    this.language = 'en',
    this.theme = 'system',
    this.soundEnabled = true,
    this.animationSpeed = 1.0,
    this.boardCameraZoom = 1.0,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        language: json['language'] as String? ?? 'en',
        theme: json['theme'] as String? ?? 'system',
        soundEnabled: json['sound_enabled'] as bool? ?? true,
        animationSpeed: (json['animation_speed'] as num?)?.toDouble() ?? 1.0,
        boardCameraZoom:
            (json['board_camera_zoom'] as num?)?.toDouble() ?? 1.0,
      );

  Map<String, dynamic> toJson() => {
        'language': language,
        'theme': theme,
        'sound_enabled': soundEnabled,
        'animation_speed': animationSpeed,
        'board_camera_zoom': boardCameraZoom,
      };
}

// ============================================================================
// GameConfig
// ============================================================================

class GameConfig {
  final String rulesetId;
  final int startingCash;
  final int maxPlayers;
  final bool stockMarketEnabled;
  final bool lotteryEnabled;
  final int passStartBonus;
  final int jailEscapeTurns;
  final int hospitalRecoveryTurns;
  final bool auctionEnabled;
  final bool mortgageEnabled;
  final bool tradeEnabled;
  /// Maximum property upgrade level (0 = upgrades disabled).
  /// Rent and upgrade cost are calculated by formula from the current level.
  final int maxUpgradeLevel;
  /// Whether Extension properties (utilities: Electric Co, Water Works)
  /// can also be upgraded using the same formula-based system.
  final bool extensionUpgradeEnabled;
  /// Whether group rent is enabled.  When enabled, if all properties in a
  /// linked group are owned by the same player, rent is the sum of all
  /// group members' individual rent.
  final bool groupRentEnabled;

  const GameConfig({
    this.rulesetId = 'classic',
    this.startingCash = CommandConstants.startingCash,
    this.maxPlayers = 4,
    this.stockMarketEnabled = true,
    this.lotteryEnabled = true,
    this.passStartBonus = CommandConstants.passStartBonus,
    this.jailEscapeTurns = GameDefaults.baseJailTurns,
    this.hospitalRecoveryTurns = CommandConstants.hospitalRecoveryTurns,
    this.auctionEnabled = true,
    this.mortgageEnabled = true,
    this.tradeEnabled = true,
    this.maxUpgradeLevel = GameDefaults.maxUpgradeLevel,
    this.extensionUpgradeEnabled = true,
    this.groupRentEnabled = true,
  });

  factory GameConfig.fromJson(Map<String, dynamic> json) => GameConfig(
        rulesetId: json['ruleset_id'] as String? ?? 'classic',
        startingCash: (json['starting_cash'] as num?)?.toInt() ?? CommandConstants.startingCash,
        maxPlayers: (json['max_players'] as num?)?.toInt() ?? 4,
        stockMarketEnabled:
            json['stock_market_enabled'] as bool? ?? true,
        lotteryEnabled: json['lottery_enabled'] as bool? ?? true,
        passStartBonus: (json['pass_start_bonus'] as num?)?.toInt() ?? CommandConstants.passStartBonus,
        jailEscapeTurns:
            (json['jail_escape_turns'] as num?)?.toInt() ?? GameDefaults.baseJailTurns,
        hospitalRecoveryTurns:
            (json['hospital_recovery_turns'] as num?)?.toInt() ?? CommandConstants.hospitalRecoveryTurns,
        auctionEnabled: json['auction_enabled'] as bool? ?? true,
        mortgageEnabled: json['mortgage_enabled'] as bool? ?? true,
        tradeEnabled: json['trade_enabled'] as bool? ?? true,
        maxUpgradeLevel: (json['max_upgrade_level'] as num?)?.toInt() ?? GameDefaults.maxUpgradeLevel,
        extensionUpgradeEnabled:
            json['extension_upgrade_enabled'] as bool? ?? true,
        groupRentEnabled:
            json['group_rent_enabled'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'ruleset_id': rulesetId,
        'starting_cash': startingCash,
        'max_players': maxPlayers,
        'stock_market_enabled': stockMarketEnabled,
        'lottery_enabled': lotteryEnabled,
        'pass_start_bonus': passStartBonus,
        'jail_escape_turns': jailEscapeTurns,
        'hospital_recovery_turns': hospitalRecoveryTurns,
        'auction_enabled': auctionEnabled,
        'mortgage_enabled': mortgageEnabled,
        'trade_enabled': tradeEnabled,
        'max_upgrade_level': maxUpgradeLevel,
        'extension_upgrade_enabled': extensionUpgradeEnabled,
        'group_rent_enabled': groupRentEnabled,
      };
}

// ============================================================================
// AiConfig
// ============================================================================

class AiConfig {
  final Map<String, AiAgentKind> agentMap;
  final AiAgentKind defaultAgent;

  const AiConfig({
    this.agentMap = const {},
    this.defaultAgent = AiAgentKind.heuristic,
  });

  factory AiConfig.fromJson(Map<String, dynamic> json) => AiConfig(
        agentMap: (json['agent_map'] as Map<String, dynamic>?)
                ?.map((k, v) =>
                    MapEntry(k, AiAgentKind.fromJson(v as Map<String, dynamic>)))
                .toString() ==
                null
            ? {}
            : {},
        defaultAgent: json['default_agent'] != null
            ? AiAgentKind.fromJson(
                json['default_agent'] as Map<String, dynamic>)
            : AiAgentKind.heuristic,
      );

  Map<String, dynamic> toJson() => {
        'agent_map': agentMap.map((k, v) => MapEntry(k, v.toJson())),
        'default_agent': defaultAgent.toJson(),
      };
}

class AiAgentKind {
  final String type;
  final int? simulations;
  final String? model;
  final double? temperature;

  const AiAgentKind._({
    required this.type,
    this.simulations,
    this.model,
    this.temperature,
  });

  static const AiAgentKind heuristic = AiAgentKind._(type: 'Heuristic');
  static const AiAgentKind monteCarlo =
      AiAgentKind._(type: 'MonteCarlo', simulations: 1000);
  static AiAgentKind llm({String model = 'gpt-4', double temperature = 0.7}) =>
      AiAgentKind._(
        type: 'Llm',
        model: model,
        temperature: temperature,
      );

  factory AiAgentKind.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? 'Heuristic';
    switch (type) {
      case 'Heuristic':
        return heuristic;
      case 'MonteCarlo':
        return AiAgentKind._(
          type: 'MonteCarlo',
          simulations: (json['simulations'] as num?)?.toInt() ?? 1000,
        );
      case 'Llm':
        return AiAgentKind._(
          type: 'Llm',
          model: json['model'] as String? ?? 'gpt-4',
          temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
        );
      default:
        return heuristic;
    }
  }

  Map<String, dynamic> toJson() {
    switch (type) {
      case 'Heuristic':
        return {'type': 'Heuristic'};
      case 'MonteCarlo':
        return {'type': 'MonteCarlo', 'simulations': simulations ?? 1000};
      case 'Llm':
        return {
          'type': 'Llm',
          'model': model ?? 'gpt-4',
          'temperature': temperature ?? 0.7,
        };
      default:
        return {'type': 'Heuristic'};
    }
  }
}

// ============================================================================
// NetworkConfig
// ============================================================================

class NetworkConfig {
  final String host;
  final int port;
  final String path;
  final bool tls;
  final int maxMessageSize;
  final int pingIntervalSecs;

  const NetworkConfig({
    this.host = '127.0.0.1',
    this.port = 9000,
    this.path = '/ws',
    this.tls = true,
    this.maxMessageSize = 262144,
    this.pingIntervalSecs = 30,
  });

  factory NetworkConfig.fromJson(Map<String, dynamic> json) => NetworkConfig(
        host: json['host'] as String? ?? '127.0.0.1',
        port: (json['port'] as num?)?.toInt() ?? 9000,
        path: json['path'] as String? ?? '/ws',
        tls: json['tls'] as bool? ?? true,
        maxMessageSize: (json['max_message_size'] as num?)?.toInt() ?? 262144,
        pingIntervalSecs:
            (json['ping_interval_secs'] as num?)?.toInt() ?? 30,
      );

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'path': path,
        'tls': tls,
        'max_message_size': maxMessageSize,
        'ping_interval_secs': pingIntervalSecs,
      };
}

// ============================================================================
// ContentConfig
// ============================================================================

class ContentConfig {
  final List<String> enabledMaps;
  final List<String> enabledPacks;
  final List<String> customContentPaths;

  const ContentConfig({
    this.enabledMaps = const ['classic'],
    this.enabledPacks = const ['classic_pack'],
    this.customContentPaths = const [],
  });

  factory ContentConfig.fromJson(Map<String, dynamic> json) => ContentConfig(
        enabledMaps: (json['enabled_maps'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            ['classic'],
        enabledPacks: (json['enabled_packs'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            ['classic_pack'],
        customContentPaths: (json['custom_content_paths'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            [],
      );

  Map<String, dynamic> toJson() => {
        'enabled_maps': enabledMaps,
        'enabled_packs': enabledPacks,
        'custom_content_paths': customContentPaths,
      };
}

// ============================================================================
// LlmApiConfig
// ============================================================================

/// LLM API connection settings, persisted as the "llm_api" section.
class LlmApiConfig {
  /// Backend type: "direct" for OpenAI-compatible API, "a2cm" for A2CM companion.
  final String backend;
  final String apiEndpoint;
  final String a2cmEndpoint;
  final String apiKey;
  final String model;
  final double temperature;
  final int maxTokens;
  final String customHeaders;

  const LlmApiConfig({
    this.backend = 'direct',
    this.apiEndpoint = 'https://api.openai.com/v1/chat/completions',
    this.a2cmEndpoint = 'http://localhost:8000',
    this.apiKey = '',
    this.model = 'gpt-4',
    this.temperature = 0.7,
    this.maxTokens = 512,
    this.customHeaders = '',
  });

  factory LlmApiConfig.fromJson(Map<String, dynamic> json) => LlmApiConfig(
        backend: json['backend'] as String? ?? 'direct',
        apiEndpoint:
            json['api_endpoint'] as String? ?? 'https://api.openai.com/v1/chat/completions',
        a2cmEndpoint: json['a2cm_endpoint'] as String? ?? 'http://localhost:8000',
        apiKey: json['api_key'] as String? ?? '',
        model: json['model'] as String? ?? 'gpt-4',
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
        maxTokens: (json['max_tokens'] as num?)?.toInt() ?? 512,
        customHeaders: json['custom_headers'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'backend': backend,
        'api_endpoint': apiEndpoint,
        'a2cm_endpoint': a2cmEndpoint,
        'api_key': apiKey,
        'model': model,
        'temperature': temperature,
        'max_tokens': maxTokens,
        'custom_headers': customHeaders,
      };
}
