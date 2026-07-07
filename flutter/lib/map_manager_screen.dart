import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';

import 'main.dart' show GameScreen;
import 'map_config_manager.dart';
import 'map_models.dart';
import 'map_repository.dart';
import 'map_selection_screen.dart';
import 'plugin_manager_screen.dart';
import 'save_manager.dart';

// ============================================================================
// Map Manager Screen – manage maps, config, and saves
//
// Layout:
//   Left (30%): search + toolbar + scrollable map list
//   Right (70%): thumbnail | info + controls | configs + saves
// ============================================================================

class MapManagerScreen extends StatefulWidget {
  const MapManagerScreen({super.key});

  @override
  State<MapManagerScreen> createState() => _MapManagerScreenState();
}

class _MapManagerScreenState extends State<MapManagerScreen> {
  final MapRepository _repository = MapRepository();
  final MapConfigManager _configManager = MapConfigManager();
  final SaveManager _saveManager = SaveManager();

  List<DiscoveredMap> _allMaps = [];
  List<DiscoveredMap> _filteredMaps = [];
  int _selectedIndex = 0;
  bool _loading = true;
  String _searchQuery = '';

  // Save list for selected map
  List<SaveMeta> _savesForSelected = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _configManager.load();
    await _repository.initialize(locale: 'zh');
    await _refreshSaves();
    if (!mounted) return;
    setState(() {
      _allMaps = _repository.entries;
      _applyFilter();
      _loading = false;
    });
  }

  Future<void> _refreshSaves() async {
    _savesForSelected = await _saveManager.listSaves();
  }

  void _applyFilter() {
    if (_searchQuery.isEmpty) {
      _filteredMaps = List.from(_allMaps);
    } else {
      final q = _searchQuery.toLowerCase();
      _filteredMaps = _allMaps.where((m) {
        return m.meta.displayName.toLowerCase().contains(q) ||
            m.meta.id.toLowerCase().contains(q);
      }).toList();
    }
    if (_selectedIndex >= _filteredMaps.length) {
      _selectedIndex = _filteredMaps.isNotEmpty ? 0 : -1;
    }
  }

  DiscoveredMap? get _selected =>
      _selectedIndex >= 0 && _selectedIndex < _filteredMaps.length
          ? _filteredMaps[_selectedIndex]
          : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: const Color(0xFF0D1117),
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: Colors.white54))
            : Row(
                children: [
                  _buildSidebar(),
                  const VerticalDivider(width: 1, color: Colors.white12),
                  Expanded(child: _buildDetailPanel()),
                ],
              ),
      ),
    );
  }

  // ── Left Sidebar ─────────────────────────────────────────────────────

  Widget _buildSidebar() {
    return SizedBox(
      width: 300,
      child: Column(
        children: [
          _buildSearchBar(),
          const Divider(height: 1, color: Colors.white12),
          Expanded(child: _buildMapList()),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 44, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Title with back button
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded,
                    color: Colors.white54, size: 20),
                onPressed: () => Navigator.of(context).pop(),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              const SizedBox(width: 4),
              const Text(
                '地图管理器',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${_filteredMaps.length}',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Search + toolbar
          Row(
            children: [
              // Search field
              Expanded(
                child: Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: TextField(
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '搜索地图...',
                      hintStyle:
                          TextStyle(color: Colors.white.withOpacity(0.30)),
                      prefixIcon: Icon(Icons.search,
                          color: Colors.white.withOpacity(0.30), size: 18),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() {
                      _searchQuery = v;
                      _applyFilter();
                    }),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _toolButton(Icons.add_rounded, '导入', _onImport),
              _toolButton(Icons.refresh_rounded, '刷新', _onRefresh),
              _toolButton(Icons.upload_rounded, '导出', _onExport),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toolButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            child:
                Icon(icon, color: Colors.white54, size: 18),
          ),
        ),
      ),
    );
  }

  Widget _buildMapList() {
    if (_filteredMaps.isEmpty) {
      return Center(
        child: Text(
          _searchQuery.isNotEmpty ? '没有匹配的地图' : '暂无地图',
          style: TextStyle(color: Colors.white.withOpacity(0.30)),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: _filteredMaps.length,
      itemBuilder: (_, i) => _buildMapListItem(i),
    );
  }

  Widget _buildMapListItem(int index) {
    final entry = _filteredMaps[index];
    final meta = entry.meta;
    final enabled = _configManager.isEnabled(meta.id);
    final selected = index == _selectedIndex;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withOpacity(0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: selected
            ? Border.all(color: Colors.white.withOpacity(0.15))
            : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _selectedIndex = index),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              // Tiny thumbnail
              Container(
                width: 40,
                height: 30,
                decoration: BoxDecoration(
                  color: meta.themeColor.withOpacity(0.30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Center(
                  child: Icon(Icons.map_rounded,
                      color: meta.themeColor.withOpacity(0.60), size: 18),
                ),
              ),
              const SizedBox(width: 10),
              // Name
              Expanded(
                child: Text(
                  meta.displayName,
                  style: TextStyle(
                    color: enabled ? Colors.white : Colors.white38,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Enable switch
              SizedBox(
                width: 36,
                height: 20,
                child: Switch(
                  value: enabled,
                  onChanged: (v) async {
                    await _configManager.setEnabled(meta.id, v);
                    setState(() {});
                  },
                  activeColor: const Color(0xFF43A047),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              // Arrow indicator when selected
              if (selected)
                Icon(Icons.chevron_right,
                    color: Colors.white.withOpacity(0.30), size: 18),
            ],
          ),
        ),
      ),
    );
  }

  // ── Right Detail Panel ───────────────────────────────────────────────

  Widget _buildDetailPanel() {
    final selected = _selected;
    if (selected == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined,
                color: Colors.white.withOpacity(0.15), size: 64),
            const SizedBox(height: 16),
            Text(
              '请选择一张地图以查看详情',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.30), fontSize: 15),
            ),
          ],
        ),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: _buildSelectedDetail(selected),
    );
  }

  Widget _buildSelectedDetail(DiscoveredMap entry) {
    final meta = entry.meta;
    final enabled = _configManager.isEnabled(meta.id);
    // Filter saves for this map
    final mapSaves = _savesForSelected
        .where((s) => s.mapId == meta.id)
        .toList();

    return SingleChildScrollView(
      key: ValueKey(meta.id),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Thumbnail ──────────────────────────────────────────────
          _buildThumbnail(meta),
          const SizedBox(height: 20),

          // ── Info + Controls ────────────────────────────────────────
          _buildInfoBar(meta, enabled),
          const SizedBox(height: 24),

          // ── Config + Saves split ───────────────────────────────────
          _buildConfigAndSaves(meta, enabled, mapSaves),
          const SizedBox(height: 24),

          // ── Plugin section ──────────────────────────────────────────
          _buildPluginSection(meta),
        ],
      ),
    );
  }

  Widget _buildThumbnail(MapMeta meta) {
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 480,
          height: 360,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  meta.themeColor.withOpacity(0.50),
                  meta.themeColor.withOpacity(0.20),
                  const Color(0xFF1A1A2E),
                ],
              ),
            ),
            child: Stack(
              children: [
                Center(
                  child: Icon(Icons.map_rounded,
                      size: 80,
                      color: meta.themeColor.withOpacity(0.30)),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black.withOpacity(0.60)],
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                meta.displayName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${meta.tileCount} tiles · v${meta.version}',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.60),
                                  fontSize: 12,
                                ),
                              ),
                            ],
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
      ),
    );
  }

  Widget _buildInfoBar(MapMeta meta, bool enabled) {
    return Row(
      children: [
        // Enable toggle
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: enabled
                ? const Color(0xFF43A047).withOpacity(0.15)
                : Colors.red.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: enabled
                  ? const Color(0xFF43A047).withOpacity(0.30)
                  : Colors.red.withOpacity(0.30),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                enabled ? Icons.check_circle : Icons.cancel,
                size: 16,
                color: enabled ? const Color(0xFF43A047) : Colors.red,
              ),
              const SizedBox(width: 6),
              Text(
                enabled ? '已启用' : '已禁用',
                style: TextStyle(
                  color: enabled ? const Color(0xFF43A047) : Colors.red,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // Play button
        FilledButton.icon(
          onPressed: enabled
              ? () => _onPlayMap(meta.id)
              : null,
          icon: const Icon(Icons.play_arrow_rounded, size: 20),
          label: const Text('开始游戏'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF43A047),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        const Spacer(),
        // Tile count badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '${meta.tileCount} 图块 · ${meta.propertyCount} 地产',
            style: TextStyle(
              color: Colors.white.withOpacity(0.50),
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConfigAndSaves(
      MapMeta meta, bool enabled, List<SaveMeta> saves) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Config column ────────────────────────────────────────────
        Expanded(
          child: _buildConfigColumn(meta, enabled),
        ),
        const SizedBox(width: 24),
        // ── Saves column ─────────────────────────────────────────────
        Expanded(
          child: _buildSavesColumn(saves),
        ),
      ],
    );
  }

  Widget _buildConfigColumn(MapMeta meta, bool enabled) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '环境/规则配置',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        _configTile('启用此地图', enabled, (v) async {
          await _configManager.setEnabled(meta.id, v);
          setState(() {});
        }),
        _configTile('允许股票市场', true, null),
        _configTile('允许彩票系统', true, null),
        _configTile('允许卡牌系统', true, null),
        _configTile('自动链接租金', true, null),
      ],
    );
  }

  Widget _configTile(String label, bool value, ValueChanged<bool>? onChanged) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          SizedBox(
          width: 32,
          height: 24,
          child: Checkbox(
            value: value,
            onChanged: (v) {
              if (v != null && onChanged != null) onChanged!(v);
            },
            activeColor: const Color(0xFF43A047),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSavesColumn(List<SaveMeta> saves) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '存档记录',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              '${saves.length}',
              style: TextStyle(color: Colors.white.withOpacity(0.30), fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (saves.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                '暂无存档',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.25), fontSize: 12),
              ),
            ),
          )
        else
          ...saves.map((save) => _buildSaveItem(save)),
      ],
    );
  }

  Widget _buildSaveItem(SaveMeta save) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  save.label,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '回合 ${save.currentTurn} · ${save.playerCount} 名玩家',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.35), fontSize: 10),
                ),
              ],
            ),
          ),
          // Load
          Tooltip(
            message: '载入',
            child: IconButton(
              icon: const Icon(Icons.play_arrow, color: Colors.green, size: 18),
              onPressed: () => _onLoadSave(save.fileName),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ),
          // Delete
          Tooltip(
            message: '删除',
            child: IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: Colors.redAccent, size: 18),
              onPressed: () => _onDeleteSave(save.fileName),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ),
        ],
      ),
    );
  }

  // ── Plugin section for map detail ──────────────────────────────────

  Widget _buildPluginSection(MapMeta meta) {
    // Demo bundled plugins for this map
    final bundledPlugins = [
      const MapPluginRef(
        id: 'economy_ext',
        name: '经济扩展',
        minVersion: '1.0.0',
        mandatory: true,
        source: 'bundled',
      ),
      const MapPluginRef(
        id: 'special_events',
        name: '特殊事件',
        minVersion: '2.0.0',
        mandatory: false,
        source: 'bundled',
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.extension_rounded,
                  size: 18, color: Color(0xFFCE93D8)),
              const SizedBox(width: 8),
              const Text(
                '插件管理',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PluginManagerScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('管理全部', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFCE93D8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '📦 地图自带插件',
            style: TextStyle(
                color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          ...bundledPlugins.map((p) => _buildPluginItem(p)),
          const SizedBox(height: 8),
          const Text(
            '📂 本地插件',
            style: TextStyle(
                color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          _buildPluginItem(const MapPluginRef(
            id: 'dice_stats',
            name: '骰子统计',
            source: 'external',
          )),
        ],
      ),
    );
  }

  Widget _buildPluginItem(MapPluginRef plugin) {
    final isBundled = plugin.source == 'bundled';
    final icon = isBundled ? Icons.inventory_2_rounded : Icons.folder_rounded;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.white38),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              plugin.name,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          if (plugin.mandatory)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFFFA726).withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('● 必选',
                  style: TextStyle(
                      color: Color(0xFFFFA726),
                      fontSize: 10,
                      fontWeight: FontWeight.w600)),
            ),
          if (!plugin.mandatory)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF43A047).withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('○ 可选',
                  style: TextStyle(
                      color: Color(0xFF43A047),
                      fontSize: 10,
                      fontWeight: FontWeight.w600)),
            ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF43A047).withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('已激活',
                style: TextStyle(
                    color: Color(0xFF43A047),
                    fontSize: 10,
                    fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  // ── Actions ──────────────────────────────────────────────────────────

  void _onPlayMap(String mapId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const MapSelectionScreen(),
      ),
    );
  }

  Future<void> _onLoadSave(String fileName) async {
    final result = await _saveManager.loadGame(fileName);
    if (!mounted) return;
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加载失败'), backgroundColor: Colors.redAccent),
      );
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => GameScreen(initialState: result.state),
      ),
      (route) => false,
    );
  }

  Future<void> _onDeleteSave(String fileName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除存档'),
        content: Text('确定要删除 $fileName 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _saveManager.deleteSave(fileName);
      await _refreshSaves();
      if (mounted) setState(() {});
    }
  }

  Future<void> _onImport() async {
    // Use file_picker to select .smap files
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['smap', 'json'],
        allowMultiple: true,
      );
      if (result == null) return;

      final dir = await _getMapsDir();
      int count = 0;
      for (final file in result.files) {
        if (file.path != null) {
          final src = File(file.path!);
          final dest = File('${dir.path}/${file.name}');
          await src.copy(dest.path);
          count++;
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 $count 个地图')),
      );
      await _onRefresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('导入失败: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _onRefresh() async {
    setState(() => _loading = true);
    await _repository.reload(locale: 'zh');
    await _refreshSaves();
    if (!mounted) return;
    setState(() {
      _allMaps = _repository.entries;
      _applyFilter();
      _loading = false;
    });
  }

  Future<void> _onExport() async {
    final selected = _selected;
    if (selected == null) return;

    try {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: '导出地图',
        fileName: '${selected.meta.id}.smap',
        type: FileType.custom,
        allowedExtensions: ['smap'],
      );
      if (result == null) return;

      // Copy from source to chosen path
      if (selected.filePath != null) {
        final src = File(selected.filePath!);
        await src.copy(result);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出到 $result')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('导出失败: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<Directory> _getMapsDir() async {
    final appDir = await getApplicationSupportDirectory();
    return Directory('${appDir.path}/maps');
  }
}
