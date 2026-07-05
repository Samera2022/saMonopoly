import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import 'map_models.dart';

// ============================================================================
// Map parser – loads and parses Rust-format map data on the Flutter side
// ============================================================================

/// Parsed result containing all discovered maps.
class MapCatalog {
  final List<MapMeta> maps;
  final Map<String, MapDefinition> definitions;

  const MapCatalog({
    this.maps = const [],
    this.definitions = const {},
  });

  MapDefinition? getDefinition(String id) => definitions[id];
}

/// Loads maps from JSON assets and resolves i18n display names.
class MapParser {
  /// Localisation key → display name mapping (from i18n JSON).
  final Map<String, String> localizations;

  /// Map ID → description mapping.
  final Map<String, String> descriptions;

  const MapParser({
    this.localizations = const {},
    this.descriptions = const {},
  });

  // ─── Built-in i18n names (fallback) ──────────────────────────────────

  static const Map<String, String> _defaultNames = {
    'map.classic.name': '经典大富翁',
    'tile.start': '起点',
    'tile.jail': '监狱',
    'tile.freeParking': '免费停车',
    'tile.goToJail': '入狱',
    'tile.chance': '机会',
    'tile.incomeTax': '所得税',
    'tile.luxuryTax': '奢侈品税',
  };

  static const Map<String, String> _defaultNamesEn = {
    'map.classic.name': 'Classic Monopoly',
    'tile.start': 'Start',
    'tile.jail': 'Jail',
    'tile.freeParking': 'Free Parking',
    'tile.goToJail': 'Go To Jail',
    'tile.chance': 'Chance',
    'tile.incomeTax': 'Income Tax',
    'tile.luxuryTax': 'Luxury Tax',
  };

  /// Resolve a `name_key` to a display string.
  String resolveName(String nameKey) {
    if (localizations.containsKey(nameKey)) return localizations[nameKey]!;
    if (_defaultNames.containsKey(nameKey)) return _defaultNames[nameKey]!;
    if (_defaultNamesEn.containsKey(nameKey)) return _defaultNamesEn[nameKey]!;
    // Strip prefix for a readable fallback
    if (nameKey.startsWith('map.')) return nameKey.substring(4);
    if (nameKey.startsWith('tile.')) return nameKey.substring(5);
    if (nameKey.startsWith('prop.')) return nameKey.substring(5);
    return nameKey;
  }

  // ─── Parse a single MapDefinition from JSON ──────────────────────────

  MapDefinition parseDefinition(Map<String, dynamic> json) {
    return MapDefinition.fromAutoDetect(json);
  }

  // ─── Parse a ContentPack from JSON ───────────────────────────────────

  ContentPack parseContentPack(Map<String, dynamic> json) {
    return ContentPack.fromJson(json);
  }

  // ─── Parse a standalone builtin map file ─────────────────────────────

  MapDefinition parseBuiltinMap(Map<String, dynamic> json) {
    return MapDefinition.fromBuiltinJson(json);
  }

  // ─── Build MapMeta list from multiple definition sources ─────────────

  /// Build a catalog from a list of map definitions.
  MapCatalog buildCatalog(List<MapDefinition> definitions) {
    final mapMetas = <MapMeta>[];
    final defMap = <String, MapDefinition>{};

    for (final def in definitions) {
      defMap[def.id] = def;
      var meta = MapMeta.fromDefinition(def)
          .withResolvedName(resolveName(def.nameKey));
      // Try to set a description
      final descKey = 'map.${def.id}.desc';
      if (descriptions.containsKey(descKey)) {
        meta = meta.withDescription(descriptions[descKey]!);
      }
      mapMetas.add(meta);
    }

    return MapCatalog(maps: mapMetas, definitions: defMap);
  }

  // ─── Load from asset bundle ──────────────────────────────────────────

  /// Load a single map file from the assets bundle.
  Future<MapDefinition?> loadMapAsset(String assetPath) async {
    try {
      final jsonStr = await rootBundle.loadString(assetPath);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      return parseDefinition(json);
    } catch (e) {
      debugPrint('Failed to load map asset "$assetPath": $e');
      return null;
    }
  }

  /// Load a content pack from the assets bundle.
  Future<ContentPack?> loadContentPackAsset(String assetPath) async {
    try {
      final jsonStr = await rootBundle.loadString(assetPath);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      return ContentPack.fromJson(json);
    } catch (e) {
      debugPrint('Failed to load content pack asset "$assetPath": $e');
      return null;
    }
  }
}

/// Debug helper to print map info.
void debugPrintMapInfo(MapDefinition def) {
  // ignore: avoid_print
  debugPrint(
      'Map: ${def.id} v${def.version} | '
      '${def.tileCount} tiles, ${def.propertyCount} properties | '
      'rules: ${def.rules.allowCustomTopology}');
}
