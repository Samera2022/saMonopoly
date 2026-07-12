import 'package:flutter/material.dart';

import 'game_constants.dart';

/// Dialog shown when a player lands on a Lottery tile.
/// Shows the current jackpot, ticket price, and a grid of numbered buttons.
class LotteryPickerDialog extends StatelessWidget {
  final int jackpot;
  final int ticketPrice;
  final int nextDrawTurn;
  final bool alreadyPicked;
  final Future<void> Function(int number) onPick;

  const LotteryPickerDialog({
    super.key,
    required this.jackpot,
    required this.ticketPrice,
    required this.nextDrawTurn,
    required this.alreadyPicked,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('🎰 Lottery'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Jackpot display
            Card(
              color: Colors.amber.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    const Text(
                      'Jackpot',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.brown,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '\$$jackpot',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepOrange,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Info row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Text('Ticket: \$$ticketPrice',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('Draw: Turn $nextDrawTurn',
                    style: const TextStyle(color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 12),
            // Number grid (5 columns x 10 rows)
            if (alreadyPicked)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'You already picked a number this cycle!',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
              )
            else ...[
              Text(
                'Pick a number (1-${LotteryConstants.pickRange}):',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 10,
                  childAspectRatio: 1.0,
                  crossAxisSpacing: 2,
                  mainAxisSpacing: 2,
                ),
                itemCount: LotteryConstants.pickRange,
                itemBuilder: (context, index) {
                  final number = index + 1;
                  return SizedBox(
                    width: 28,
                    height: 28,
                    child: FilledButton.tonal(
                      onPressed: () {
                        onPick(number);
                        Navigator.of(context).pop();
                      },
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(28, 28),
                      ),
                      child: Text(
                        '$number',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
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
}

/// Dialog showing the result of a lottery draw.
class LotteryResultDialog extends StatelessWidget {
  final int winningNumber;
  final String? winnerId;
  final int prize;

  const LotteryResultDialog({
    super.key,
    required this.winningNumber,
    this.winnerId,
    required this.prize,
  });

  @override
  Widget build(BuildContext context) {
    final hasWinner = winnerId != null && prize > 0;
    return AlertDialog(
      title: Text(hasWinner ? '🎉 Lottery Winner!' : '🎲 No Winner'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Winning number: $winningNumber'),
          const SizedBox(height: 12),
          if (hasWinner) ...[
            const Icon(Icons.celebration, size: 48, color: Colors.amber),
            const SizedBox(height: 8),
            Text(
              '$winnerId wins \$$prize!',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.deepOrange,
              ),
            ),
          ] else ...[
            const Icon(Icons.sentiment_dissatisfied,
                size: 48, color: Colors.grey),
            const SizedBox(height: 8),
            Text(
              'Jackpot rolls over to \$$prize!',
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
