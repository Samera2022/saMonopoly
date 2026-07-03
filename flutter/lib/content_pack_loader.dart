import 'dart:convert';

import 'content_pack.dart';
import 'board_view.dart';

class ContentPackLoader {
  const ContentPackLoader();

  ContentPackViewModel loadFromJson(String source) {
    final decoded = jsonDecode(source) as Map<String, dynamic>;
    final tiles = (decoded['board']['tiles'] as List<dynamic>)
        .map((tile) => BoardTileViewModel(
              id: tile['id'] as String,
              name: tile['name'] as String,
              kind: tile['kind'] as String,
            ))
        .toList();

    return ContentPackViewModel(
      id: decoded['id'] as String,
      version: decoded['version'] as String,
      board: BoardViewModel(
        mapName: decoded['board']['mapName'] as String,
        tiles: tiles,
      ),
    );
  }
}
