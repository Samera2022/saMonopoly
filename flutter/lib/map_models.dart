import 'package:flutter/material.dart';

// ============================================================================
// Dart models mirroring Rust map data structures from:
//   crates/infra/src/map.rs     → MapDefinition, MapTile, MapRules, MapPluginRef
//   crates/infra/src/plugins.rs → PluginInfo, PluginOrigin, PluginStatus
//   crates/infra/src/content.rs → ContentPack
//   crates/domain/src/tile.rs   → TileKind (replaced by TileTypeId)
//   crates/domain/src/property.rs → Property
//   crates/domain/src/board.rs   → Board, BoardGraph
// ============================================================================

// ─── Tile type enum (mirrors crates/domain/src/tile.rs:TileKind) ──────────

enum TileKind {
  start,
  ordinaryProperty,
  specialProperty,
  extensionProperty,
  chance,
  cardShop,
  lottery,
  bank,
  jail,
  hospital,
  unknown;

  static TileKind fromString(String s) {
    switch (s) {
      case 'Start':
      case 'start':
        return TileKind.start;
      case 'OrdinaryProperty':
      case 'ordinary_property':
        return TileKind.ordinaryProperty;
      case 'SpecialProperty':
      case 'special_property':
        return TileKind.specialProperty;
      case 'ExtensionProperty':
      case 'extension_property':
        return TileKind.extensionProperty;
      case 'Chance':
      case 'chance':
        return TileKind.chance;
      case 'CardShop':
      case 'card_shop':
        return TileKind.cardShop;
      case 'Lottery':
      case 'lottery':
        return TileKind.lottery;
      case 'Bank':
      case 'bank':
        return TileKind.bank;
      case 'Jail':
      case 'jail':
        return TileKind.jail;
      case 'Hospital':
      case 'hospital':
        return TileKind.hospital;
      default:
        return TileKind.unknown;
    }
  }

  String get displayName {
    switch (this) {
      case TileKind.start:
        return 'Start';
      case TileKind.ordinaryProperty:
        return 'OrdinaryProperty';
      case TileKind.specialProperty:
        return 'SpecialProperty';
      case TileKind.extensionProperty:
        return 'ExtensionProperty';
      case TileKind.chance:
        return 'Chance';
      case TileKind.cardShop:
        return 'CardShop';
      case TileKind.lottery:
        return 'Lottery';
      case TileKind.bank:
        return 'Bank';
      case TileKind.jail:
        return 'Jail';
      case TileKind.hospital:
        return 'Hospital';
      case TileKind.unknown:
        return 'Unknown';
    }
  }

  /// Color associated with this tile kind for UI display.
  Color get color {
    switch (this) {
      case TileKind.start:
        return Colors.green;
      case TileKind.ordinaryProperty:
        return Colors.blue;
      case TileKind.specialProperty:
        return Colors.purple;
      case TileKind.extensionProperty:
        return Colors.teal;
      case TileKind.chance:
        return Colors.orange;
      case TileKind.cardShop:
        return Colors.amber;
      case TileKind.lottery:
        return Colors.red;
      case TileKind.bank:
        return Colors.brown;
      case TileKind.jail:
        return Colors.grey;
      case TileKind.hospital:
        return Colors.pink;
      case TileKind.unknown:
        return Colors.grey.shade300;
    }
  }
}

// ─── Map tile (mirrors crates/infra/src/map.rs:MapTile) ──────────────────

class MapTile {
  final String id;
  final String nameKey;
  final TileKind tileType;
  final Map<String, dynamic> attributes;

  const MapTile({
    required this.id,
    required this.nameKey,
    required this.tileType,
    this.attributes = const {},
  });

  factory MapTile.fromJson(Map<String, dynamic> json) {
    return MapTile(
      id: json['id'] as String? ?? '',
      nameKey: json['name_key'] as String? ?? '',
      tileType: TileKind.fromString(json['tile_type'] as String? ?? ''),
      attributes:
          json['attributes'] is Map<String, dynamic>
              ? json['attributes'] as Map<String, dynamic>
              : {},
    );
  }
}

// ─── Property definition (mirrors crates/domain/src/property.rs:Property) ─

