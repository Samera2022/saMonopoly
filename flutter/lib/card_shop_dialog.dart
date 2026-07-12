import 'package:flutter/material.dart';

import 'game_constants.dart';

/// Card shop data for a purchasable card.
class CardShopItem {
  final String id;
  final String name;
  final String description;
  final int price;

  const CardShopItem({
    required this.id,
    required this.name,
    required this.description,
    required this.price,
  });
}

/// Predefined cards available at the card shop.
///
/// Prices MUST match the server-side constants in [CommandConstants].
/// The engine rejects any purchase with a mismatched price.
/// `skip_turn` is excluded because its effect (skip own turn) is strictly
/// detrimental; it may be re-added with a reworked effect in the future.
const List<CardShopItem> kCardShopItems = [
  CardShopItem(
    id: 'get_out_of_jail',
    name: 'Get Out of Jail',
    description: 'Exit jail immediately',
    price: CommandConstants.cardPriceGetOutOfJail,
  ),
  CardShopItem(
    id: 'bonus_200',
    name: 'Bonus \$200',
    description: 'Receive \$200 cash',
    price: CommandConstants.cardPriceBonus200,
  ),
  CardShopItem(
    id: 'double_rent',
    name: 'Double Rent',
    description: 'Next rent payment is doubled',
    price: CommandConstants.cardPriceDoubleRent,
  ),
];

/// Dialog shown when a player lands on a Card Shop tile.
/// Lets the player browse and purchase cards.
class CardShopDialog extends StatefulWidget {
  final int playerCash;
  final Future<void> Function(String cardId, int price) onBuy;

  const CardShopDialog({
    super.key,
    required this.playerCash,
    required this.onBuy,
  });

  @override
  State<CardShopDialog> createState() => _CardShopDialogState();
}

class _CardShopDialogState extends State<CardShopDialog> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Card Shop'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: kCardShopItems
              .map((item) => Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: Icon(
                        _iconFor(item.id),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(item.name),
                      subtitle: Text(item.description),
                      trailing: FilledButton.tonal(
                        onPressed: widget.playerCash >= item.price
                            ? () {
                                widget.onBuy(item.id, item.price);
                                Navigator.of(context).pop();
                              }
                            : null,
                        child: Text('\$${item.price}'),
                      ),
                    ),
                  ))
              .toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Leave'),
        ),
      ],
    );
  }

  IconData _iconFor(String id) {
    switch (id) {
      case 'get_out_of_jail':
        return Icons.lock_open;
      case 'bonus_200':
        return Icons.monetization_on;
      case 'double_rent':
        return Icons.trending_up;
      case 'skip_turn':
        return Icons.skip_next;
      default:
        return Icons.card_giftcard;
    }
  }
}
