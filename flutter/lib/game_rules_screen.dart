import 'package:flutter/material.dart';

import 'game_constants.dart';

import 'config_provider.dart' show ConfigProvider, GameConfig;
import 'main.dart' show GameScreen;

// ============================================================================
// Game Rules Screen – configure match rules before starting
// ============================================================================

class GameRulesScreen extends StatefulWidget {
  final String mapId;
  final List<PlayerSlotInfo> players;

  const GameRulesScreen({
    super.key,
    required this.mapId,
    required this.players,
  });

  @override
  State<GameRulesScreen> createState() => _GameRulesScreenState();
}

/// Information about a player slot.
class PlayerSlotInfo {
  final String id;
  final String name;
  final bool isBot;

  const PlayerSlotInfo({
    required this.id,
    required this.name,
    required this.isBot,
  });
}

class _GameRulesScreenState extends State<GameRulesScreen> {
  final ConfigProvider _configProvider = ConfigProvider();

  // ── Game config controllers ──────────────────────────────────────────────
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

  @override
  void initState() {
    super.initState();
    final game = _configProvider.game;
    _startCashCtrl =
        TextEditingController(text: game.startingCash.toString());
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
    _startCashCtrl.dispose();
    _passBonusCtrl.dispose();
    _jailTurnsCtrl.dispose();
    _hospitalTurnsCtrl.dispose();
    _maxUpgradeCtrl.dispose();
    super.dispose();
  }

  bool _validateGameConfig() {
    final checks = <String, int?>{
      '起始资金': int.tryParse(_startCashCtrl.text),
      '经过奖金': int.tryParse(_passBonusCtrl.text),
      '监狱回合': int.tryParse(_jailTurnsCtrl.text),
      '医院回合': int.tryParse(_hospitalTurnsCtrl.text),
      '升级等级': int.tryParse(_maxUpgradeCtrl.text),
    };
    for (final entry in checks.entries) {
      final v = entry.value;
      if (v == null || v < 0) {
        if (!mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${entry.key} 无效，请检查输入')),
        );
        return false;
      }
    }
    return true;
  }

  void _saveConfig() {
    _configProvider.updateGame(GameConfig(
      startingCash: int.tryParse(_startCashCtrl.text) ?? CommandConstants.startingCash,
      maxPlayers: widget.players.length,
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

  /// Start the game.
  void _onStartGame() {
    if (!_validateGameConfig()) return;
    _saveConfig();

    // Build player names and AI flags
    final names = widget.players.map((p) => p.name).toList();
    final aiFlags = widget.players.map((p) => p.isBot).toList();
    final count = widget.players.length;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => GameScreen(
          initialPlayerCount: count,
          playerNames: names,
          aiFlags: aiFlags,
          mapId: widget.mapId,
        ),
      ),
      (route) => false, // clear all previous routes
    );
  }

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
          child: Column(
            children: [
              // ── Header ────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded,
                          color: Colors.white70),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    const Text(
                      '游戏规则',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // ── Map + Players summary ─────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    _summaryBadge(
                        Icons.map_rounded, '地图: ${widget.mapId}'),
                    const SizedBox(width: 12),
                    _summaryBadge(
                      Icons.people_rounded,
                      '${widget.players.length} 名玩家',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // ── Rules content ─────────────────────────────────────────
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
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
                      const SizedBox(height: 12),
                      _buildTextField(
                        controller: _passBonusCtrl,
                        label: '经过起点奖励 (\$)',
                        icon: Icons.redeem_outlined,
                      ),

                      const SizedBox(height: 24),
                      _buildSectionTitle('回合与状态'),
                      const SizedBox(height: 8),
                      _buildTextField(
                        controller: _jailTurnsCtrl,
                        label: '监狱停留回合数',
                        icon: Icons.lock_outline,
                      ),
                      const SizedBox(height: 12),
                      _buildTextField(
                        controller: _hospitalTurnsCtrl,
                        label: '医院恢复回合数',
                        icon: Icons.local_hospital_outlined,
                      ),
                      const SizedBox(height: 12),
                      _buildTextField(
                        controller: _maxUpgradeCtrl,
                        label: '最高升级等级 (0 = 禁用升级)',
                        icon: Icons.star_outline,
                      ),

                      const SizedBox(height: 24),
                      _buildSectionTitle('功能开关'),
                      const SizedBox(height: 8),
                      _buildSwitchTile(
                        '公共设施升级',
                        '允许升级水电公司',
                        _extensionUpgradeEnabled,
                        (v) =>
                            setState(() => _extensionUpgradeEnabled = v),
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

                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),

              // ── Bottom action ─────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _onStartGame,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('开始游戏'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF43A047),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      textStyle: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: Colors.white70,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _summaryBadge(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white60),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.70),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 15),
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: Colors.white.withOpacity(0.50)),
          prefixIcon:
              Icon(icon, color: Colors.white.withOpacity(0.40), size: 20),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SwitchListTile(
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            color: Colors.white.withOpacity(0.50),
            fontSize: 11,
          ),
        ),
        value: value,
        dense: true,
        activeColor: const Color(0xFF43A047),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        onChanged: onChanged,
      ),
    );
  }
}
