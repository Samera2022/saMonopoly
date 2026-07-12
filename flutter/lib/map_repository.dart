import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'bridge_client.dart';
import 'map_models.dart';
import 'map_parser.dart';
import 'smap_loader.dart';

// ============================================================================
// Map Repository – manages built-in and external maps
//
// Built-in maps are loaded directly from the asset bundle.
// External maps are scanned from the filesystem directory via Rust FFI.
// Both sources are merged into a single entries list with source labels.
//
// Built-in assets:
//   assets/maps/classic.smap     ← 经典大富翁（.smap ZIP 格式）
//   assets/maps/all_owned.json   ← 全所有权测试地图（JSON 格式）
//
// External directory (user-added .smap files only):
//   ~/.local/share/saMonopoly/maps/
//     └── my_custom_map.smap     ← 用户放入的 .smap 文件
// ============================================================================

/// Source of a map entry.
enum MapSource { builtin, external }

/// A discovered map entry with its source info.
class DiscoveredMap {
  final MapMeta meta;
  final MapDefinition definition;
  final MapSource source;
  final String? filePath;

  const DiscoveredMap({
    required this.meta,
    required this.definition,
    required this.source,
    this.filePath,
  });
}

/// Repository that manages both built-in and external maps.
class MapRepository {
  final BridgeClient _client;
  final SmapLoader _smapLoader;

  /// Built-in map assets (loaded directly from asset bundle, never seeded).
  static const List<String> _builtinAssets = [
    'assets/maps/classic.smap',
    'assets/maps/all_owned.json',
  ];

  MapCatalog _catalog = const MapCatalog();
  List<DiscoveredMap> _entries = [];
  bool _initialized = false;

  MapRepository({
    BridgeClient? client,
    SmapLoader? smapLoader,
  })  : _client = client ?? BridgeClient(),
        _smapLoader = smapLoader ?? const SmapLoader();

  MapCatalog get catalog => _catalog;
  List<DiscoveredMap> get entries => _entries;
  bool get initialized => _initialized;
  List<MapMeta> get maps => _entries.map((e) => e.meta).toList();

  /// Initialize: load built-in maps from assets + scan external directory.
  Future<void> initialize({String locale = 'zh'}) async {
    final globalI18n = await _loadGlobalI18n(locale);
    final definitions = <MapDefinition>[];
    final entries = <DiscoveredMap>[];

    // 1. Load built-in maps directly from assets
    await _loadBuiltinMaps(globalI18n, definitions, entries);

    // 2. Scan external directory for user-added .smap files
    await _loadExternalMaps(globalI18n, definitions, entries);

    // 3. Sort: built-in first (in _builtinAssets order), then externals by name
    entries.sort(_compareDiscoveredMaps);

    final catalogParser = MapParser(localizations: globalI18n);
    _catalog = catalogParser.buildCatalog(definitions);
    _entries = entries;
    _initialized = true;

    debugPrint(
      'MapRepository initialized: ${_entries.length} maps (built-in: ${_builtinAssets.length})',
    );
  }

  /// Load built-in maps directly from the asset bundle.
  Future<void> _loadBuiltinMaps(
    Map<String, String> globalI18n,
    List<MapDefinition> definitions,
    List<DiscoveredMap> entries,
  ) async {
    for (final assetPath in _builtinAssets) {
      try {
        if (assetPath.endsWith('.smap')) {
          final result = await _smapLoader.loadFromAsset(assetPath);
          if (result == null) {
            debugPrint('Failed to load built-in smap: $assetPath');
            continue;
          }
          definitions.add(result.definition);
          final displayName = _resolveName(
            result.definition.nameKey,
            globalI18n,
            result.localizations,
          );
          final description = _resolveDescription(
            result.definition.id,
            globalI18n,
            result.localizations,
          );
          final meta = MapMeta.fromDefinition(result.definition)
              .withResolvedName(displayName)
              .withDescription(description);
          entries.add(DiscoveredMap(
            meta: meta,
            definition: result.definition,
            source: MapSource.builtin,
            filePath: null,
          ));
          debugPrint('Loaded built-in map: $assetPath');
        } else if (assetPath.endsWith('.json')) {
          final jsonStr = await rootBundle.loadString(assetPath);
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;
          final def = MapDefinition.fromAutoDetect(json);
          definitions.add(def);
          final displayName = _resolveName(def.nameKey, globalI18n, null);
          final description = _resolveDescription(
            def.id,
            globalI18n,
            null,
          );
          final meta = MapMeta.fromDefinition(def)
              .withResolvedName(displayName)
              .withDescription(description);
          entries.add(DiscoveredMap(
            meta: meta,
            definition: def,
            source: MapSource.builtin,
            filePath: null,
          ));
          debugPrint('Loaded built-in map: $assetPath');
        }
      } catch (e) {
        debugPrint('Failed to load built-in map $assetPath: $e');
      }
    }
  }

