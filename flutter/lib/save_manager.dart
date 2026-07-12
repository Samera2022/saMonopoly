import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import 'bridge_client.dart';

// ============================================================================
// Save Manager – manages game save files
//
// Directory (Dart I/O fallback): ~/.local/share/saMonopoly/saves/
// Directory (FFI path):          Rust config dir + /saves/
// Format:    JSON matching Rust's SaveGame struct (save.rs)
// Extension: .sav
//
// SaveGame JSON structure:
//   { "version": "0.1.0", "state": { ... full GameState ... } }
//
// When a BridgeClient is provided, the FFI path is preferred. If the FFI
// function is unavailable or fails, the Dart I/O fallback is used.
// ============================================================================

/// Metadata extracted from a save file for display in the load UI.
class SaveMeta {
  final String fileName;
  final String mapId;
  final int playerCount;
  final int currentTurn;
  final int activePlayerIndex;
  final DateTime timestamp;
  final String label;

  const SaveMeta({
    required this.fileName,
    required this.mapId,
    required this.playerCount,
    required this.currentTurn,
    required this.activePlayerIndex,
    required this.timestamp,
    required this.label,
  });

  /// Human-readable summary.
  String get summary =>
      '$mapId · 回合 $currentTurn · ${playerCount}名玩家';
}

/// Result of loading a save.
class SaveLoadResult {
  final SaveMeta meta;
  final Map<String, dynamic> state;

  const SaveLoadResult({required this.meta, required this.state});
}

/// Manages game save files on the external storage.
///
/// If a [BridgeClient] is provided, the Rust FFI path is attempted first.
/// Falls back to Dart I/O when FFI is unavailable or returns an error.
class SaveManager {
  final BridgeClient? _bridge;

  SaveManager({BridgeClient? bridge}) : _bridge = bridge;

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Check whether the FFI path is usable.
  bool get _ffiAvailable => _bridge != null && _bridge!.engine.isAvailable;

  /// Get the saves directory path (Dart I/O fallback).
  Future<Directory> _getSavesDir() async {
    final appDir = await getApplicationSupportDirectory();
    return Directory('${appDir.path}/saves');
  }

