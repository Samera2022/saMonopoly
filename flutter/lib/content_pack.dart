import 'board_view.dart';

class ContentPackViewModel {
  final String id;
  final String version;
  final BoardViewModel board;

  const ContentPackViewModel({
    required this.id,
    required this.version,
    required this.board,
  });
}

ContentPackViewModel sampleClassicPack() {
  return const ContentPackViewModel(
    id: 'classic-pack',
    version: '0.1.0',
    board: BoardViewModel(
      mapName: 'Classic',
      tiles: [
        BoardTileViewModel(id: 'start', name: 'Start', kind: 'Start'),
        BoardTileViewModel(id: 'property_1', name: 'Property 1', kind: 'OrdinaryProperty'),
        BoardTileViewModel(id: 'opportunity_1', name: 'Opportunity', kind: 'Chance'),
        BoardTileViewModel(id: 'bank_1', name: 'Bank', kind: 'Bank'),
      ],
    ),
  );
}
