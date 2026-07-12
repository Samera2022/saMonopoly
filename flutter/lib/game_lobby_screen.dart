import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'game_constants.dart';

import 'network_service.dart' show NetworkService;

import 'config_provider.dart' show ConfigProvider, GameConfig, NetworkConfig;
import 'main.dart' show GameScreen;
import 'map_models.dart' show MapMeta, MapPluginRef;
import 'plugin_models.dart' show PluginSyncEntry, PluginAckMessage;
import 'plugin_state.dart';

// ============================================================================
// Data model for a player slot
// ============================================================================

enum PlayerSlotType { human, bot, empty }

enum LobbyMode { offline, host, join }

class PlayerSlotData {
  final String id;
  String name;
  final Color color;
  PlayerSlotType type;
  /// Optional ping in ms (only shown for network players).
  int? pingMs;
  /// Team colour (outer ring). Null means no team assigned.
  Color? teamColor;
  /// Whether this player is ready (online lobby).
  bool isReady = false;

  PlayerSlotData({
    required this.id,
    required this.name,
    required this.color,
    this.type = PlayerSlotType.human,
    this.pingMs,
    this.teamColor,
    this.isReady = false,
  });
}

// ============================================================================
// Game Lobby Screen – "游戏大厅"
//
// Side-by-side dashboard connecting map selection → game start.
//   Left:   Player Roster (participant list)
//   Right:  Match Settings (map preview + rules)
//   Bottom: Action bar (system messages + start/ready button)
//
// Network modes:
//   Offline — local / single-system play (default)
//   Host    — open a lobby on LAN for others to join
//   Join    — connect to a remote lobby via IP:port
// ============================================================================

class GameLobbyScreen extends StatefulWidget {
  final String mapId;
  final MapMeta? mapMeta;

  const GameLobbyScreen({
    super.key,
    required this.mapId,
    this.mapMeta,
  });

  @override
  State<GameLobbyScreen> createState() => _GameLobbyScreenState();
}

class _GameLobbyScreenState extends State<GameLobbyScreen> {
  final ConfigProvider _configProvider = ConfigProvider();
  final List<String> _systemMessages = [
    '请设置玩家和规则，然后开始游戏',
  ];

  // ── Slot colours (player identity colours) ────────────────────────────────
  static const List<Color> _slotColors = [
    Color(0xFFD32F2F),
    Color(0xFF1976D2),
    Color(0xFF388E3C),
    Color(0xFFFBC02D),
  ];

  // ── Team colours (distinct from player colours; for team battles) ────────
  static const List<Color> _teamColors = [
    Color(0xFF9C27B0), // Purple
    Color(0xFFFF9800), // Orange
    Color(0xFF009688), // Teal
    Color(0xFFE91E63), // Pink
  ];

  // ── Network state ─────────────────────────────────────────────────────────

  LobbyMode _lobbyMode = LobbyMode.offline;
  bool _isHosting = false;
  bool _isConnected = false;
  String _localIp = '127.0.0.1';
  static const int _defaultPort = 9000;
  final TextEditingController _connectIpCtrl =
      TextEditingController(text: '127.0.0.1:9000');

  NetworkService? _networkService;
  StreamSubscription<Map<String, dynamic>>? _netSub;

  // ── Plugin sync state ─────────────────────────────────────────────────────
  List<PluginSyncEntry> _activePlugins = [];
  /// Client ID → (ready, missing_plugins) — host only
  Map<String, bool> _clientReadyStates = {};
  /// Plugin enable state
  final Map<String, bool> _pluginEnabled = {};

  // ── Player slots ──────────────────────────────────────────────────────────
  late List<PlayerSlotData> _slots;

  // ── Game config controllers (mirrors GameRulesScreen) ─────────────────────
  late TextEditingController _startCashCtrl;
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

  // ── System message controller (for future chat input) ─────────────────────
  final TextEditingController _chatCtrl = TextEditingController();

  // ── Initialisation ────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    // Detect local IP for LAN hosting
    _detectLocalIp();

    // Initialise player slots (one human, three empty)
    _slots = [
      PlayerSlotData(
        id: 'player_0',
        name: '玩家 1',
        color: _slotColors[0],
        type: PlayerSlotType.human,
        teamColor: null,
        isReady: false,
      ),
      PlayerSlotData(
        id: 'player_1',
        name: '空闲',
        color: _slotColors[1],
        type: PlayerSlotType.empty,
        teamColor: null,
        isReady: false,
      ),
      PlayerSlotData(
        id: 'player_2',
        name: '空闲',
        color: _slotColors[2],
        type: PlayerSlotType.empty,
        teamColor: null,
        isReady: false,
      ),
      PlayerSlotData(
        id: 'player_3',
        name: '空闲',
        color: _slotColors[3],
        type: PlayerSlotType.empty,
        teamColor: null,
        isReady: false,
      ),
    ];

