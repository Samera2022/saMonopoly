import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

// ============================================================================
// Map Config Manager – manages per-map enable/disable state
//
// Persisted to: ~/.local/share/com.example.sa_monopoly/map_config.json
// ============================================================================

class MapConfigManager {
  Map<String, bool> _enabled = {};
  bool _loaded = false;

  /// Whether a map is enabled.
  bool isEnabled(String mapId) => _enabled[mapId] ?? true;

  /// Enable or disable a map.
  Future<void> setEnabled(String mapId, bool enabled) async {
    _enabled[mapId] = enabled;
    await _save();
  }

  /// Load config from disk.
  Future<void> load() async {
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        _enabled = json.map((k, v) => MapEntry(k, v as bool));
      }
    } catch (e) {
      debugPrint('Failed to load map config: $e');
    }
    _loaded = true;
  }

  /// Save config to disk.
  Future<void> _save() async {
    try {
      final file = await _getFile();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_enabled),
      );
    } catch (e) {
      debugPrint('Failed to save map config: $e');
    }
  }

  Future<File> _getFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/map_config.json');
  }
}