  /// Ensure the saves directory exists (Dart I/O fallback).
  Future<Directory> _ensureSavesDir() async {
    final dir = await _getSavesDir();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Generate a save file name from map ID and timestamp.
  String _generateFileName(String mapId) {
    final now = DateTime.now();
    final ts = '${now.year}${_pad(now.month)}${_pad(now.day)}_'
        '${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}';
    return '${mapId}_$ts.sav';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  /// Try to parse a SaveLoadResult from a raw save JSON string.
  SaveLoadResult? _parseSaveContent(String fileName, String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final state = decoded['state'] as Map<String, dynamic>?;
      if (state == null) return null;
      final meta = _extractMeta(fileName, state);
      return SaveLoadResult(meta: meta, state: state);
    } catch (_) {
      return null;
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Save the current game state.
  ///
  /// [state] is the raw GameState JSON map.
  /// Returns the save file name on success, or null on failure.
  Future<String?> saveGame({
    required Map<String, dynamic> state,
    String? fileName,
  }) async {
    // Try FFI path first
    if (_ffiAvailable) {
      try {
        final name = fileName ?? _generateFileName(_extractMapId(state));
        final payload = jsonEncode({
          'file_name': name.replaceAll('.sav', ''),
          'state': state,
        });
        final result = _bridge!.saveGame(payload);
        if (result != null) {
          final parsed = jsonDecode(result) as Map<String, dynamic>;
          if (parsed['ok'] == true) {
            debugPrint('Game saved via FFI: $name');
            return name;
          }
          debugPrint('FFI save returned error, falling back: ${parsed['error']}');
        }
      } catch (e) {
        debugPrint('FFI save failed, falling back: $e');
      }
    }

    // Dart I/O fallback
    try {
      final dir = await _ensureSavesDir();
      final name = fileName ?? _generateFileName(_extractMapId(state));

      final saveGame = {
        'version': '0.1.0',
        'state': state,
      };

      final file = File('${dir.path}/$name');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(saveGame),
      );
      debugPrint('Game saved (Dart I/O): ${file.path}');
      return name;
    } catch (e) {
      debugPrint('Failed to save game: $e');
      return null;
    }
  }

  /// Load a saved game state.
  Future<SaveLoadResult?> loadGame(String fileName) async {
    // Try FFI path first
    if (_ffiAvailable) {
      try {
        final result = _bridge!.loadGame(fileName);
        if (result != null) {
          final parsed = jsonDecode(result) as Map<String, dynamic>;
          // FFI load returns the SaveGame JSON directly on success,
          // or {"ok": false, "error": "..."} on failure.
          if (parsed.containsKey('state')) {
            final saveContent = result;
            final parsedResult = _parseSaveContent(fileName, saveContent);
            if (parsedResult != null) {
              debugPrint('Game loaded via FFI: $fileName');
              return parsedResult;
            }
          } else if (parsed['ok'] == false) {
            debugPrint('FFI load returned error, falling back: ${parsed['error']}');
          }
        }
      } catch (e) {
        debugPrint('FFI load failed, falling back: $e');
      }
    }

    // Dart I/O fallback
    try {
      final dir = await _getSavesDir();
      final file = File('${dir.path}/$fileName');

      if (!await file.exists()) {
        debugPrint('Save file not found: $fileName');
        return null;
      }

      final jsonStr = await file.readAsString();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final state = decoded['state'] as Map<String, dynamic>;

      final meta = _extractMeta(fileName, state);
      return SaveLoadResult(meta: meta, state: state);
    } catch (e) {
      debugPrint('Failed to load save $fileName: $e');
      return null;
    }
  }

  /// List all available saves with metadata.
  Future<List<SaveMeta>> listSaves() async {
    final saves = <SaveMeta>[];

    // Try FFI path first
    if (_ffiAvailable) {
      try {
        final result = _bridge!.listSaves();
        if (result != null) {
          final list = jsonDecode(result) as List<dynamic>;
          for (final entry in list) {
            final fileObj = entry as Map<String, dynamic>;
            final fileName = fileObj['file_name'] as String?;
            if (fileName == null) continue;

            // Load each save to extract metadata via FFI
            try {
              final loadResult = _bridge!.loadGame(fileName);
              if (loadResult != null) {
                final parsed = jsonDecode(loadResult) as Map<String, dynamic>;
                if (parsed.containsKey('state')) {
                  final state = parsed['state'] as Map<String, dynamic>;
                  saves.add(_extractMeta(fileName, state));
                }
              }
            } catch (_) {
              // Skip corrupt saves
            }
          }
          if (saves.isNotEmpty) {
            saves.sort((a, b) => b.timestamp.compareTo(a.timestamp));
            debugPrint('Listed ${saves.length} saves via FFI');
            return saves;
          }
        }
      } catch (e) {
        debugPrint('FFI listSaves failed, falling back: $e');
      }
    }

    // Dart I/O fallback
    final dir = await _getSavesDir();
    if (!await dir.exists()) return [];

    try {
      final files = await dir.list().toList();
      for (final entity in files) {
        if (entity is! File || !entity.path.endsWith('.sav')) continue;
        try {
          final content = await entity.readAsString();
          final decoded = jsonDecode(content) as Map<String, dynamic>;
          final state = decoded['state'] as Map<String, dynamic>?;
          if (state == null) continue;

          final fileName = entity.uri.pathSegments.last;
          saves.add(_extractMeta(fileName, state));
        } catch (_) {
          // Skip corrupted saves
        }
      }
    } catch (e) {
      debugPrint('Failed to list saves: $e');
    }

    // Sort by timestamp descending (newest first)
    saves.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return saves;
  }

  /// Delete a save file.
  Future<bool> deleteSave(String fileName) async {
    // Try FFI path first
    if (_ffiAvailable) {
      try {
        final result = _bridge!.deleteSave(fileName);
        if (result != null) {
          final parsed = jsonDecode(result) as Map<String, dynamic>;
          if (parsed['ok'] == true) {
            debugPrint('Save deleted via FFI: $fileName');
            return true;
          }
          debugPrint('FFI delete returned error, falling back: ${parsed['error']}');
        }
      } catch (e) {
        debugPrint('FFI delete failed, falling back: $e');
      }
    }

    // Dart I/O fallback
    try {
      final dir = await _getSavesDir();
      final file = File('${dir.path}/$fileName');
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Failed to delete save $fileName: $e');
      return false;
    }
  }

  /// Check if any saves exist.
  Future<bool> hasSaves() async {
    // Try FFI path first
    if (_ffiAvailable) {
      try {
        final result = _bridge!.listSaves();
        if (result != null) {
          final list = jsonDecode(result) as List<dynamic>;
          if (list.isNotEmpty) return true;
        }
      } catch (_) {}
    }

    // Dart I/O fallback
    final dir = await _getSavesDir();
    if (!await dir.exists()) return false;
    try {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.sav')) return true;
      }
    } catch (_) {}
    return false;
  }

  // ── Metadata extraction ─────────────────────────────────────────────

  String _extractMapId(Map<String, dynamic> state) {
    final board = state['board'] as Map<String, dynamic>?;
    if (board == null) return 'unknown';
    final tiles = board['tiles'] as List<dynamic>?;
    if (tiles == null || tiles.isEmpty) return 'unknown';
    return 'game';
  }

  SaveMeta _extractMeta(String fileName, Map<String, dynamic> state) {
    final board = state['board'] as Map<String, dynamic>? ?? {};
    final tiles = board['tiles'] as List<dynamic>? ?? [];
    final players = state['players'] as List<dynamic>? ?? [];
    final currentTurn = (state['current_turn'] as num?)?.toInt() ?? 0;
    final activeIdx = (state['active_player_index'] as num?)?.toInt() ?? 0;

    // Extract map ID from board
    String mapId = 'unknown';
    if (tiles.isNotEmpty) {
      final count = tiles.length;
      mapId = count >= 40 ? 'classic' : 'map_${count}tiles';
    }

    // Extract timestamp from filename: "mapId_20260705_120000.sav"
    DateTime timestamp;
    try {
      final parts = fileName.replaceAll('.sav', '').split('_');
      if (parts.length >= 3) {
        final dateStr = parts[parts.length - 2];
        final timeStr = parts[parts.length - 1];
        final year = int.parse(dateStr.substring(0, 4));
        final month = int.parse(dateStr.substring(4, 6));
        final day = int.parse(dateStr.substring(6, 8));
        final hour = int.parse(timeStr.substring(0, 2));
        final minute = int.parse(timeStr.substring(2, 4));
        final second = int.parse(timeStr.substring(4, 6));
        timestamp = DateTime(year, month, day, hour, minute, second);
      } else {
        timestamp = DateTime.now();
      }
    } catch (_) {
      timestamp = DateTime.now();
    }

    // Readable label
    final ts = '${_pad(timestamp.month)}/${_pad(timestamp.day)} '
        '${_pad(timestamp.hour)}:${_pad(timestamp.minute)}';

    return SaveMeta(
      fileName: fileName,
      mapId: mapId,
      playerCount: players.length,
      currentTurn: currentTurn,
      activePlayerIndex: activeIdx,
      timestamp: timestamp,
      label: '$mapId · 回合 $currentTurn · $ts',
    );
  }
}
