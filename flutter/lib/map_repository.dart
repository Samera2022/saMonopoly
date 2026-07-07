import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'map_models.dart';
import 'map_parser.dart';
import 'smap_loader.dart';

// ============================================================================
// Map Repository – manages built-in and external maps
//
// All maps are stored in the external directory, scanned at runtime.
// Built-in maps are seeded on first launch by copying from assets.
//
// Directory:
//   ~/.local/share/saMonopoly/maps/
//     ├── classic.smap              ← 内置地图（首次启动时从 asset 复制）
//     └── my_custom_map.smap        ← 用户放入的 .smap 文件
//
//   No hardcoded paths, no AssetManifest.json, pure filesystem scanning.
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

/// Repository that discovers maps from the external filesystem directory.
class MapRepository {
  final MapParser _parser;
  final SmapLoader _smapLoader;

  /// Built-in map assets to seed on first launch.
  static const List<String> _builtinAssets = [
    'assets/maps/classic.smap',
  ];

  MapCatalog _catalog = const MapCatalog();
  List<DiscoveredMap> _entries = [];
  bool _initialized = false;

  MapRepository({
    MapParser? parser,
    SmapLoader? smapLoader,
  })  : _parser = parser ?? const MapParser(),
        _smapLoader = smapLoader ?? const SmapLoader();

  MapCatalog get catalog => _catalog;
  List<DiscoveredMap> get entries => _entries;
  bool get initialized => _initialized;
  List<MapMeta> get maps => _entries.map((e) => e.meta).toList();

  /// Initialize: seed built-in maps if needed, then scan the directory.
  Future<void> initialize({String locale = 'zh'}) async {
    final dir = await _getMapsDirectory();

    // Ensure directory exists
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Seed built-in maps if directory has no map files yet
    final hasMaps = await _directoryHasMaps(dir);
    if (!hasMaps) {
      await _seedBuiltinMaps(dir);
    }

    // Scan the directory
    await _scanDirectory(dir, locale);
    _initialized = true;

    debugPrint(
      'MapRepository initialized: ${_entries.length} maps from ${dir.path}',
    );
  }

  /// Check if the directory already has any map files.
  Future<bool> _directoryHasMaps(Directory dir) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is File &&
            (entity.path.endsWith('.smap') || entity.path.endsWith('.json'))) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Copy built-in maps from assets to the external directory.
  Future<void> _seedBuiltinMaps(Directory dir) async {
    for (final assetPath in _builtinAssets) {
      try {
        final fileName = assetPath.split('/').last;
        final data = await rootBundle.load(assetPath);
        final file = File('${dir.path}/$fileName');
        await file.writeAsBytes(data.buffer.asUint8List());
        debugPrint('Seeded built-in map: $fileName (${data.lengthInBytes} bytes)');
      } catch (e) {
        debugPrint('Failed to seed $assetPath: $e');
      }
    }
  }

  /// Scan the external directory for .smap and .json files.
  Future<void> _scanDirectory(Directory dir, String locale) async {
    final definitions = <MapDefinition>[];
    final entries = <DiscoveredMap>[];

    // Load global i18n
    final globalI18n = await _loadGlobalI18n(locale);

    try {
      final contents = await dir.list().toList();
      for (final entity in contents) {
        if (entity is! File) continue;
        final path = entity.path;

        try {
          if (path.endsWith('.smap')) {
            final bytes = await entity.readAsBytes();
            final result = _smapLoader.loadFromBytes(bytes, source: path);
            if (result != null) {
              definitions.add(result.definition);
              final displayName = _resolveName(
                result.definition.nameKey,
                globalI18n,
                result.localizations,
              );
              final meta = MapMeta.fromDefinition(result.definition)
                  .withResolvedName(displayName);
              entries.add(DiscoveredMap(
                meta: meta,
                definition: result.definition,
                source: MapSource.external,
                filePath: path,
              ));
            }
          } else if (path.endsWith('.json')) {
            final jsonStr = await entity.readAsString();
            final json = jsonDecode(jsonStr) as Map<String, dynamic>;
            final def = MapDefinition.fromAutoDetect(json);
            definitions.add(def);
            final displayName = _resolveName(def.nameKey, globalI18n, null);
            final meta =
                MapMeta.fromDefinition(def).withResolvedName(displayName);
            entries.add(DiscoveredMap(
              meta: meta,
              definition: def,
              source: MapSource.external,
              filePath: path,
            ));
          }
        } catch (e) {
          debugPrint('Failed to load map $path: $e');
        }
      }
    } catch (e) {
      debugPrint('Failed to scan maps directory: $e');
    }

    final catalogParser = MapParser(localizations: globalI18n);
    _catalog = catalogParser.buildCatalog(definitions);
    _entries = entries;
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

  /// Get the external maps directory.
  Future<Directory> _getMapsDirectory() async {
    final appDir = await getApplicationSupportDirectory();
    return Directory('${appDir.path}/maps');
  }

  /// Get the path to the external maps directory.
  Future<String> getMapsDirectoryPath() async {
    final dir = await _getMapsDirectory();
    await dir.create(recursive: true);
    return dir.path;
  }

  /// Reload maps from the directory.
  Future<void> reload({String locale = 'zh'}) async {
    _initialized = false;
    _entries = [];
    _catalog = const MapCatalog();
    await initialize(locale: locale);
  }
}
