import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bridge_client.dart';
import 'config_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ConfigProvider _config = ConfigProvider(client: BridgeClient());
  final _formKey = GlobalKey<FormState>();

  // ── Game ──
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

  // ── LLM ──
  String _llmBackend = 'direct';
  late TextEditingController _llmEndpointCtrl;
  late TextEditingController _llmA2cmEndpointCtrl;
  late TextEditingController _llmApiKeyCtrl;
  late TextEditingController _llmModelCtrl;
  late TextEditingController _llmTemperatureCtrl;
  late TextEditingController _llmMaxTokensCtrl;
  late TextEditingController _llmCustomHeadersCtrl;
  bool _apiKeyVisible = false;
  bool _testingConnection = false;

  /// Whether the current API key field holds a stored reference
  /// (`keyring:` from the OS keychain, or `env:`) rather than a plaintext key.
  bool get _apiKeyIsReference {
    final v = _llmApiKeyCtrl.text.trim();
    return v.startsWith('keyring:') || v.startsWith('env:');
  }

  @override
  void initState() {
    super.initState();
    final game = _config.game;
    final llm = _config.llmApi;

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

    _llmBackend = llm.backend;
    _llmEndpointCtrl = TextEditingController(text: llm.apiEndpoint);
    _llmA2cmEndpointCtrl = TextEditingController(text: llm.a2cmEndpoint);
    _llmApiKeyCtrl = TextEditingController(text: llm.apiKey);
    _llmModelCtrl = TextEditingController(text: llm.model);
    _llmTemperatureCtrl =
        TextEditingController(text: llm.temperature.toString());
    _llmMaxTokensCtrl = TextEditingController(text: llm.maxTokens.toString());
    _llmCustomHeadersCtrl =
        TextEditingController(text: llm.customHeaders);
  }

  @override
  void dispose() {
    _startCashCtrl.dispose();
    _passBonusCtrl.dispose();
    _jailTurnsCtrl.dispose();
    _hospitalTurnsCtrl.dispose();
    _maxUpgradeCtrl.dispose();
    _llmEndpointCtrl.dispose();
    _llmA2cmEndpointCtrl.dispose();
    _llmApiKeyCtrl.dispose();
    _llmModelCtrl.dispose();
    _llmTemperatureCtrl.dispose();
    _llmMaxTokensCtrl.dispose();
    _llmCustomHeadersCtrl.dispose();
    super.dispose();
  }

  bool _saveAll() {
    // Preserve fields this screen does not expose (e.g. rulesetId, maxPlayers)
    // by copying from the current config instead of using constructor defaults.
    final current = _config.game;
    final result = _config.updateSettings(game: GameConfig(
      rulesetId: current.rulesetId,
      maxPlayers: current.maxPlayers,
      startingCash: int.tryParse(_startCashCtrl.text) ?? current.startingCash,
      passStartBonus: int.tryParse(_passBonusCtrl.text) ?? current.passStartBonus,
      jailEscapeTurns: int.tryParse(_jailTurnsCtrl.text) ?? current.jailEscapeTurns,
      hospitalRecoveryTurns:
          int.tryParse(_hospitalTurnsCtrl.text) ?? current.hospitalRecoveryTurns,
      maxUpgradeLevel: int.tryParse(_maxUpgradeCtrl.text) ?? current.maxUpgradeLevel,
      extensionUpgradeEnabled: _extensionUpgradeEnabled,
      groupRentEnabled: _groupRentEnabled,
      stockMarketEnabled: _stockMarketEnabled,
      lotteryEnabled: _lotteryEnabled,
      auctionEnabled: _auctionEnabled,
      mortgageEnabled: _mortgageEnabled,
      tradeEnabled: _tradeEnabled,
    ), llmApi: LlmApiConfig(
      backend: _llmBackend,
      apiEndpoint: _llmEndpointCtrl.text,
      a2cmEndpoint: _llmA2cmEndpointCtrl.text,
      apiKey: _llmApiKeyCtrl.text,
      model: _llmModelCtrl.text,
      temperature: double.tryParse(_llmTemperatureCtrl.text) ?? 0.7,
      maxTokens: int.tryParse(_llmMaxTokensCtrl.text) ?? 512,
      customHeaders: _llmCustomHeadersCtrl.text,
    ));
    if (!mounted) return result.success;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.success ? '设置已保存' : result.error ?? '设置保存失败'),
        duration: Duration(seconds: 1),
      ),
    );
    return result.success;
  }

  @override
  Widget build(BuildContext context) {
    final seed = Theme.of(context).colorScheme.primary;
    final topColor = seed.withOpacity(0.85);
    final bottomColor = seed.withOpacity(0.50);

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [topColor, bottomColor],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(context),
              Expanded(
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      const SizedBox(height: 8),
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: Column(children: [
                            _buildGameRulesCard(),
                            const SizedBox(height: 16),
                            _buildLlmConfigCard(),
                            const SizedBox(height: 24),
                          ]),
                        ),
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

  Widget _buildAppBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          const Text(
            '设置',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: () {
              if ((_formKey.currentState?.validate() ?? false) && _saveAll()) {
                Navigator.of(context).pop(true);
              }
            },
            icon: const Icon(Icons.check_rounded,
                color: Colors.white, size: 20),
            label: const Text('完成',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ── Game Rules Card ──────────────────────────────────────────────────────

  Widget _buildGameRulesCard() {
    return _SectionCard(
      icon: Icons.tune_rounded,
      title: '游戏规则',
      color: const Color(0xFF43A047),
      children: [
        Column(
            children: [
              _buildNumField(_startCashCtrl, '起始资金 (\$)',
                  icon: Icons.monetization_on_outlined),
              const SizedBox(height: 10),
              _buildNumField(_passBonusCtrl, '经过起点奖金 (\$)',
                  icon: Icons.redeem_outlined),
              const SizedBox(height: 10),
              _buildNumField(_jailTurnsCtrl, '监狱回合数',
                  icon: Icons.lock_outline),
              const SizedBox(height: 10),
              _buildNumField(_hospitalTurnsCtrl, '医院回合数',
                  icon: Icons.local_hospital_outlined),
              const SizedBox(height: 10),
              _buildNumField(_maxUpgradeCtrl, '最高升级等级',
                  icon: Icons.star_outline,
                  subtitle: '0 = 禁用升级'),
            ],
        ),
        const SizedBox(height: 8),
        _buildSwitchTile('公共设施升级', '允许升级水电公司',
            _extensionUpgradeEnabled, (v) {
          setState(() => _extensionUpgradeEnabled = v);
        }),
        _buildSwitchTile('连带租金', '拥有完整色组时累加租金',
            _groupRentEnabled, (v) {
          setState(() => _groupRentEnabled = v);
        }),
        _buildSwitchTile('股票市场', '启用股票交易系统',
            _stockMarketEnabled, (v) {
          setState(() => _stockMarketEnabled = v);
        }),
        _buildSwitchTile('彩票系统', '启用彩票购买与抽奖',
            _lotteryEnabled, (v) {
          setState(() => _lotteryEnabled = v);
        }),
        _buildSwitchTile('拍卖机制', '放弃购买地产时进入拍卖',
            _auctionEnabled, (v) {
          setState(() => _auctionEnabled = v);
        }),
        _buildSwitchTile('抵押贷款', '允许抵押地产获得资金',
            _mortgageEnabled, (v) {
          setState(() => _mortgageEnabled = v);
        }),
        _buildSwitchTile('交易系统', '允许玩家之间交易地产和资金',
            _tradeEnabled, (v) {
          setState(() => _tradeEnabled = v);
        }),
      ],
    );
  }

  // ── LLM Config Card ──────────────────────────────────────────────────────

  Widget _buildLlmConfigCard() {
    return _SectionCard(
      icon: Icons.psychology_rounded,
      title: 'LLM AI 配置',
      color: const Color(0xFF9C27B0),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              const Text('LLM 后端',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              const Spacer(),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'direct', label: Text('直接 API')),
                  ButtonSegment(value: 'a2cm', label: Text('A2CM')),
                ],
                selected: {_llmBackend},
                 onSelectionChanged: (v) {
                   setState(() => _llmBackend = v.first);
                 },
              ),
            ],
          ),
        ),
        if (_llmBackend == 'a2cm') ...[
          _buildTextField(_llmA2cmEndpointCtrl, 'A2CM 地址',
              hint: 'http://localhost:8000', validator: _validateUrl),
          const SizedBox(height: 10),
          _buildTextField(
              _llmApiKeyCtrl, 'A2CM API 密钥（可选）',
              obscure: !_apiKeyVisible, suffixIcon: _buildApiKeyToggle(),
              onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
               onPressed: _testingConnection ? null : _testA2cmConnection,
               icon: _testingConnection
                   ? const SizedBox(width: 18, height: 18,
                       child: CircularProgressIndicator(strokeWidth: 2))
                   : const Icon(Icons.wifi_find_rounded, size: 18),
               label: Text(_testingConnection ? '正在测试' : '测试连接'),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                    color: Colors.white.withOpacity(0.3)),
              ),
            ),
          ),
        ] else ...[
          _buildTextField(_llmEndpointCtrl, 'API 端点',
              hint: 'https://api.openai.com/v1/chat/completions',
              validator: _validateUrl),
          _buildTextField(_llmApiKeyCtrl, 'API 密钥',
              obscure: !_apiKeyVisible, suffixIcon: _buildApiKeyToggle(),
              onChanged: (_) => setState(() {})),
          _buildTextField(_llmModelCtrl, '模型',
              hint: 'gpt-4', validator: _required),
          _buildTextField(
              _llmTemperatureCtrl, '温度 (0.0–2.0)',
              validator: _validateTemperature),
          _buildTextField(_llmMaxTokensCtrl, '最大 Token 数',
              validator: _validateMaxTokens),
          _buildTextField(
              _llmCustomHeadersCtrl, '自定义请求头 (JSON)',
              hint: '{"X-Custom-Header": "value"}',
              validator: _validateHeaders),
        ],
        const SizedBox(height: 8),
        Text(
          _llmBackend == 'a2cm'
              ? '选择 A2CM 后，游戏状态将通过 A2CM 协议发送到指定地址进行决策。'
               : '配置后，LLM 玩家将通过此 API 进行决策。提示词由游戏状态自动构建。',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withOpacity(0.5),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _apiKeyIsReference
              ? '密钥已安全存储在系统密钥链中，此处显示的是引用而非明文。'
              : '保存后密钥会自动存入系统密钥链，不会以明文写入配置文件；也可填写 env:变量名 手动引用。',
          style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.55)),
        ),
      ],
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Widget _buildNumField(TextEditingController ctrl, String label,
      {String? subtitle, IconData? icon}) {
    return TextFormField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      validator: (v) {
        if (v == null || v.isEmpty) return '请输入数值';
        final n = int.tryParse(v);
        if (n == null) return '无效数字';
        if (n < 0) return '不能为负数';
        return null;
      },
      decoration: InputDecoration(
        labelText: label,
        helperText: subtitle,
        helperStyle: TextStyle(
          color: Colors.white.withOpacity(0.30),
          fontSize: 10,
        ),
        prefixIcon: icon != null
            ? Icon(icon, color: Colors.white.withOpacity(0.40), size: 18)
            : null,
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.6)),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.redAccent),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.redAccent),
        ),
        errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 11),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  Widget _buildTextField(TextEditingController ctrl, String label,
      {bool obscure = false, String? hint, String? Function(String?)? validator,
      Widget? suffixIcon, ValueChanged<String>? onChanged}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: ctrl,
        obscureText: obscure,
        validator: validator,
        onChanged: onChanged,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixIcon: suffixIcon,
          labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.6)),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildApiKeyToggle() => IconButton(
        tooltip: _apiKeyVisible ? '隐藏密钥' : '显示密钥',
        onPressed: () => setState(() => _apiKeyVisible = !_apiKeyVisible),
        icon: Icon(_apiKeyVisible ? Icons.visibility_off : Icons.visibility),
      );

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '此项不能为空' : null;

  static const _loopbackHosts = {'localhost', '127.0.0.1', '::1'};

  String? _validateUrl(String? value) {
    final requiredError = _required(value);
    if (requiredError != null) return requiredError;
    final uri = Uri.tryParse(value!.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '请输入有效的 HTTP 或 HTTPS 地址';
    }
    // Refuse to send an API key over cleartext HTTP to non-loopback hosts.
    // This applies to plaintext keys and to stored references (keyring:/env:)
    // alike, because the backend resolves the reference and attaches the raw
    // key as a Bearer token on every request.
    if (uri.scheme == 'http' &&
        _llmApiKeyCtrl.text.trim().isNotEmpty &&
        !_loopbackHosts.contains(uri.host)) {
      return '配置密钥时非本地地址必须使用 HTTPS';
    }
    return null;
  }

  String? _validateTemperature(String? value) {
    final number = double.tryParse(value ?? '');
    return number == null || !number.isFinite || number < 0 || number > 2
        ? '温度必须在 0.0 到 2.0 之间'
        : null;
  }

  String? _validateMaxTokens(String? value) {
    final number = int.tryParse(value ?? '');
    return number == null || number < 1 || number > 32768
        ? 'Token 数必须在 1 到 32768 之间'
        : null;
  }

  String? _validateHeaders(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map || decoded.values.any((v) => v is! String)) {
        return '请求头必须是字符串键值的 JSON 对象';
      }
    } catch (_) {
      return '请输入有效的 JSON 对象';
    }
    return null;
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

  // ── A2CM Connection Test ─────────────────────────────────────────────────

  Future<void> _testA2cmConnection() async {
    if (_validateUrl(_llmA2cmEndpointCtrl.text) != null) {
      _formKey.currentState?.validate();
      return;
    }
    final url = _llmA2cmEndpointCtrl.text.isNotEmpty
        ? _llmA2cmEndpointCtrl.text
        : 'http://localhost:8000';
    final apiKey = _llmApiKeyCtrl.text;

    setState(() => _testingConnection = true);
    try {
      final engine = BridgeClient();
      final payload = jsonEncode({
        'command_type': 'core:command:llm_test_connection',
        'source': 'core',
        'payload': {
          'config': {
            'backend': 'a2cm',
            'a2cm_endpoint': url,
            'api_key': apiKey,
          },
        },
        'state': {},
      });
      final result = engine.engine.execute(payload);
      if (result == null) {
        _showTestResult('连接失败: 引擎不可用');
        return;
      }
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      if (decoded['ok'] != true ||
          decoded['service'] != 'a2cm' ||
          decoded['game'] != 'monopoly' ||
          decoded['protocol_version'] != 1) {
        final reason = decoded['error'] ?? '服务未返回 A2CM Monopoly 协议 v1 能力声明';
        _showTestResult('连接失败: $reason');
      } else {
        final backend = decoded['llm_backend'] ?? 'unknown';
        _showTestResult('A2CM 连接成功（协议 v1，模型后端: $backend）');
      }
    } catch (e) {
      _showTestResult('连接失败: $e');
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  void _showTestResult(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }
}

// ============================================================================
// Section card widget
// ============================================================================

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final List<Widget> children;

  const _SectionCard({
    required this.icon,
    required this.title,
    required this.color,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.30),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}
