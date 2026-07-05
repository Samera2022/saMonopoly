import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

// ============================================================================
// Save Manager – manages game save files
//
// Directory: ~/.local/share/saMonopoly/saves/
// Format:    JSON matching Rust's SaveGame struct (save.rs)
// Extension: .sav
//
// SaveGame JSON structure:
//   { "version": "0.1.0", "state": { ... full GameState ... } }
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
class SaveManager {
  /// Get the saves directory path.
  Future<Directory> _getSavesDir() async {
    final appDir = await getApplicationSupportDirectory();
    return Directory('${appDir.path}/saves');
  }

  /// Ensure the saves directory exists.
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

  /// Save the current game state.
  ///
  /// [state] is the raw GameState JSON map.
  /// Returns the save file name on success, or null on failure.
  Future<String?> saveGame({
    required Map<String, dynamic> state,
    String? fileName,
  }) async {
    try {
      final dir = await _ensureSavesDir();
      final name = fileName ?? _generateFileName(_extractMapId(state));

      // Extract metadata for the filename
      final saveGame = {
        'version': '0.1.0',
        'state': state,
      };

      final file = File('${dir.path}/$name');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(saveGame),
      );
      debugPrint('Game saved: ${file.path}');
      return name;
    } catch (e) {
      debugPrint('Failed to save game: $e');
      return null;
    }
  }

  /// Load a saved game state.
  Future<SaveLoadResult?> loadGame(String fileName) async {
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

      // Extract metadata
      final meta = _extractMeta(fileName, state);
      return SaveLoadResult(meta: meta, state: state);
    } catch (e) {
      debugPrint('Failed to load save $fileName: $e');
      return null;
    }
  }

  /// List all available saves with metadata.
  Future<List<SaveMeta>> listSaves() async {
    final dir = await _getSavesDir();
    if (!await dir.exists()) return [];

    final saves = <SaveMeta>[];
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
    // Try to get map name from board tiles
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
      // Try to derive a map ID from the tile count
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