    // Initialise game config controllers
    final game = _configProvider.game;
    _startCashCtrl = TextEditingController(text: game.startingCash.toString());
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
  }

  @override
  void dispose() {
    _netSub?.cancel();
    _netSub = null;
    // NOTE: _networkService is intentionally NOT disposed here.
    // When the game starts, NetworkService is passed to GameScreen
    // and must remain alive for game state synchronization.
    // It will be disposed by GameScreen's dispose().
    _startCashCtrl.dispose();
    _passBonusCtrl.dispose();
    _jailTurnsCtrl.dispose();
    _hospitalTurnsCtrl.dispose();
    _maxUpgradeCtrl.dispose();
    _chatCtrl.dispose();
    _connectIpCtrl.dispose();
    super.dispose();
  }

  // ── Network helpers ───────────────────────────────────────────────────────

  /// Attempt to detect the local non-loopback IPv4 address for LAN hosting.
  /// Also updates the "connect to host" IP input field to match.
  void _detectLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.isLoopback &&
              addr.address.isNotEmpty) {
            _localIp = addr.address;
            // Auto-fill the connect IP field with the detected local IP
            // so that joining players see the correct host address by default.
            _connectIpCtrl.text = '$_localIp:$_defaultPort';
            return;
          }
        }
      }
    } catch (_) {
      // Fallback: keep 127.0.0.1
    }
  }

  String get _hostAddress => '$_localIp:$_defaultPort';

  // ── Lobby mode logic ──────────────────────────────────────────────────────

  void _setLobbyMode(LobbyMode mode) {
    if (mode == _lobbyMode) return;

    // Clean up previous mode
    if (_lobbyMode == LobbyMode.host && _isHosting) {
      _stopHosting();
    }
    if (_lobbyMode == LobbyMode.join && _isConnected) {
      _disconnect();
    }

    setState(() {
      _lobbyMode = mode;
      _systemMessages.insert(0, _modeMessage(mode));
    });
  }

  String _modeMessage(LobbyMode mode) {
    switch (mode) {
      case LobbyMode.offline:
        return '已切换为离线模式';
      case LobbyMode.host:
        return '已切换为主机模式 · 房间地址: $_hostAddress';
      case LobbyMode.join:
        return '已切换为加入模式 · 请输入主机 IP 地址';
    }
  }

  // ── Hosting actions ───────────────────────────────────────────────────────

  Future<void> _startHosting() async {
    try {
      _networkService = NetworkService();
      await _networkService!.startHost(_localIp, _defaultPort);

      _netSub = _networkService!.messages.listen((message) {
        final type = message['type'] as String?;
        if (type == 'join') {
          final playerId = message['player_id'] as String? ??
              'remote_${DateTime.now().millisecondsSinceEpoch}';

          setState(() {
            final emptyIdx =
                _slots.indexWhere((s) => s.type == PlayerSlotType.empty);
            if (emptyIdx >= 0) {
              // Auto-assign a unique sequential name based on slot index
              // to prevent duplicate names (e.g. both host and remote "玩家 1").
              // Ignore the client-provided player_name to avoid conflicts.
              final slotName = '玩家 ${emptyIdx + 1}';
              _slots[emptyIdx] = PlayerSlotData(
                id: playerId,
                name: slotName,
                color: _slotColors[emptyIdx],
                type: PlayerSlotType.human,
                teamColor: null,
                isReady: false,
              );
              _systemMessages.insert(0, '$slotName 已通过局域网加入');
            }
          });

          // Broadcast updated roster to all connected clients
          _broadcastRoster();
        } else if (type == 'request_roster') {
          // Client requests full roster sync
          _broadcastRoster();
        } else if (type == 'leave') {
          final playerId = message['player_id'] as String?;
          if (playerId != null) {
            setState(() {
              final idx = _slots.indexWhere((s) => s.id == playerId);
              if (idx >= 0) {
                final name = _slots[idx].name;
                _slots[idx] = PlayerSlotData(
                  id: 'player_$idx',
                  name: '空闲',
                  color: _slotColors[idx],
                  type: PlayerSlotType.empty,
                  isReady: false,
                );
                _systemMessages.insert(0, '$name 已离开');
              }
            });
            // Notify other clients about removal and broadcast updated roster
            _networkService!.sendMessage({
              'type': 'player_removed',
              'player_id': playerId,
            });
            _broadcastRoster();
          }
        } else if (type == 'ready') {
          // Client toggles ready/unready state
          final playerId = message['player_id'] as String?;
          final ready = message['ready'] as bool? ?? false;
          if (playerId != null) {
            setState(() {
              final idx = _slots.indexWhere((s) => s.id == playerId);
              if (idx >= 0) {
                _slots[idx].isReady = ready;
                final name = _slots[idx].name;
                _systemMessages.insert(0, '$name ${ready ? '已准备' : '取消准备'}');
              }
            });
            // Broadcast updated roster to all clients to sync ready states
            _broadcastRoster();
          }
        } else if (type == 'plugin_list_request') {
          // Client requests plugin list → broadcast current state
          _broadcastPluginList();
        } else if (type == '_client_disconnected') {
          // Client disconnected abruptly (network failure / crash)
          final playerId = message['player_id'] as String?;
          if (playerId != null) {
            setState(() {
              final idx = _slots.indexWhere((s) => s.id == playerId);
              if (idx >= 0) {
                final name = _slots[idx].name;
                _slots[idx] = PlayerSlotData(
                  id: 'player_$idx',
                  name: '空闲',
                  color: _slotColors[idx],
                  type: PlayerSlotType.empty,
                  isReady: false,
                );
                _systemMessages.insert(0, '$name 已断线');
              }
            });
            _networkService!.sendMessage({
              'type': 'player_removed',
              'player_id': playerId,
            });
            _broadcastRoster();
          }
        } else if (type == 'plugin_ack') {
          // Host: record client ack status
          final ack = PluginAckMessage.fromJson(message);
          setState(() {
            _clientReadyStates[ack.clientId] = ack.ready;
            _systemMessages.insert(0,
                '插件同步: ${ack.ready ? "✅ ${ack.clientId} 已就绪" : "❌ ${ack.clientId} 缺少插件: ${ack.missingPlugins.join(", ")}"}');
          });
        }
      });

      // Save network config for the Rust backend
      _configProvider.updateNetwork(NetworkConfig(
        host: _localIp,
        port: _defaultPort,
      ));

      setState(() {
        _isHosting = true;
        _systemMessages.insert(0, '🚀 已开放大厅到局域网 · $_hostAddress');
      });
      // Broadcast initial plugin list to all clients
      _broadcastPluginList();
    } catch (e) {
      setState(() {
        _systemMessages.insert(0, '⚠️ 启动主机失败: $e');
      });
    }
  }

  void _stopHosting() {
    _netSub?.cancel();
    _netSub = null;
    _networkService?.dispose();
    _networkService = null;

    setState(() {
      _isHosting = false;
      _systemMessages.insert(0, '已停止托管');
    });
  }

  /// Broadcast the current full roster to all connected clients.
  /// This is the single source of truth for client-side slot state.
  Future<void> _broadcastRoster() async {
    if (!_isHosting || _networkService == null) return;
    final roster = _slots
        .where((s) => s.type != PlayerSlotType.empty)
        .map((s) => {
              'player_id': s.id,
              'player_name': s.name,
              'is_bot': s.type == PlayerSlotType.bot,
              'is_ready': s.isReady,
              'slot_index': _slots.indexOf(s),
            })
        .toList();
    await _networkService!.sendMessage({
      'type': 'roster_sync',
      'players': roster,
    });
  }

  /// Broadcast the current plugin list to all connected clients.
  void _broadcastPluginList() {
    if (!_isHosting || _networkService == null) return;
    final entries = _activePlugins.isNotEmpty
        ? _activePlugins
        : [
            PluginSyncEntry(id: 'economy_ext', name: '经济扩展', minVersion: '1.0.0', mandatory: true, source: 'bundled', enabled: true),
            PluginSyncEntry(id: 'special_events', name: '特殊事件', minVersion: '2.0.0', mandatory: false, source: 'bundled', enabled: true),
            PluginSyncEntry(id: 'dice_stats', name: '骰子统计', minVersion: '1.0.0', mandatory: false, source: 'external', enabled: true),
          ];
    _networkService!.sendMessage({
      'type': 'plugin_sync',
      'plugins': entries.map((e) => e.toJson()).toList(),
    });
  }

  // ── Connection actions ────────────────────────────────────────────────────

  Future<void> _connectToHost() async {
    final input = _connectIpCtrl.text.trim();
    // Parse "ip:port" or just "ip"
    final parts = input.split(':');
    final ip = parts[0].trim();
    final port =
        parts.length > 1 ? int.tryParse(parts[1].trim()) ?? _defaultPort : _defaultPort;

    if (ip.isEmpty) {
      setState(() {
        _systemMessages.insert(0, '⚠️ 请输入有效的 IP 地址');
      });
      return;
    }

    try {
      _networkService = NetworkService();
      await _networkService!.connectToHost(ip, port);

      _netSub = _networkService!.messages.listen((message) {
        // Handle messages from host
        final type = message['type'] as String?;
        if (type == 'roster_sync') {
          final players = message['players'] as List<dynamic>?;
          if (players != null) {
            setState(() {
              // Reset all slots to empty
              for (int i = 0; i < _slots.length; i++) {
                _slots[i] = PlayerSlotData(
                  id: 'player_$i',
                  name: '空闲',
                  color: _slotColors[i],
                  type: PlayerSlotType.empty,
                  isReady: false,
                );
              }
              // Fill in roster data
              for (final p in players) {
                final playerId =
                    p['player_id'] as String? ?? '';
                final playerName =
                    p['player_name'] as String? ?? '远程玩家';
                final isBot = p['is_bot'] as bool? ?? false;
                final isReady = p['is_ready'] as bool? ?? false;
                final slotIndex =
                    p['slot_index'] as int? ?? 0;
                if (slotIndex >= 0 &&
                    slotIndex < _slots.length) {
                  _slots[slotIndex] = PlayerSlotData(
                    id: playerId,
                    name: playerName,
                    color: _slotColors[slotIndex],
                    type: isBot
                        ? PlayerSlotType.bot
                        : PlayerSlotType.human,
                    teamColor: null,
                    isReady: isReady,
                  );
                }
              }
            });
          }
        } else if (type == 'player_removed') {
          final playerId = message['player_id'] as String?;
          if (playerId != null) {
            setState(() {
              final idx =
                  _slots.indexWhere((s) => s.id == playerId);
              if (idx >= 0) {
                final name = _slots[idx].name;
                _slots[idx] = PlayerSlotData(
                  id: 'player_$idx',
                  name: '空闲',
                  color: _slotColors[idx],
                  type: PlayerSlotType.empty,
                  isReady: false,
                );
                _systemMessages.insert(0, '$name 已离开');
              }
            });
          }
        } else if (type == 'game_start') {
          final initialState = message['state'] as Map<String, dynamic>?;
          final count = _activePlayerCount;
          final names = _slots
              .where((s) => s.type != PlayerSlotType.empty)
              .map((s) => s.name)
              .toList();
          final aiFlags = _slots
              .where((s) => s.type != PlayerSlotType.empty)
              .map((s) => s.type == PlayerSlotType.bot)
              .toList();
          final teamIds = _slots
              .where((s) => s.type != PlayerSlotType.empty)
              .map((s) => s.teamColor != null ? 'team_${_teamColors.indexOf(s.teamColor!)}' : null)
              .toList();
          final networkService = _networkService;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => GameScreen(
                initialPlayerCount: count,
                playerNames: names,
                aiFlags: aiFlags,
                teamIds: teamIds,
                mapId: widget.mapId,
                initialState: initialState,
                networkService: networkService,
              ),
            ),
            (route) => false,
          );
        } else if (type == 'plugin_sync') {
          final pluginList = message['plugins'] as List<dynamic>? ?? [];
          final entries = pluginList.map((p) => PluginSyncEntry.fromJson(p)).toList();
          final hostPluginIds = entries.map((e) => e.id).toSet();

          // Client: check for missing mandatory external plugins
          final localPluginIds = <String>{'dice_stats', 'treasure_hunt'}; // demo local plugins
          final missing = <String>[];
          for (final entry in entries) {
            if (entry.mandatory && entry.source == 'external') {
              if (!localPluginIds.contains(entry.id)) {
                missing.add(entry.id);
              }
            }
          }

          // ═══ 强制禁用客户端多余的插件 ═══════════════════════════
          // 任何不在 host 清单中的本地插件都会被禁用，
          // 防止它们影响游戏规则
          for (final localId in localPluginIds) {
            if (!hostPluginIds.contains(localId)) {
              PluginState().setEnabled(localId, false);
            }
          }
          for (final hostId in hostPluginIds) {
            PluginState().setEnabled(hostId, true);
          }
          // ═════════════════════════════════════════════════════════

          setState(() {
            _activePlugins = entries;
          });

          _networkService!.sendMessage({
            'type': 'plugin_ack',
            'client_id': 'local_client',
            'ready': missing.isEmpty,
            'missing_plugins': missing,
          });
        }
      });

      // Send join message to announce ourselves
      // The name sent here is a placeholder; the host will auto-assign
      // a slot-appropriate name (玩家 2, 玩家 3, etc.) via roster_sync.
      await _networkService!.sendMessage({
        'type': 'join',
        'player_name': '远程玩家',
        'player_id': 'local_player',
      });

      // Request full roster from host to sync all players
      await _networkService!.sendMessage({
        'type': 'request_roster',
      });

      // Save network config
      _configProvider.updateNetwork(NetworkConfig(
        host: ip,
        port: port,
      ));

      setState(() {
        _isConnected = true;
        _systemMessages.insert(0, '🔗 已连接到 $ip:$port');
      });
    } catch (e) {
      // Clean up on failure
      _netSub?.cancel();
      _netSub = null;
      _networkService?.dispose();
      _networkService = null;

      setState(() {
        _systemMessages.insert(0, '⚠️ 连接失败: $e');
      });
    }
  }

  void _disconnect() {
    // Send leave message before disconnecting
    if (_networkService != null && _isConnected) {
      _networkService!.sendMessage({
        'type': 'leave',
        'player_id': 'local_player',
      });
    }

    _netSub?.cancel();
    _netSub = null;
    _networkService?.dispose();
    _networkService = null;

    setState(() {
      _isConnected = false;
      _systemMessages.insert(0, '已断开连接');
    });
  }

  // ── Computed properties ───────────────────────────────────────────────────

  int get _activePlayerCount =>
      _slots.where((s) => s.type != PlayerSlotType.empty).length;

  bool get _canStartGame => _activePlayerCount >= 1;

  /// Whether all remote human players (non-local, non-bot) are ready.
  /// Used by the host to decide if the "start game" button is enabled.
  bool get _allRemotePlayersReady {
    final remoteHumans = _slots.where(
      (s) => s.type == PlayerSlotType.human && !s.id.startsWith('player_'),
    );
    return remoteHumans.isEmpty || remoteHumans.every((s) => s.isReady);
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _saveConfig() {
    _configProvider.updateGame(GameConfig(
      startingCash: int.tryParse(_startCashCtrl.text) ?? CommandConstants.startingCash,
      maxPlayers: _activePlayerCount,
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
  }

  void _onStartGame() {
    if (!_canStartGame) return;
    _saveConfig();

    final names = _slots
        .where((s) => s.type != PlayerSlotType.empty)
        .map((s) => s.name)
        .toList();
    final aiFlags = _slots
        .where((s) => s.type != PlayerSlotType.empty)
        .map((s) => s.type == PlayerSlotType.bot)
        .toList();
    final teamIds = _slots
        .where((s) => s.type != PlayerSlotType.empty)
        .map((s) => s.teamColor != null ? 'team_${_teamColors.indexOf(s.teamColor!)}' : null)
        .toList();
    final count = _activePlayerCount;
    final networkService = _networkService;

    if (_lobbyMode == LobbyMode.host && _isHosting && networkService != null) {
      // ── Host mode: navigate to game screen ─────────────────────────────
      // GameScreen.initState will broadcast the full game_start message.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => GameScreen(
            initialPlayerCount: count,
            playerNames: names,
            aiFlags: aiFlags,
            teamIds: teamIds,
            mapId: widget.mapId,
            networkService: networkService,
          ),
        ),
        (route) => false,
      );
    } else if (_lobbyMode == LobbyMode.join && _isConnected && networkService != null) {
      // ── Client mode: wait for game_start from host, then navigate ──────
      // Replace the roster listener with a game-start listener
      _netSub?.cancel();
      _netSub = networkService.messages.listen((message) {
        final type = message['type'] as String?;
        if (type == 'game_start') {
          _netSub?.cancel();
          _netSub = null;
          final initialState = message['state'] as Map<String, dynamic>?;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => GameScreen(
                initialPlayerCount: count,
                playerNames: names,
                aiFlags: aiFlags,
                teamIds: teamIds,
                mapId: widget.mapId,
                initialState: initialState,
                networkService: networkService,
              ),
            ),
            (route) => false,
          );
        }
      });
      // Notify host that we're ready for the game
      networkService.sendMessage({'type': 'client_ready'});
    } else {
      // ── Offline mode: navigate directly ────────────────────────────────
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => GameScreen(
            initialPlayerCount: count,
            playerNames: names,
            aiFlags: aiFlags,
            teamIds: teamIds,
            mapId: widget.mapId,
          ),
        ),
        (route) => false,
      );
    }
  }

  void _addBotPlayer() {
    setState(() {
      final emptyIdx =
          _slots.indexWhere((s) => s.type == PlayerSlotType.empty);
      if (emptyIdx >= 0) {
        final botIndex =
            _slots.where((s) => s.type == PlayerSlotType.bot).length + 1;
        _slots[emptyIdx] = PlayerSlotData(
          id: 'player_$emptyIdx',
          name: '电脑玩家 $botIndex',
          color: _slotColors[emptyIdx],
          type: PlayerSlotType.bot,
          teamColor: null,
          isReady: false,
        );
        _systemMessages.insert(0, '已添加电脑玩家 $botIndex');

        // Broadcast to connected clients if hosting
        if (_isHosting && _networkService != null) {
          _networkService!.sendMessage({
            'type': 'join',
            'player_name': '电脑玩家 $botIndex',
            'player_id': 'player_$emptyIdx',
            'is_bot': true,
          });
          _broadcastRoster();
        }
      }
    });
  }

  void _onSlotTap(int index) {
    final slot = _slots[index];
    if (slot.type == PlayerSlotType.empty) {
      // Toggle empty → human (fill slot with a local player)
      setState(() {
        _slots[index] = PlayerSlotData(
          id: 'player_$index',
          name: '玩家 ${index + 1}',
          color: _slotColors[index],
          type: PlayerSlotType.human,
          teamColor: null,
          isReady: false,
        );
        _systemMessages.insert(0, '玩家 ${index + 1} 已加入');

        // Broadcast to connected clients if hosting
        if (_isHosting && _networkService != null) {
          _networkService!.sendMessage({
            'type': 'join',
            'player_name': '玩家 ${index + 1}',
            'player_id': 'player_$index',
          });
          _broadcastRoster();
        }
      });
    } else {
      // Open action menu for filled slots
      _onSlotLongPress(index);
    }
  }

  void _onSlotLongPress(int index) {
    final slot = _slots[index];
    if (slot.type == PlayerSlotType.human ||
        slot.type == PlayerSlotType.bot) {
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1A1A2E),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.30),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                ListTile(
                  leading: const Icon(Icons.edit_rounded,
                      color: Colors.white70),
                  title: const Text('修改名称',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showRenameDialog(index);
                  },
                ),
                ListTile(
                  leading: Icon(Icons.remove_circle_outline,
                      color: Colors.red.shade300),
                  title: Text('移除',
                      style: TextStyle(color: Colors.red.shade300)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _removeSlot(index);
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }
  }

  void _showRenameDialog(int index) {
    final slot = _slots[index];
    final ctrl = TextEditingController(text: slot.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('修改名称',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: '玩家名称',
            labelStyle: TextStyle(color: Colors.white.withOpacity(0.50)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide:
                  BorderSide(color: Colors.white.withOpacity(0.20)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF43A047)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消',
                style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                setState(() {
                  _slots[index].name = name;
                  _systemMessages
                      .insert(0, '已重命名玩家 ${index + 1} → $name');
                });
              }
              Navigator.of(ctx).pop();
            },
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF43A047)),
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  void _removeSlot(int index) {
    setState(() {
      final name = _slots[index].name;
      _slots[index] = PlayerSlotData(
        id: 'player_$index',
        name: '空闲',
        color: _slotColors[index],
        type: PlayerSlotType.empty,
        isReady: false,
      );
      _systemMessages.insert(0, '$name 已移除');

      // Broadcast to connected clients if hosting
      if (_isHosting && _networkService != null) {
        _networkService!.sendMessage({
          'type': 'player_removed',
          'player_id': 'player_$index',
        });
        _broadcastRoster();
      }
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF1A1A2E),
              Color(0xFF16213E),
              Color(0xFF0F3460),
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 600;

              return Column(
                children: [
                  // ── Header ────────────────────────────────────────────
                  _buildHeader(),

                  // ── Network status bar (host/join only) ───────────────
                  if (_lobbyMode != LobbyMode.offline)
                    _buildNetworkStatusBar(),

                  // ── Body (side-by-side or stacked) ────────────────────
                  Expanded(
                    child: isWide
                        ? _buildWideBody()
                        : _buildNarrowBody(),
                  ),

                  // ── Bottom Action Bar ─────────────────────────────────
                  _buildActionBar(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  HEADER
  // ═════════════════════════════════════════════════════════════════════════

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded,
                color: Colors.white70),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _lobbyMode == LobbyMode.host && _isHosting
                  ? const Color(0xFF43A047)
                  : _lobbyMode == LobbyMode.join && _isConnected
                      ? const Color(0xFF1E88E5)
                      : const Color(0xFF43A047),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            '游戏大厅',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const Spacer(),

          // ── Mode selector badge ──────────────────────────────────────
          GestureDetector(
            onTap: _showModeSelector,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _modeColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _modeColor.withOpacity(0.30),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_modeIcon, size: 12, color: _modeColor),
                  const SizedBox(width: 4),
                  Text(
                    _modeLabel,
                    style: TextStyle(
                      fontSize: 11,
                      color: _modeColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(Icons.arrow_drop_down_rounded,
                      size: 14, color: _modeColor.withOpacity(0.60)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  // ── Mode selector helpers ─────────────────────────────────────────────────

  Color get _modeColor {
    switch (_lobbyMode) {
      case LobbyMode.offline:
        return Colors.grey;
      case LobbyMode.host:
        return const Color(0xFF43A047);
      case LobbyMode.join:
        return const Color(0xFF1E88E5);
    }
  }

  IconData get _modeIcon {
    switch (_lobbyMode) {
      case LobbyMode.offline:
        return Icons.wifi_off_rounded;
      case LobbyMode.host:
        return Icons.wifi_tethering_rounded;
      case LobbyMode.join:
        return Icons.cast_connected_rounded;
    }
  }

  String get _modeLabel {
    switch (_lobbyMode) {
      case LobbyMode.offline:
        return _isHosting
            ? '托管中'
            : '离线模式';
      case LobbyMode.host:
        return _isHosting ? '托管中' : '主机模式';
      case LobbyMode.join:
        return _isConnected ? '已连接' : '加入游戏';
    }
  }

  void _showModeSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.30),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  '网络模式',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Offline mode
              _buildModeOption(
                icon: Icons.wifi_off_rounded,
                title: '离线模式',
                subtitle: '本地单人 / 同屏多人游戏',
                color: Colors.grey,
                isActive: _lobbyMode == LobbyMode.offline,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _setLobbyMode(LobbyMode.offline);
                },
              ),

              // Host mode
              _buildModeOption(
                icon: Icons.wifi_tethering_rounded,
                title: '托管游戏 (主机)',
                subtitle: '开放大厅到局域网 · $_localIp:$_defaultPort',
                color: const Color(0xFF43A047),
                isActive: _lobbyMode == LobbyMode.host,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _setLobbyMode(LobbyMode.host);
                },
              ),

              // Join mode
              _buildModeOption(
                icon: Icons.cast_connected_rounded,
                title: '加入游戏 (客户端)',
                subtitle: '通过 IP 地址连接到主机大厅',
                color: const Color(0xFF1E88E5),
                isActive: _lobbyMode == LobbyMode.join,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _setLobbyMode(LobbyMode.join);
                },
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: isActive
            ? color.withOpacity(0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: isActive
            ? Border.all(color: color.withOpacity(0.40), width: 1.5)
            : null,
      ),
      child: ListTile(
        leading: Icon(icon, color: color, size: 24),
        title: Text(
          title,
          style: TextStyle(
            color: isActive ? Colors.white : Colors.white70,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withOpacity(0.45),
          ),
        ),
        trailing: isActive
            ? Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              )
            : null,
        onTap: onTap,
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  NETWORK STATUS BAR (shown below header when host/join active)
  // ═════════════════════════════════════════════════════════════════════════

  Widget _buildNetworkStatusBar() {
    switch (_lobbyMode) {
      case LobbyMode.host:
        return _buildHostStatusBar();
      case LobbyMode.join:
        return _buildJoinStatusBar();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildHostStatusBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF43A047).withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF43A047).withOpacity(0.20),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _isHosting
                  ? const Color(0xFF43A047)
                  : Colors.orange,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _isHosting
                  ? '托管中 · 房间地址: $_hostAddress'
                  : '准备托管 · 点击下方按钮开放大厅',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withOpacity(0.80),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (_isHosting)
            SizedBox(
              height: 28,
              child: TextButton.icon(
                onPressed: _stopHosting,
                icon: const Icon(Icons.stop_rounded, size: 14),
                label: const Text('停止', style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red.shade300,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            )
          else
            SizedBox(
              height: 28,
              child: FilledButton.icon(
                onPressed: _startHosting,
                icon: const Icon(Icons.wifi_tethering_rounded, size: 14),
                label: const Text('开放大厅', style: TextStyle(fontSize: 11)),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF43A047),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildJoinStatusBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E88E5).withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF1E88E5).withOpacity(0.20),
        ),
      ),
      child: _isConnected
          ? Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF43A047),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '已连接到 ${_connectIpCtrl.text.trim()}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.80),
                    ),
                  ),
                ),
                SizedBox(
                  height: 28,
                  child: TextButton.icon(
                    onPressed: _disconnect,
                    icon: const Icon(Icons.link_off_rounded, size: 14),
                    label: const Text('断开', style: TextStyle(fontSize: 11)),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red.shade300,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: TextField(
                      controller: _connectIpCtrl,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        hintText: '输入主机 IP:端口 (如 192.168.1.100:9000)',
                        hintStyle: TextStyle(
                          color: Colors.white.withOpacity(0.30),
                          fontSize: 11,
                        ),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 32,
                  child: FilledButton.icon(
                    onPressed: _connectToHost,
                    icon: const Icon(Icons.link_rounded, size: 14),
                    label: const Text('连接', style: TextStyle(fontSize: 11)),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1E88E5),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  // ── Wide layout: side-by-side ─────────────────────────────────────────────

  Widget _buildWideBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _buildPlayerRoster()),
          const SizedBox(width: 16),
          Expanded(child: _buildMatchSettings()),
        ],
      ),
    );
  }

  // ── Narrow layout: stacked ────────────────────────────────────────────────

  Widget _buildNarrowBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SingleChildScrollView(
        child: Column(
          children: [
            _buildPlayerRoster(),
            const SizedBox(height: 16),
            _buildMatchSettings(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  LEFT PANEL – Player Roster
  // ═════════════════════════════════════════════════════════════════════════

  Widget _buildPlayerRoster() {
    final showNetworkInfo =
        (_lobbyMode == LobbyMode.host && _isHosting) ||
        (_lobbyMode == LobbyMode.join && _isConnected);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Row(
          children: [
            const Icon(Icons.people_rounded,
                size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            Text(
              '参与者  ($_activePlayerCount/4)',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
                letterSpacing: 0.5,
              ),
            ),
            if (showNetworkInfo) ...[
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF43A047).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'LAN',
                  style: TextStyle(
                    fontSize: 9,
                    color: const Color(0xFF43A047).withOpacity(0.80),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),

        // Player slot cards
        ...List.generate(_slots.length, (i) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildPlayerSlotCard(i),
          );
        }),

        // Add bot button — only in offline or host mode
        if (_lobbyMode != LobbyMode.join && _activePlayerCount < 4) ...[
          const SizedBox(height: 4),
          _buildAddBotButton(),
        ],
      ],
    );
  }

  Widget _buildPlayerSlotCard(int index) {
    final slot = _slots[index];
    final isEmpty = slot.type == PlayerSlotType.empty;

    // Avatar border colour: team colour as outer ring, fallback to player colour
    final avatarBorderColor = slot.teamColor ?? slot.color;

    // Badge config
    String badgeLabel;
    Color badgeColor;
    IconData badgeIcon;
    switch (slot.type) {
      case PlayerSlotType.human:
        badgeLabel = '本地';
        badgeColor = const Color(0xFF43A047);
        badgeIcon = Icons.person_rounded;
        break;
      case PlayerSlotType.bot:
        badgeLabel = 'CPU';
        badgeColor = const Color(0xFF1E88E5);
        badgeIcon = Icons.computer_rounded;
        break;
      case PlayerSlotType.empty:
        badgeLabel = '空位';
        badgeColor = Colors.grey;
        badgeIcon = Icons.person_add_alt_1_rounded;
        break;
    }

    return GestureDetector(
      onTap: () => _onSlotTap(index),
      onLongPress: () => _onSlotLongPress(index),
      child: IntrinsicHeight(
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isEmpty
                  ? Colors.white.withOpacity(0.08)
                  : slot.color.withOpacity(0.35),
              width: isEmpty ? 1 : 1.5,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Green left vertical bar for ready non-empty slots
              if (!isEmpty && slot.isReady)
                Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: const Color(0xFF43A047),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

              // Original content
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      // Avatar circle with team colour ring
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isEmpty
                              ? Colors.white.withOpacity(0.08)
                              : slot.color.withOpacity(0.70),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isEmpty
                                ? Colors.white.withOpacity(0.15)
                                : avatarBorderColor,
                            width: isEmpty ? 2 : 3,
                          ),
                        ),
                        child: Center(
                          child: isEmpty
                              ? Icon(Icons.add_rounded,
                                  color: Colors.white.withOpacity(0.40), size: 20)
                              : Text(
                                  slot.name.isNotEmpty ? slot.name[0] : '?',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),

                      // Team colour selector (2×2 grid, between avatar and name)
                      if (!isEmpty) ...[
                        const SizedBox(width: 8),
                        _buildTeamSelector(index),
                        const SizedBox(width: 8),
                      ] else
                        const SizedBox(width: 12),

                      // Name + badge
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isEmpty ? '点击添加玩家' : slot.name,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: isEmpty
                                    ? Colors.white.withOpacity(0.35)
                                    : Colors.white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(badgeIcon,
                                    size: 11, color: badgeColor),
                                const SizedBox(width: 3),
                                Text(
                                  badgeLabel,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: badgeColor,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),

                                // Ping (for network players in host/join mode)
                                if (!isEmpty && slot.pingMs != null) ...[
                                  const SizedBox(width: 8),
                                  Icon(Icons.signal_cellular_alt_rounded,
                                      size: 10,
                                      color: _pingColor(slot.pingMs!)),
                                  const SizedBox(width: 2),
                                  Text(
                                    '${slot.pingMs}ms',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: Colors.white.withOpacity(0.35),
                                    ),
                                  ),
                                ],

                                // Ready status indicator (only for ready slots)
                                if (!isEmpty && slot.isReady) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF43A047),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    '已准备',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.white.withOpacity(0.40),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),

                      // Slot number + delete button
                      if (isEmpty)
                        Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: slot.color.withOpacity(0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              '${index + 1}',
                              style: TextStyle(
                                color: slot.color.withOpacity(0.70),
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        )
                      else
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Slot number badge
                            Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: slot.color.withOpacity(0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    color: slot.color.withOpacity(0.70),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            // Delete (remove) button — only shown for non-empty slots
                            GestureDetector(
                              onTap: () => _removeSlot(index),
                              child: Container(
                                width: 26,
                                height: 26,
                                decoration: BoxDecoration(
                                  color: Colors.red.withOpacity(0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Icon(
                                    Icons.close_rounded,
                                    color: Colors.red.shade300,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Team colour selector (2×2 grid of colour dots) ──────────────────────────

  /// Build a 2×2 grid of team colour dots. The currently selected team (if any)
  /// is highlighted with a checkmark. Tapping a dot assigns that team to the slot.
  Widget _buildTeamSelector(int slotIndex) {
    final slot = _slots[slotIndex];

    return SizedBox(
      width: 34,
      height: 34,
      child: GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: List.generate(_teamColors.length, (i) {
          final tc = _teamColors[i];
          final isSelected = slot.teamColor == tc;

          return GestureDetector(
            onTap: () => _onSelectTeam(slotIndex, tc),
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: tc,
                shape: BoxShape.circle,
                border: isSelected
                    ? Border.all(color: Colors.white, width: 2)
                    : null,
              ),
              child: isSelected
                  ? const Center(
                      child: Icon(Icons.check_rounded,
                          color: Colors.white, size: 8),
                    )
                  : null,
            ),
          );
        }),
      ),
    );
  }

  void _onSelectTeam(int slotIndex, Color teamColor) {
    setState(() {
      final slot = _slots[slotIndex];
      // Toggle: if already this team, clear it; otherwise assign
      if (slot.teamColor == teamColor) {
        slot.teamColor = null;
        _systemMessages.insert(0, '${slot.name} 已取消队伍');
      } else {
        slot.teamColor = teamColor;
        final teamNames = ['紫队', '橙队', '青队', '粉队'];
        final teamIdx = _teamColors.indexOf(teamColor);
        final teamName = teamIdx >= 0 ? teamNames[teamIdx] : '队伍';
        _systemMessages.insert(0, '${slot.name} 加入了 $teamName');
      }
    });
  }

  Color _pingColor(int ms) {
    if (ms < 30) return const Color(0xFF43A047);
    if (ms < 80) return const Color(0xFFFDD835);
    return const Color(0xFFE53935);
  }

  Widget _buildAddBotButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _addBotPlayer,
        icon: const Icon(Icons.smart_toy_rounded, size: 18),
        label: const Text('添加电脑玩家',
            style: TextStyle(fontSize: 13)),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white.withOpacity(0.60),
          side: BorderSide(
            color: Colors.white.withOpacity(0.15),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  RIGHT PANEL – Match Settings
  // ═════════════════════════════════════════════════════════════════════════

  Widget _buildMatchSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Row(
          children: [
            const Icon(Icons.tune_rounded,
                size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            const Text(
              '比赛设置',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Map preview card
        _buildMapPreviewCard(),
        const SizedBox(height: 16),

        // Plugin management card
        _buildPluginPanel(),
        const SizedBox(height: 16),

        // Rules list (scrollable)
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionTitle('经济设置'),
                const SizedBox(height: 8),
                _buildTextField(
                  controller: _startCashCtrl,
                  label: '起始资金 (\$)',
                  icon: Icons.monetization_on_outlined,
                ),
                const SizedBox(height: 10),
                _buildTextField(
                  controller: _passBonusCtrl,
                  label: '经过起点奖励 (\$)',
                  icon: Icons.redeem_outlined,
                ),

                const SizedBox(height: 20),
                _buildSectionTitle('回合与状态'),
                const SizedBox(height: 8),
                _buildTextField(
                  controller: _jailTurnsCtrl,
                  label: '监狱停留回合数',
                  icon: Icons.lock_outline,
                ),
                const SizedBox(height: 10),
                _buildTextField(
                  controller: _hospitalTurnsCtrl,
                  label: '医院恢复回合数',
                  icon: Icons.local_hospital_outlined,
                ),
                const SizedBox(height: 10),
                _buildTextField(
                  controller: _maxUpgradeCtrl,
                  label: '最高升级等级',
                  subtitle: '0 = 禁用升级',
                  icon: Icons.star_outline,
                ),

                const SizedBox(height: 20),
                _buildSectionTitle('功能开关'),
                const SizedBox(height: 8),
                _buildSwitchTile(
                  '公共设施升级',
                  '允许升级水电公司',
                  _extensionUpgradeEnabled,
                  (v) => setState(() => _extensionUpgradeEnabled = v),
                ),
                _buildSwitchTile(
                  '组合租金',
                  '拥有完整色组时累加租金',
                  _groupRentEnabled,
                  (v) => setState(() => _groupRentEnabled = v),
                ),
                _buildSwitchTile(
                  '股票市场',
                  '启用股票交易系统',
                  _stockMarketEnabled,
                  (v) => setState(() => _stockMarketEnabled = v),
                ),
                _buildSwitchTile(
                  '彩票系统',
                  '启用彩票购买与抽奖',
                  _lotteryEnabled,
                  (v) => setState(() => _lotteryEnabled = v),
                ),
                _buildSwitchTile(
                  '拍卖机制',
                  '放弃购买地产时进入拍卖',
                  _auctionEnabled,
                  (v) => setState(() => _auctionEnabled = v),
                ),
                _buildSwitchTile(
                  '抵押贷款',
                  '允许抵押地产获得资金',
                  _mortgageEnabled,
                  (v) => setState(() => _mortgageEnabled = v),
                ),
                _buildSwitchTile(
                  '交易系统',
                  '允许玩家之间交易地产和资金',
                  _tradeEnabled,
                  (v) => setState(() => _tradeEnabled = v),
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Map preview with thumbnail and metadata.
  Widget _buildMapPreviewCard() {
    final map = widget.mapMeta;
    final mapName = map?.displayName ?? widget.mapId;
    final tileCount = map?.tileCount ?? 0;
    final themeColor = map?.themeColor ?? const Color(0xFF43A047);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: themeColor.withOpacity(0.25),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // Thumbnail (4:3 ratio)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 80,
                height: 60,
                child: map?.resolvedThumbnailPath != null
                    ? Image.asset(
                        map!.resolvedThumbnailPath!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            _buildPlaceholderThumb(themeColor),
                      )
                    : _buildPlaceholderThumb(themeColor),
              ),
            ),
            const SizedBox(width: 12),

            // Map info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mapName,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$tileCount 个格子 · ${widget.mapId}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.50),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Plugin management panel in lobby.
  Widget _buildPluginPanel() {
    final bundledPlugins = [
      const MapPluginRef(
        id: 'economy_ext', name: '经济扩展',
        minVersion: '1.0.0', mandatory: true, source: 'bundled',
      ),
      const MapPluginRef(
        id: 'special_events', name: '特殊事件',
        minVersion: '2.0.0', mandatory: false, source: 'bundled',
      ),
    ];

    // Demo local plugins that are "installed" on this device
    final localPluginEntries = [
      PluginSyncEntry(
        id: 'dice_stats', name: '骰子统计',
        minVersion: '1.0.0', mandatory: false, source: 'external', enabled: true,
      ),
      PluginSyncEntry(
        id: 'treasure_hunt', name: '宝藏猎人',
        minVersion: '1.0.0', mandatory: false, source: 'external', enabled: false,
      ),
    ];

    // Determine which display list to use
    final syncedEntries = _activePlugins.isNotEmpty
        ? _activePlugins
        : bundledPlugins.map((r) => PluginSyncEntry(
              id: r.id,
              name: r.name,
              minVersion: r.minVersion,
              mandatory: r.mandatory,
              source: r.source,
              enabled: true,
            )).toList();
    // Merge with local plugin entries
    final displayPlugins = [
      ...syncedEntries,
      ...localPluginEntries.where((local) =>
          !syncedEntries.any((s) => s.id == local.id)),
    ];

    final synced = _activePlugins.isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF8E24AA).withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF8E24AA).withOpacity(0.20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.extension_rounded,
                  size: 16, color: Color(0xFFCE93D8)),
              const SizedBox(width: 6),
              const Text(
                '插件',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFCE93D8),
                ),
              ),
              const Spacer(),
              if (synced)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF43A047).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('已同步',
                      style: TextStyle(
                          color: Color(0xFF43A047),
                          fontSize: 10, fontWeight: FontWeight.w500)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('📦 地图自带',
              style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          ...displayPlugins.where((p) => p.source == 'bundled').map((p) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(
                  p.mandatory
                      ? Icons.inventory_2_rounded
                      : Icons.extension_outlined,
                  size: 14, color: Colors.white38,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    p.name,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: (p.mandatory
                        ? const Color(0xFFFFA726)
                        : const Color(0xFF43A047)).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    p.mandatory ? '● 必选' : '○ 可选',
                    style: TextStyle(
                      color: p.mandatory
                          ? const Color(0xFFFFA726)
                          : const Color(0xFF43A047),
                      fontSize: 10, fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: !p.mandatory ? () {
                    final cur = _pluginEnabled[p.id] ?? true;
                    final newVal = !cur;
                    setState(() {
                      _pluginEnabled[p.id] = newVal;
                      PluginState().setEnabled(p.id, newVal);
                    });
                  } : null,
                  child: Container(
                    width: 28,
                    height: 18,
                    decoration: BoxDecoration(
                      color: (_pluginEnabled[p.id] ?? true)
                          ? const Color(0xFF43A047).withOpacity(0.20)
                          : Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: (_pluginEnabled[p.id] ?? true)
                            ? const Color(0xFF43A047).withOpacity(0.40)
                            : Colors.white.withOpacity(0.15),
                        width: 1,
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        !p.mandatory
                            ? ((_pluginEnabled[p.id] ?? true)
                                ? Icons.check_circle
                                : Icons.remove_circle_outline)
                            : Icons.lock_outline,
                        size: 12,
                        color: (_pluginEnabled[p.id] ?? true)
                            ? const Color(0xFF43A047)
                            : !p.mandatory
                                ? Colors.white38
                                : Colors.white24,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )),
          const SizedBox(height: 8),
          const Text('📂 本地',
              style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          ...displayPlugins.where((p) => p.source == 'external').map((p) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                const Icon(Icons.folder_rounded, size: 14, color: Colors.white38),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    p.name,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () {
                    final cur = _pluginEnabled[p.id] ?? true;
                    final newVal = !cur;
                    setState(() {
                      _pluginEnabled[p.id] = newVal;
                      PluginState().setEnabled(p.id, newVal);
                    });
                  },
                  child: Container(
                    width: 28, height: 18,
                    decoration: BoxDecoration(
                      color: (_pluginEnabled[p.id] ?? true)
                          ? const Color(0xFF43A047).withOpacity(0.20)
                          : Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: (_pluginEnabled[p.id] ?? true)
                            ? const Color(0xFF43A047).withOpacity(0.40)
                            : Colors.white.withOpacity(0.15),
                        width: 1,
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        (_pluginEnabled[p.id] ?? true)
                            ? Icons.check_circle
                            : Icons.remove_circle_outline,
                        size: 12,
                        color: (_pluginEnabled[p.id] ?? true)
                            ? const Color(0xFF43A047)
                            : Colors.white38,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )),
          if (displayPlugins.where((p) => p.source == 'external').isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('（无已安装的本地插件）',
                  style: TextStyle(color: Colors.white.withOpacity(0.20), fontSize: 11)),
            ),
          // Host-only: client sync status
          if (_lobbyMode == LobbyMode.host && _isHosting && _clientReadyStates.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 8),
            ..._clientReadyStates.entries.map((e) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    e.value ? Icons.check_circle_rounded : Icons.warning_rounded,
                    size: 14,
                    color: e.value ? const Color(0xFF43A047) : const Color(0xFFFFA726),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${e.key}: ${e.value ? "已同步" : "缺少插件"}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.60),
                    ),
                  ),
                ],
              ),
            )),
          ],
        ],
      ),
    );
  }

  Widget _buildPlaceholderThumb(Color themeColor) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            themeColor.withOpacity(0.50),
            themeColor.withOpacity(0.20),
          ],
        ),
      ),
      child: Center(
        child: Icon(Icons.map_rounded,
            color: Colors.white.withOpacity(0.40), size: 28),
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  BOTTOM ACTION BAR
  // ═════════════════════════════════════════════════════════════════════════

  Widget _buildActionBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withOpacity(0.30),
          ],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 500;

          return Row(
            children: [
              // System messages (left side)
              Expanded(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 14, color: Colors.white.withOpacity(0.40)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _systemMessages.isNotEmpty
                              ? _systemMessages.first
                              : '',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withOpacity(0.50),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (isWide) const SizedBox(width: 12),

              // Action button (right side)
              const SizedBox(width: 12),
              if (_lobbyMode == LobbyMode.join && _isConnected)
                // ── Ready / Unready toggle (client mode) ────────────────
                _buildReadyToggleButton()
              else
                // ── Start Game button (host / offline mode) ─────────────
                _buildStartGameButton(),
            ],
          );
        },
      ),
    );
  }

  /// Build the ready/unready toggle button shown in join (client) mode.
  Widget _buildReadyToggleButton() {
    // Find the local player's slot (id == 'local_player')
    final localSlotIdx = _slots.indexWhere((s) => s.id == 'local_player');
    final isReady =
        localSlotIdx >= 0 ? _slots[localSlotIdx].isReady : false;

    return FilledButton.icon(
      onPressed: () {
        if (localSlotIdx < 0 || _networkService == null) return;
        final newReady = !_slots[localSlotIdx].isReady;
        setState(() {
          _slots[localSlotIdx].isReady = newReady;
          _systemMessages.insert(0, newReady ? '你已准备' : '你已取消准备');
        });
        _networkService!.sendMessage({
          'type': 'ready',
          'player_id': 'local_player',
          'ready': newReady,
        });
      },
      icon: Icon(
        isReady ? Icons.close_rounded : Icons.check_rounded,
        size: 20,
      ),
      label: Text(
        isReady ? '取消准备' : '准备',
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      style: FilledButton.styleFrom(
        backgroundColor:
            isReady ? const Color(0xFFE53935) : const Color(0xFF43A047),
        disabledBackgroundColor: Colors.white.withOpacity(0.10),
        disabledForegroundColor: Colors.white.withOpacity(0.30),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  /// Build the "Start Game" button for host or offline mode.
  /// In host mode the button is only enabled when all remote human players
  /// have signalled ready via [_allRemotePlayersReady].
  Widget _buildStartGameButton() {
    final isHost = _lobbyMode == LobbyMode.host && _isHosting;
    final canStart = _canStartGame && (isHost ? _allRemotePlayersReady : true);

    return FilledButton.icon(
      onPressed: canStart ? _onStartGame : null,
      icon: const Icon(Icons.play_arrow_rounded, size: 20),
      label: Text(
        !_canStartGame
            ? '至少需要 1 名玩家'
            : (isHost && !_allRemotePlayersReady
                ? '等待玩家准备...'
                : '开始游戏'),
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF43A047),
        disabledBackgroundColor: Colors.white.withOpacity(0.10),
        disabledForegroundColor: Colors.white.withOpacity(0.30),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  REUSABLE WIDGET BUILDERS
  // ═════════════════════════════════════════════════════════════════════════

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Colors.white60,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? subtitle,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          helperText: subtitle,
          helperStyle: TextStyle(
            color: Colors.white.withOpacity(0.30),
            fontSize: 10,
          ),
          labelStyle: TextStyle(
            color: Colors.white.withOpacity(0.45),
            fontSize: 13,
          ),
          prefixIcon: Icon(icon,
              color: Colors.white.withOpacity(0.35), size: 18),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildSwitchTile(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 3),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(9),
      ),
      child: SwitchListTile(
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            color: Colors.white.withOpacity(0.45),
            fontSize: 10,
          ),
        ),
        value: value,
        dense: true,
        activeColor: const Color(0xFF43A047),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        onChanged: onChanged,
      ),
    );
  }
}