class MapProperty {
  final String tileId;
  final int basePrice;
  final String? colorGroup;

  const MapProperty({
    required this.tileId,
    required this.basePrice,
    this.colorGroup,
  });

  factory MapProperty.fromJson(Map<String, dynamic> json) {
    return MapProperty(
      tileId: json['tile_id'] as String? ?? '',
      basePrice: (json['base_price'] as num?)?.toInt() ?? 0,
      colorGroup: json['color_group'] as String?,
    );
  }
}

// ─── Special tile config ─────────────────────────────────────────────────

class SpecialTileConfig {
  final String kind;
  final int? amount;
  final String? description;

  const SpecialTileConfig({
    required this.kind,
    this.amount,
    this.description,
  });

  factory SpecialTileConfig.fromJson(Map<String, dynamic> json) {
    return SpecialTileConfig(
      kind: json['kind'] as String? ?? '',
      amount: (json['amount'] as num?)?.toInt(),
      description: json['description'] as String?,
    );
  }
}

// ─── Map rules (mirrors crates/infra/src/map.rs:MapRules) ────────────────

class MapRules {
  final bool allowCustomTopology;
  final bool allowStockMarket;
  final bool allowLottery;
  final bool allowCardSystem;
  final bool autoLinkRent;
  final int? startingCash;
  final int? passStartBonus;
  final int? maxUpgradeLevel;

  const MapRules({
    this.allowCustomTopology = false,
    this.allowStockMarket = false,
    this.allowLottery = false,
    this.allowCardSystem = false,
    this.autoLinkRent = false,
    this.startingCash,
    this.passStartBonus,
    this.maxUpgradeLevel,
  });

  factory MapRules.fromJson(Map<String, dynamic> json) {
    return MapRules(
      allowCustomTopology:
          json['allow_custom_topology'] as bool? ?? false,
      allowStockMarket:
          json['allow_stock_market'] as bool? ?? false,
      allowLottery: json['allow_lottery'] as bool? ?? false,
      allowCardSystem:
          json['allow_card_system'] as bool? ?? false,
      autoLinkRent: json['auto_link_rent'] as bool? ?? false,
      startingCash: (json['starting_cash'] as num?)?.toInt(),
      passStartBonus: (json['pass_start_bonus'] as num?)?.toInt(),
      maxUpgradeLevel:
          (json['max_upgrade_level'] as num?)?.toInt(),
    );
  }
}

// ─── Map definition (mirrors crates/infra/src/map.rs:MapDefinition) ──────

class MapDefinition {
  final String id;
  final String version;
  final String nameKey;
  final List<MapTile> tiles;
  final MapRules rules;
  // Extra fields from content/maps/builtin/classic.json format
  final List<MapProperty> properties;
  final Map<String, SpecialTileConfig> specialTiles;
  final List<String> chanceTiles;
  /// Optional thumbnail image path (relative to map file location, e.g. "thumbnail/classic.png").
  final String? thumbnail;

  const MapDefinition({
    required this.id,
    required this.version,
    required this.nameKey,
    required this.tiles,
    required this.rules,
    this.properties = const [],
    this.specialTiles = const {},
    this.chanceTiles = const [],
    this.thumbnail,
  });

  int get tileCount => tiles.length;
  int get propertyCount => properties.length;