  /// Scan the external directory for user-added .smap and .json files.
  /// Uses Rust FFI when available, falls back to Dart file I/O.
  Future<void> _loadExternalMaps(
    Map<String, String> globalI18n,
    List<MapDefinition> definitions,
    List<DiscoveredMap> entries,
  ) async {
    final dir = await _getMapsDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    debugPrint('[MapRepo] External maps dir: ${dir.path} (exists: ${await dir.exists()})');

    // Collect file entries (try FFI first, fall back to Dart)
    List<Map<String, dynamic>> fileEntries;
    final scanJson = _client.scanMaps(dir.path);
    if (scanJson != null) {
      final decoded = jsonDecode(scanJson);
      if (decoded is List) {
        fileEntries = decoded.cast<Map<String, dynamic>>();
        debugPrint('[MapRepo] FFI scan found ${fileEntries.length} files');
      } else if (decoded is Map && decoded['ok'] == false) {
        debugPrint('[MapRepo] FFI scan error: ${decoded['error']}');
        fileEntries = [];
      } else {
        fileEntries = [];
      }
    } else {
      // Dart fallback: list files manually
      fileEntries = [];
      debugPrint('[MapRepo] FFI scan unavailable, using Dart fallback');
      try {
        final entities = dir.list().toList();
        final files = await entities;
        for (final entity in files) {
          if (entity is File) {
            final p = entity.path;
            if (p.endsWith('.smap') || p.endsWith('.json')) {
              fileEntries.add({
                'path': p,
                'format': p.endsWith('.smap') ? 'smap' : 'json',
              });
            }
          }
        }
        debugPrint('[MapRepo] Dart scan found ${fileEntries.length} files in ${dir.path}');
      } catch (e) {
        debugPrint('[MapRepo] Dart scan error: $e');
      }
    }

    // Load each map file
    for (final entry in fileEntries) {
      final mapPath = entry['path'] as String?;
      if (mapPath == null) continue;
      if (!mapPath.endsWith('.smap') && !mapPath.endsWith('.json')) continue;

      try {
        MapDefinition definition;
        final loadJson = _client.loadMap(mapPath);
        if (loadJson != null) {
          final decoded = jsonDecode(loadJson);
          if (decoded is Map && decoded['ok'] == false) {
            debugPrint('FFI load error for $mapPath: ${decoded['error']}');
            continue;
          }
          definition = MapDefinition.fromAutoDetect(decoded as Map<String, dynamic>);
        } else {
          // Dart fallback: read file directly
          if (mapPath.endsWith('.smap')) {
            // Read .smap from disk without SmapLoader
            // (it may not exist in standalone mode)
            final bytes = await File(mapPath).readAsBytes();
            final jsonStr = utf8.decode(bytes);
            definition = MapDefinition.fromAutoDetect(jsonDecode(jsonStr) as Map<String, dynamic>);
          } else {
            final jsonStr = await File(mapPath).readAsString();
            definition = MapDefinition.fromAutoDetect(jsonDecode(jsonStr) as Map<String, dynamic>);
          }
        }

        definitions.add(definition);
        final displayName = _resolveName(definition.nameKey, globalI18n, null);
        final description = _resolveDescription(definition.id, globalI18n, null);
        final meta = MapMeta.fromDefinition(definition)
            .withResolvedName(displayName)
            .withDescription(description);
        entries.add(DiscoveredMap(
          meta: meta,
          definition: definition,
          source: MapSource.external,
          filePath: mapPath,
        ));
        debugPrint('Loaded external map: $mapPath');
      } catch (e) {
        debugPrint('Failed to load external map $mapPath: $e');
      }
    }
  }

  /// Load global i18n data.
  Future<Map<String, String>> _loadGlobalI18n(String locale) async {
    for (final l in [locale, 'zh', 'en']) {
      try {
        final i18nStr =
            await rootBundle.loadString('assets/i18n/$l.json');
        final decoded = jsonDecode(i18nStr) as Map<String, dynamic>;
        return decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {
        continue;
      }
    }
    return {};
  }

  /// Resolve display name using merged i18n sources.
  String _resolveName(
    String nameKey,
    Map<String, String> globalI18n,
    Map<String, Map<String, String>>? mapLocalizations,
  ) {
    final merged = <String, String>{
      ...globalI18n,
      if (mapLocalizations != null && mapLocalizations.containsKey('zh'))
        ...mapLocalizations['zh']!,
    };
    final p = MapParser(localizations: merged);
    return p.resolveName(nameKey);
  }

  /// Resolve map description using merged i18n sources.
  String _resolveDescription(
    String mapId,
    Map<String, String> globalI18n,
    Map<String, Map<String, String>>? mapLocalizations,
  ) {
    final merged = <String, String>{
      ...globalI18n,
      if (mapLocalizations != null && mapLocalizations.containsKey('zh'))
        ...mapLocalizations['zh']!,
    };
    final descKey = 'map.$mapId.desc';
    return merged[descKey] ?? '';
  }

  /// Comparison function for sorting discovered maps.
  /// Built-in maps come first (in _builtinAssets order), then externals by display name.
  int _compareDiscoveredMaps(DiscoveredMap a, DiscoveredMap b) {
    // Built-in maps: sorted by _builtinAssets order
    if (a.source == MapSource.builtin && b.source == MapSource.builtin) {
      final aIdx = _builtinAssets.indexWhere(
        (asset) => asset.endsWith('/${a.definition.id}.smap') ||
                     asset.endsWith('/${a.definition.id}.json'),
      );
      final bIdx = _builtinAssets.indexWhere(
        (asset) => asset.endsWith('/${b.definition.id}.smap') ||
                     asset.endsWith('/${b.definition.id}.json'),
      );
      return aIdx.compareTo(bIdx);
    }
    // Built-in comes before external
    if (a.source == MapSource.builtin) return -1;
    if (b.source == MapSource.builtin) return 1;
    // Both are external: sort by display name
    return a.meta.displayName.compareTo(b.meta.displayName);
  }

  /// Get the external maps directory path.
  Future<Directory> _getMapsDirectory() async {
    final appDir = await getApplicationSupportDirectory();
    return Directory('${appDir.path}/maps');
  }

  /// Get the path to the external maps directory (for UI display).
  Future<String> getMapsDirectoryPath() async {
    final dir = await _getMapsDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// Reload all maps.
  Future<void> reload({String locale = 'zh'}) async {
    _initialized = false;
    _entries = [];
    _catalog = const MapCatalog();
    await initialize(locale: locale);
  }
}
