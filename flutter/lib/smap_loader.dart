import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZipDecoder, ArchiveFile, Archive;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import 'map_models.dart';
import 'map_parser.dart';

/// Decode raw bytes from a ZIP entry as UTF-8 string.
/// [String.fromCharCodes] treats bytes as Latin-1, which garbles CJK text.
String _zipEntryContent(List<int> bytes) => utf8.decode(bytes);

// ============================================================================
// .smap loader – extracts map data from ZIP packages
//
// Format:
//   classic.smap
//   ├── map.json              # Map definition (required)
//   ├── thumbnail.png         # Thumbnail image (optional)
//   ├── lang/
//   │   ├── zh.json           # Chinese translations (optional)
//   │   ├── en.json           # English translations (optional)
//   │   └── ...               # Other locales
//   └── rules.json            # Custom rules override (optional)
// ============================================================================

/// Result of loading a .smap file.
class SmapResult {
  final MapDefinition definition;
  final Uint8List? thumbnailBytes;
  /// Locale-specific translations extracted from `lang/*.json`.
  /// Key = locale code (e.g. "zh", "en"), value = name_key → display name.
  final Map<String, Map<String, String>> localizations;

  const SmapResult({
    required this.definition,
    this.thumbnailBytes,
    this.localizations = const {},
  });
}

/// Loader for `.smap` (saMonopoly Map Package) ZIP files.
class SmapLoader {
  const SmapLoader();

  /// Load a .smap file from assets.
  Future<SmapResult?> loadFromAsset(String assetPath) async {
    try {
      final bytes = await rootBundle.load(assetPath);
      return _decode(bytes.buffer.asUint8List(), assetPath);
    } catch (e) {
      debugPrint('Failed to load .smap from asset "$assetPath": $e');
      return null;
    }
  }

  /// Load a .smap file from raw bytes (e.g. file picker).
  SmapResult? loadFromBytes(Uint8List bytes, {String? source}) {
    try {
      return _decode(bytes, source ?? 'bytes');
    } catch (e) {
      debugPrint('Failed to load .smap from $source: $e');
      return null;
    }
  }

  SmapResult? _decode(Uint8List bytes, String source) {
    final archive = ZipDecoder().decodeBytes(bytes);

    // Extract map.json (required)
    final mapFile = _findFile(archive, 'map.json');
    if (mapFile == null) {
      debugPrint('$source: missing map.json');
      return null;
    }
    final mapJson = jsonDecode(_zipEntryContent(mapFile.content as List<int>))
        as Map<String, dynamic>;
    final definition = MapDefinition.fromAutoDetect(mapJson);

    // Extract thumbnail.png (optional)
    Uint8List? thumbnailBytes;
    final thumbFile = _findFile(archive, 'thumbnail.png');
    if (thumbFile != null) {
      thumbnailBytes = thumbFile.content as Uint8List;
    }

    // Extract lang/*.json files (optional)
    final localizations = <String, Map<String, String>>{};
    for (final file in archive) {
      if (!file.isFile) continue;
      final fName = file.name;
      // Match files under lang/ directory with .json extension
      if (fName.startsWith('lang/') && fName.endsWith('.json') ||
          fName.startsWith('lang\\') && fName.endsWith('.json')) {
        final locale = fName
            .replaceAll(RegExp(r'^lang[/\\]'), '')
            .replaceAll('.json', '');
        try {
          final content = _zipEntryContent(file.content as List<int>);
          final decoded = jsonDecode(content) as Map<String, dynamic>;
          localizations[locale] =
              decoded.map((k, v) => MapEntry(k, v.toString()));
        } catch (e) {
          debugPrint('$source: failed to parse $fName: $e');
        }
      }
    }

    return SmapResult(
      definition: definition,
      thumbnailBytes: thumbnailBytes,
      localizations: localizations,
    );
  }

  /// Find a file in the archive ignoring directory prefixes.
  ArchiveFile? _findFile(Archive archive, String name) {
    for (final file in archive) {
      if (file.isFile) {
        final fName = file.name;
        // Match exact name or basename (ignore directory prefixes)
        if (fName == name ||
            fName.endsWith('/$name') ||
            fName.endsWith('\\$name')) {
          return file;
        }
      }
    }
    return null;
  }

  /// Scan a directory for .smap files and load all of them.
  Future<List<SmapResult>> scanDirectory(String assetDir) async {
    final results = <SmapResult>[];
    try {
      final manifest = await rootBundle.loadString('AssetManifest.json');
      final manifestMap =
          Map<String, dynamic>.from(jsonDecode(manifest) as Map);
      final smapFiles = manifestMap.keys
          .where((path) =>
              path.startsWith(assetDir) && path.endsWith('.smap'))
          .toList();

      for (final path in smapFiles) {
        final result = await loadFromAsset(path);
        if (result != null) {
          results.add(result);
        }
      }
    } catch (e) {
      debugPrint('Failed to scan .smap directory "$assetDir": $e');
    }
    return results;
  }
}

/// Build a [MapMeta] from an [SmapResult], resolving names using
/// the map's built-in localizations (lang/*.json) and global i18n.
MapMeta mapMetaFromSmapResult(
  SmapResult result, {
  Map<String, String> globalLocalizations = const {},
  String locale = 'zh',
}) {
  // Merge: map's own lang files take priority, then global i18n
  final merged = <String, String>{
    ...globalLocalizations,
    if (result.localizations.containsKey(locale))
      ...result.localizations[locale]!,
  };
  final parser = MapParser(localizations: merged);
  final meta =
      MapMeta.fromDefinition(result.definition).withResolvedName(
    parser.resolveName(result.definition.nameKey),
  );
  return meta;
}
