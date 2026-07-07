import 'package:flutter/material.dart';
import 'map_models.dart';
import 'plugin_state.dart';

// ============================================================================
// Plugin Manager Screen – 插件管理
//
// Layout:
//   Left:   category list (内置, 本地)
//   Right:  plugin details + enable/disable controls
// ============================================================================

class PluginManagerScreen extends StatefulWidget {
  const PluginManagerScreen({super.key});

  @override
  State<PluginManagerScreen> createState() => _PluginManagerScreenState();
}

class _PluginManagerScreenState extends State<PluginManagerScreen> {
  // Demo data — in production, this comes from the Rust backend via FFI
  final List<PluginEntry> _builtinPlugins = [
    const PluginEntry(
      id: 'event_logger',
      name: '事件日志',
      version: '1.0.0',
      author: 'saMonopoly Team',
      description: '记录游戏中所有事件到日志文件',
      enabled: true,
      origin: 'builtin',
      permissions: ['ReadState'],
    ),
    const PluginEntry(
      id: 'bridge_broadcaster',
      name: '桥接广播器',
      version: '1.0.0',
      author: 'saMonopoly Team',
      description: '将游戏事件转发到 Flutter UI',
      enabled: true,
      origin: 'builtin',
      permissions: ['ReadState'],
    ),
  ];

  final List<PluginEntry> _localPlugins = [
    const PluginEntry(
      id: 'dice_stats',
      name: '骰子统计',
      version: '1.0.0',
      author: 'saMonopoly Team',
      description: '记录骰子投掷统计信息',
      enabled: true,
      origin: 'local',
      permissions: ['ReadState', 'EventInjection'],
    ),
    const PluginEntry(
      id: 'treasure_hunt',
      name: '宝藏猎人',
      version: '1.0.0',
      author: 'saMonopoly Team',
      description: '添加宝藏格子，玩家落地可获得随机奖励',
      enabled: false,
      origin: 'local',
      permissions: ['ReadState', 'WriteState', 'EventInjection'],
    ),
  ];

  int _selectedCategory = 0;
  int _selectedPluginIndex = 0;
  late List<List<PluginEntry>> _categories;
  late List<String> _categoryLabels;

  @override
  void initState() {
    super.initState();
    _categories = [
      _builtinPlugins,
      _localPlugins,
    ];
    _categoryLabels = ['📦 内置 (${_builtinPlugins.length})', '📂 本地 (${_localPlugins.length})'];
  }

  List<PluginEntry> get _currentList => _categories[_selectedCategory];
  PluginEntry get _selected =>
      _currentList.isNotEmpty ? _currentList[_selectedPluginIndex] : _dummy;

  static const _dummy = PluginEntry(id: '', name: '无插件');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        title: const Text('插件管理'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _currentList.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.extension_off_rounded,
                      size: 48, color: Colors.white24),
                  SizedBox(height: 12),
                  Text('暂无插件',
                      style: TextStyle(color: Colors.white38, fontSize: 16)),
                ],
              ),
            )
          : Row(
              children: [
                // Left: category + plugin list
                SizedBox(
                  width: 200,
                  child: _buildCategoryList(),
                ),
                // Right: plugin details
                Expanded(child: _buildDetailPanel()),
              ],
            ),
    );
  }

  Widget _buildCategoryList() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        border: Border(
          right: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Category tabs
          ...List.generate(_categories.length, (catIdx) {
            final isSelected = catIdx == _selectedCategory;
            return Material(
              color: isSelected
                  ? const Color(0xFF8E24AA).withOpacity(0.20)
                  : Colors.transparent,
              child: InkWell(
                onTap: () => setState(() {
                  _selectedCategory = catIdx;
                  _selectedPluginIndex = 0;
                }),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Icon(
                        catIdx == 0
                            ? Icons.inventory_2_rounded
                            : Icons.folder_rounded,
                        size: 18,
                        color: isSelected
                            ? const Color(0xFF8E24AA)
                            : Colors.white54,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _categoryLabels[catIdx],
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white54,
                          fontSize: 13,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          const Divider(color: Colors.white10, height: 1),
          // Plugin list under selected category
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _currentList.length,
              itemBuilder: (_, idx) {
                final plugin = _currentList[idx];
                final isSel = idx == _selectedPluginIndex;
                return Material(
                  color: isSel
                      ? const Color(0xFF8E24AA).withOpacity(0.12)
                      : Colors.transparent,
                  child: InkWell(
                    onTap: () => setState(() => _selectedPluginIndex = idx),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: plugin.enabled
                                  ? const Color(0xFF43A047)
                                  : Colors.white24,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              plugin.name,
                              style: TextStyle(
                                color: isSel ? Colors.white : Colors.white70,
                                fontSize: 13,
                                fontWeight: isSel
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailPanel() {
    final plugin = _selected;

    if (plugin.id.isEmpty) {
      return Center(
        child: Text('请选择一个插件',
            style: TextStyle(color: Colors.white.withOpacity(0.30))),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Plugin icon + name + version
          Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFF8E24AA).withOpacity(0.20),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.extension_rounded,
                    size: 32, color: Color(0xFFCE93D8)),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plugin.name,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'v${plugin.version} · ${plugin.author}',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withOpacity(0.50),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Description
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('简介',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  plugin.description,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.60),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Source info
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('来源',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                _infoRow(
                  '插件来源',
                  plugin.origin == 'builtin'
                      ? '内置'
                      : plugin.origin == 'local'
                          ? '本地安装'
                          : '地图捆绑',
                ),
                if (plugin.mandatory)
                  _infoRow('必要性', '● 必选',
                      valueColor: const Color(0xFFFFA726)),
                _infoRow('权限数', '${plugin.permissions.length}'),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Permissions
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('所需权限',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                ...plugin.permissions.map((perm) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle_outline,
                              size: 16, color: Color(0xFF43A047)),
                          const SizedBox(width: 8),
                          Text(
                            perm,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.50),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )),
                if (plugin.permissions.isEmpty)
                  Text(
                    '无需特殊权限',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.30), fontSize: 13),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Enable/disable button
          if (plugin.origin != 'builtin' && !plugin.mandatory)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  final idx = _categories[_selectedCategory].indexWhere((p) => p.id == plugin.id);
                  if (idx < 0) return;
                  final old = _categories[_selectedCategory][idx];
                  final newEnabled = !old.enabled;
                  PluginState().setEnabled(old.id, newEnabled);
                  setState(() {
                    _categories[_selectedCategory][idx] = PluginEntry(
                      id: old.id,
                      name: old.name,
                      version: old.version,
                      author: old.author,
                      description: old.description,
                      enabled: newEnabled,
                      origin: old.origin,
                      mandatory: old.mandatory,
                      permissions: old.permissions,
                    );
                  });
                },
                icon: Icon(plugin.enabled
                    ? Icons.toggle_off_outlined
                    : Icons.toggle_on_outlined),
                label: Text(plugin.enabled ? '禁用' : '启用'),
                style: FilledButton.styleFrom(
                  backgroundColor: plugin.enabled
                      ? Colors.red.withOpacity(0.80)
                      : const Color(0xFF43A047),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style:
                  TextStyle(color: Colors.white.withOpacity(0.40), fontSize: 13),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? Colors.white.withOpacity(0.70),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
