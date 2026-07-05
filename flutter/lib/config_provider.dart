import 'dart:convert';

/// Client-side configuration provider for saMonopoly.
///
/// Mirrors the Rust-side config types defined in
/// `crates/domain/src/config.rs`.
///
/// In standalone (simulation) mode, config is stored in local memory.
/// When the native FFI bridge is connected, config commands are forwarded
/// to the Rust engine for persistent file storage.
class ConfigProvider {
  // ── In-memory defaults (used when native bridge is unavailable) ──────────

  AppConfig _app = const AppConfig();
  GameConfig _game = const GameConfig();
  AiConfig _ai = const AiConfig();
  NetworkConfig _network = const NetworkConfig();
  ContentConfig _content = const ContentConfig();

  // ── Accessors ────────────────────────────────────────────────────────────

  AppConfig get app => _app;
  GameConfig get game => _game;
  AiConfig get ai => _ai;
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

  /// Persist a config section.  In simulation mode this is a no-op;
  /// when the native bridge is connected, the section is forwarded to the
  /// Rust engine which writes it to `config.sav`.
  void _persist(String section, Map<String, dynamic> value) {
    // TODO: forward to native bridge when connected
    // e.g.  NativeBridge.executeJson('{"ConfigSet":{"section":"$section","value":${jsonEncode(value)}}}');
  }
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

  const GameConfig({
    this.rulesetId = 'classic',
    this.startingCash = 1500,
    this.maxPlayers = 4,
    this.stockMarketEnabled = false,
    this.lotteryEnabled = false,
    this.passStartBonus = 200,
    this.jailEscapeTurns = 3,
    this.hospitalRecoveryTurns = 2,
    this.auctionEnabled = true,
    this.mortgageEnabled = true,
    this.tradeEnabled = true,
    this.maxUpgradeLevel = 3,
    this.extensionUpgradeEnabled = false,
  });

  factory GameConfig.fromJson(Map<String, dynamic> json) => GameConfig(
        rulesetId: json['ruleset_id'] as String? ?? 'classic',
        startingCash: (json['starting_cash'] as num?)?.toInt() ?? 1500,
        maxPlayers: (json['max_players'] as num?)?.toInt() ?? 4,
        stockMarketEnabled:
            json['stock_market_enabled'] as bool? ?? false,
        lotteryEnabled: json['lottery_enabled'] as bool? ?? false,
        passStartBonus: (json['pass_start_bonus'] as num?)?.toInt() ?? 200,
        jailEscapeTurns:
            (json['jail_escape_turns'] as num?)?.toInt() ?? 3,
        hospitalRecoveryTurns:
            (json['hospital_recovery_turns'] as num?)?.toInt() ?? 2,
        auctionEnabled: json['auction_enabled'] as bool? ?? true,
        mortgageEnabled: json['mortgage_enabled'] as bool? ?? true,
        tradeEnabled: json['trade_enabled'] as bool? ?? true,
        maxUpgradeLevel: (json['max_upgrade_level'] as num?)?.toInt() ?? 3,
        extensionUpgradeEnabled:
            json['extension_upgrade_enabled'] as bool? ?? false,
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
    this.tls = false,
    this.maxMessageSize = 262144,
    this.pingIntervalSecs = 30,
  });

  factory NetworkConfig.fromJson(Map<String, dynamic> json) => NetworkConfig(
        host: json['host'] as String? ?? '127.0.0.1',
        port: (json['port'] as num?)?.toInt() ?? 9000,
        path: json['path'] as String? ?? '/ws',
        tls: json['tls'] as bool? ?? false,
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