  /// Parse from the content/maps/builtin/*.json format (standalone map).
  factory MapDefinition.fromBuiltinJson(Map<String, dynamic> json) {
    // Parse tiles
    final tiles = (json['tiles'] as List<dynamic>?)
            ?.map((t) => MapTile(
                  id: t['id'] as String? ?? '',
                  nameKey: t['name_key'] as String? ?? '',
                  tileType:
                      TileKind.fromString(t['tile_type'] as String? ?? ''),
                ))
            .toList() ??
        [];

    // Parse properties (from the builtin format)
    final properties = (json['properties'] as List<dynamic>?)
            ?.map((p) => MapProperty.fromJson(p as Map<String, dynamic>))
            .toList() ??
        [];

    // Parse special tiles
    final specialTiles = <String, SpecialTileConfig>{};
    if (json['special_tiles'] is Map<String, dynamic>) {
      (json['special_tiles'] as Map<String, dynamic>).forEach((key, value) {
        if (value is Map<String, dynamic>) {
          specialTiles[key] = SpecialTileConfig.fromJson(value);
        }
      });
    }

    // Parse chance tiles
    final chanceTiles = (json['chance_tiles'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList() ??
        [];

    // Parse rules
    final rules = json['rules'] is Map<String, dynamic>
        ? MapRules.fromJson(json['rules'] as Map<String, dynamic>)
        : const MapRules();

    return MapDefinition(
      id: json['id'] as String? ?? '',
      version: json['version'] as String? ?? '',
      nameKey: json['name_key'] as String? ?? '',
      tiles: tiles,
      properties: properties,
      specialTiles: specialTiles,
      chanceTiles: chanceTiles,
      rules: rules,
      thumbnail: json['thumbnail'] as String?,
    );
  }

  /// Parse from the content/packs/*.json format (ContentPack-style MapDefinition).
  factory MapDefinition.fromPackJson(Map<String, dynamic> json) {
    final tiles = (json['tiles'] as List<dynamic>?)
            ?.map((t) => MapTile.fromJson(t as Map<String, dynamic>))
            .toList() ??
        [];

    final rules = json['rules'] is Map<String, dynamic>
        ? MapRules.fromJson(json['rules'] as Map<String, dynamic>)
        : const MapRules();

    return MapDefinition(
      id: json['id'] as String? ?? '',
      version: json['version'] as String? ?? '',
      nameKey: json['name_key'] as String? ?? '',
      tiles: tiles,
      rules: rules,
      thumbnail: json['thumbnail'] as String?,
    );
  }

  /// Auto-detect the format and parse accordingly.
  factory MapDefinition.fromAutoDetect(Map<String, dynamic> json) {
    // A builtin-format map has 'properties' and 'special_tiles' at the top level.
    if (json.containsKey('properties') || json.containsKey('special_tiles')) {
      return MapDefinition.fromBuiltinJson(json);
    }
    return MapDefinition.fromPackJson(json);
  }
}

// ─── Content pack (mirrors crates/infra/src/content.rs:ContentPack) ──────

class ContentPack {
  final String id;
  final String version;
  final String name;
  final String description;
  final String author;
  final List<MapDefinition> maps;
  final Map<String, String> metadata;

  const ContentPack({
    required this.id,
    required this.version,
    this.name = '',
    this.description = '',
    this.author = '',
    this.maps = const [],
    this.metadata = const {},
  });

  factory ContentPack.fromJson(Map<String, dynamic> json) {
    final maps = (json['maps'] as List<dynamic>?)
            ?.map((m) =>
                MapDefinition.fromAutoDetect(m as Map<String, dynamic>))
            .toList() ??
        [];

    return ContentPack(
      id: json['id'] as String? ?? '',
      version: json['version'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      author: json['author'] as String? ?? '',
      maps: maps,
      metadata: (json['metadata'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v.toString())) ??
          {},
    );
  }

  String get displayName => name.isNotEmpty ? name : id;
}

// ─── Parsed map metadata for the map selection UI ────────────────────────

class MapMeta {
  final String id;
  final String nameKey;
  final String displayName;
  final int tileCount;
  final int propertyCount;
  final String description;
  final String version;
  final Color themeColor;
  /// Thumbnail image asset path (e.g. "assets/maps/thumbnail/classic.png").
  final String? thumbnailPath;

  const MapMeta({
    required this.id,
    required this.nameKey,
    required this.displayName,
    required this.tileCount,
    this.propertyCount = 0,
    this.description = '',
    this.version = '',
    this.themeColor = Colors.green,
    this.thumbnailPath,
  });

  /// Derive a theme color from the tile kinds in the map.
  static Color _deriveThemeColor(MapDefinition def) {
    // Count tile kind frequencies
    final counts = <TileKind, int>{};
    for (final tile in def.tiles) {
      counts[tile.tileType] = (counts[tile.tileType] ?? 0) + 1;
    }
    // Pick the most frequent non-start, non-unknown kind
    TileKind? dominant;
    int maxCount = 0;
    for (final entry in counts.entries) {
      if (entry.key != TileKind.start &&
          entry.key != TileKind.unknown &&
          entry.value > maxCount) {
        dominant = entry.key;
        maxCount = entry.value;
      }
    }
    return dominant?.color ?? Colors.green;
  }

  factory MapMeta.fromDefinition(MapDefinition def) {
    return MapMeta(
      id: def.id,
      nameKey: def.nameKey,
      displayName: def.nameKey, // Will be resolved via i18n
      tileCount: def.tileCount,
      propertyCount: def.propertyCount,
      description: '',
      version: def.version,
      themeColor: _deriveThemeColor(def),
      thumbnailPath: def.thumbnail,
    );
  }

  MapMeta withResolvedName(String resolvedName) {
    return MapMeta(
      id: id,
      nameKey: nameKey,
      displayName: resolvedName,
      tileCount: tileCount,
      propertyCount: propertyCount,
      description: description,
      version: version,
      themeColor: themeColor,
      thumbnailPath: thumbnailPath,
    );
  }

  MapMeta withDescription(String desc) {
    return MapMeta(
      id: id,
      nameKey: nameKey,
      displayName: displayName,
      tileCount: tileCount,
      propertyCount: propertyCount,
      description: desc,
      version: version,
      themeColor: themeColor,
      thumbnailPath: thumbnailPath,
    );
  }

  /// Derive the full asset path for the thumbnail.
  /// If [thumbnailPath] is already an absolute asset path, use it as-is.
  /// Otherwise prepend the default maps asset directory.
  String? get resolvedThumbnailPath {
    if (thumbnailPath == null) return null;
    // If it already starts with "assets/", use directly
    if (thumbnailPath!.startsWith('assets/')) return thumbnailPath;
    // Otherwise it's relative to the maps asset dir
    return 'assets/maps/$thumbnailPath';
  }
}

// ============================================================================
// Plugin models (mirrors crates/infra/src/plugins.rs)
// ============================================================================

/// Plugin metadata for display
class PluginEntry {
    final String id;
    final String name;
    final String version;
    final String author;
    final String description;
    final bool enabled;
    final String origin; // "local", "bundled", "builtin"
    final bool mandatory;
    final List<String> permissions;
  
    const PluginEntry({
      required this.id,
      required this.name,
      this.version = '',
      this.author = '',
      this.description = '',
      this.enabled = false,
      this.origin = 'builtin',
      this.mandatory = false,
      this.permissions = const [],
    });
  
    factory PluginEntry.fromJson(Map<String, dynamic> json) {
      return PluginEntry(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        version: json['version'] as String? ?? '',
        author: json['author'] as String? ?? '',
        description: json['description'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? false,
        origin: (json['origin'] is Map<String, dynamic>)
            ? (json['origin'] as Map<String, dynamic>).keys.first
            : 'builtin',
        mandatory: _isMandatory(json['origin']),
        permissions: _parsePermissions(json['required_permissions']),
      );
    }
  
    static bool _isMandatory(dynamic origin) {
      if (origin is Map<String, dynamic>) {
        final bundled = origin['Bundled'];
        if (bundled is Map<String, dynamic>) {
          return bundled['mandatory'] as bool? ?? false;
        }
      }
      return false;
    }
  
    static List<String> _parsePermissions(dynamic perms) {
      if (perms is Map<String, dynamic>) {
        final granted = perms['granted'];
        if (granted is List) {
          return granted.cast<String>();
        }
      }
      return [];
    }
  }
  
  /// Map plugin reference (mirrors crates/infra/src/map.rs:MapPluginRef)
  class MapPluginRef {
    final String id;
    final String name;
    final String minVersion;
    final bool mandatory;
    final String source; // "bundled" or "external"
  
    const MapPluginRef({
      required this.id,
      required this.name,
      this.minVersion = '',
      this.mandatory = false,
      this.source = 'external',
    });
  
    factory MapPluginRef.fromJson(Map<String, dynamic> json) {
      return MapPluginRef(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        minVersion: json['min_version'] as String? ?? '',
        mandatory: json['mandatory'] as bool? ?? false,
        source: json['source'] as String? ?? 'external',
      );
    }
  }
