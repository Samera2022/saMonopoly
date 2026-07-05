import 'package:flutter/material.dart';

/// Card info for display in the inventory.
class _CardInfo {
  final String id;
  final String name;
  final String description;
  final IconData icon;

  const _CardInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
  });
}

const Map<String, _CardInfo> _kCardInfo = {
  'get_out_of_jail': _CardInfo(
    id: 'get_out_of_jail',
    name: 'Get Out of Jail',
    description: 'Exit jail immediately (auto-used on roll)',
    icon: Icons.lock_open,
  ),
  'bonus_200': _CardInfo(
    id: 'bonus_200',
    name: 'Bonus \$200',
    description: 'Receive \$200 cash immediately',
    icon: Icons.monetization_on,
  ),
  'double_rent': _CardInfo(
    id: 'double_rent',
    name: 'Double Rent',
    description: 'Next rent you pay is doubled (auto-used)',
    icon: Icons.trending_up,
  ),
  'skip_turn': _CardInfo(
    id: 'skip_turn',
    name: 'Skip Turn',
    description: 'Skip your next turn',
    icon: Icons.skip_next,
  ),
};

/// Dialog showing the player's owned cards with the option to use them.
class CardInventoryDialog extends StatelessWidget {
  final List<String> ownedCardIds;
  final Future<void> Function(String cardId) onUse;

  const CardInventoryDialog({
    super.key,
    required this.ownedCardIds,
    required this.onUse,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('🎒 Card Inventory'),
      content: SizedBox(
        width: double.maxFinite,
        child: ownedCardIds.isEmpty
            ? const Text('You have no cards.')
            : ListView(
                shrinkWrap: true,
                children: ownedCardIds
                    .map((id) => _buildCardTile(context, id))
                    .toList(),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildCardTile(BuildContext context, String cardId) {
    final info = _kCardInfo[cardId];
    if (info == null) {
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          title: Text(cardId),
          subtitle: const Text('Unknown card'),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(info.icon, color: Theme.of(context).colorScheme.primary),
        title: Text(info.name),
        subtitle: Text(info.description),
        trailing: FilledButton.tonal(
          onPressed: () {
            onUse(cardId);
            Navigator.of(context).pop();
          },
          child: const Text('Use'),
        ),
      ),
    );
  }
}
