/// Event dispatcher — processes all [BridgeResponse] events and drives UI actions.
///
/// Instead of main.dart checking only `response.event[0]` with ad-hoc if/else
/// chains, this class dispatches every event in `response.allEvents` to a
/// dedicated handler.  Each handler returns an optional log message.
///
/// ## Usage
/// ```dart
/// final result = EventDispatcher.dispatch(
///   response: response,
///   callbacks: EventCallbacks(
///     addLog: _addLog,
///     showCardShop: () => _showCardShopDialog(),
///     showLottery: () => _showLotteryPickerDialog(),
///     showChanceCard: () => _showChanceCardDialog(),
///     showAuction: (tid, bid) => _showAuctionDialog(tid, bid),
///     onRollEnd: (d1, d2, r, log) => _broadcastRollEnd(d1, d2, r, actionLog: log),
///     syncAction: (r, log) => _syncAfterAction(r, actionLog: log),
///   ),
/// );
/// // Apply final state
/// setState(() {
///   _currentState = response.state;
///   _gameState = _buildGameState(response.state, lastEvent: result.lastLog);
/// });
/// ```
library;

import 'bridge_client.dart';

/// Result of dispatching a full event list.
class DispatchResult {
  /// Log messages collected from all event handlers.
  final List<String> logs;

  /// The last log message (convenience for UI updates).
  String get lastLog => logs.isNotEmpty ? logs.last : '';

  /// Whether at least one event indicated a rejection / error.
  final bool hadError;

  /// Dice values extracted from the response (0 if not a roll).
  final int dice1;
  final int dice2;

  /// Whether this was a jail-related roll.
  final bool isJailRoll;

  const DispatchResult({
    this.logs = const [],
    this.hadError = false,
    this.dice1 = 0,
    this.dice2 = 0,
    this.isJailRoll = false,
  });
}

/// Callbacks that the game UI must provide for the dispatcher to trigger
/// dialogs, animations, and network sync.
class EventCallbacks {
  /// Append a message to the event log.
  final void Function(String message) addLog;

  /// Show the card shop dialog.
  final void Function()? showCardShop;

  /// Show the lottery picker dialog.
  final void Function()? showLottery;

  /// Show a chance / community chest card dialog.
  final void Function()? showChanceCard;

  /// Show the auction dialog for a given tile with a starting bid.
  final void Function(String tileId, int startingBid)? showAuction;

  /// Broadcast the final dice result to network peers after roll animation.
  final void Function(int dice1, int dice2, BridgeResponse response, String log)?
      onRollEnd;

  /// Sync state + action log to network peers.
  final void Function(BridgeResponse response, String log)? syncAction;

  const EventCallbacks({
    required this.addLog,
    this.showCardShop,
    this.showLottery,
    this.showChanceCard,
    this.showAuction,
    this.onRollEnd,
    this.syncAction,
  });
}

/// Central event dispatcher.
class EventDispatcher {
  /// Process all events in [response] and return a [DispatchResult].
  static DispatchResult dispatch({
    required BridgeResponse response,
    required EventCallbacks callbacks,
  }) {
    final logs = <String>[];
    bool hadError = false;
    int dice1 = 0, dice2 = 0;
    bool isJailRoll = false;

    for (final event in response.allEvents) {
      final type = event['event_type'] as String? ?? '';
      final log = _handle(type, event, callbacks);
      if (log != null) {
        logs.add(log);
        callbacks.addLog(log);
      }

      // Track error state
      if (type == 'core:command_rejected' || type == 'core:error') {
        hadError = true;
      }

      // Extract dice values for roll events
      if (type == 'core:dice_rolled') {
        dice1 = (event['dice1'] as num?)?.toInt() ?? 0;
        dice2 = (event['dice2'] as num?)?.toInt() ?? 0;
        isJailRoll = event['consecutive'] == null;
      }
      if (type == 'core:player_released_from_jail') {
        isJailRoll = true;
      }
    }

    return DispatchResult(
      logs: logs,
      hadError: hadError,
      dice1: dice1,
      dice2: dice2,
      isJailRoll: isJailRoll,
    );
  }

  /// Handle a single event.  Returns an optional log message.
  static String? _handle(
    String type,
    Map<String, dynamic> event,
    EventCallbacks cb,
  ) {
    switch (type) {
      // ── Roll / movement ────────────────────────────────────────────
      case 'core:dice_rolled':
        final d1 = (event['dice1'] as num?)?.toInt() ?? 0;
        final d2 = (event['dice2'] as num?)?.toInt() ?? 0;
        final consecutive = event['consecutive'];
        final jailSuffix = consecutive == null
            ? ' (jail — need 7)'
            : '';
        return 'Rolled $d1 + $d2 = ${d1 + d2}$jailSuffix';

      case 'core:player_moved':
        final pid = event['player_id'] as String? ?? '';
        final to = event['to_tile'] as String? ?? '';
        return '$pid moved to $to';

      case 'core:player_sent_to_jail':
        final turns = event['turns'] as int? ?? 3;
        return 'Sent to jail for $turns turns';

      case 'core:player_released_from_jail':
        return 'Released from jail!';

      case 'core:player_released_from_hospital':
        return 'Released from hospital!';

      // ── Property / economy ─────────────────────────────────────────
      case 'core:property_bought':
        final tid = event['tile_id'] as String? ?? '';
        return 'Bought $tid';

      case 'core:property_upgraded':
        final tid = event['tile_id'] as String? ?? '';
        return 'Upgraded $tid';

      case 'core:property_mortgaged':
        final tid = event['tile_id'] as String? ?? '';
        return 'Mortgaged $tid';

      case 'core:property_redeemed':
        final tid = event['tile_id'] as String? ?? '';
        return 'Redeemed $tid';

      case 'core:rent_paid':
        final amount = event['amount'] as int? ?? 0;
        return 'Paid rent: \$$amount';

      case 'core:bail_paid':
        return 'Bail paid';

      // ── Cards ──────────────────────────────────────────────────────
      case 'core:card_drawn':
        final cardId = event['card_id'] as String? ?? '';
        cb.showChanceCard?.call();
        return 'Drew card: $cardId';

      case 'core:card_bought':
        final cardId = event['card_id'] as String? ?? '';
        return 'Bought card: $cardId';

      case 'core:card_used':
        final cardId = event['card_id'] as String? ?? '';
        return 'Used card: $cardId';

      case 'core:card_consumed':
        final cardId = event['card_id'] as String? ?? '';
        return 'Card consumed: $cardId';

      case 'core:card_shop_landed':
        cb.showCardShop?.call();
        return 'Landed on Card Shop';

      // ── Lottery ────────────────────────────────────────────────────
      case 'core:lottery_landed':
        cb.showLottery?.call();
        return 'Landed on Lottery';

      case 'core:lottery_ticket_bought':
        final number = event['number'] as int? ?? 0;
        return 'Bought lottery ticket #$number';

      case 'core:lottery_draw_result':
        final winner = event['winner'] as String?;
        final prize = event['prize'] as int? ?? 0;
        if (winner != null) {
          return 'Lottery winner: $winner wins \$$prize!';
        }
        return 'Lottery draw — no winner, prize rolls over';

      // ── Turn / game flow ───────────────────────────────────────────
      case 'core:turn_advanced':
        final turn = event['turn'] as int? ?? 0;
        return 'Turn $turn';

      case 'core:game_won':
        final winnerId = event['winner_id'] as String? ?? '';
        return 'Game won by $winnerId!';

      case 'core:player_bankrupt':
        final pid = event['player_id'] as String? ?? '';
        return '$pid is bankrupt!';

      case 'core:player_eliminated':
        final pid = event['player_id'] as String? ?? '';
        return '$pid eliminated';

      // ── Auction / trade ────────────────────────────────────────────
      case 'core:auction_started':
        final tid = event['tile_id'] as String? ?? '';
        final bid = (event['starting_bid'] as num?)?.toInt() ?? 0;
        cb.showAuction?.call(tid, bid);
        return 'Auction started for $tid (starting bid: \$$bid)';

      case 'core:bid_placed':
        final pid = event['player_id'] as String? ?? '';
        final amount = event['amount'] as int? ?? 0;
        return '$pid bids \$$amount';

      case 'core:trade_proposed':
        return 'Trade proposed';

      // ── Tax / bonus ────────────────────────────────────────────────
      case 'core:income_tax_paid':
        return 'Income tax paid';

      case 'core:luxury_tax_paid':
        return 'Luxury tax paid';

      case 'core:free_parking_bonus':
        return 'Free parking bonus!';

      case 'core:bank_bonus':
        return 'Bank bonus!';

      // ── Extension / utilities ──────────────────────────────────────
      case 'core:extension_property_landed':
        return 'Landed on utility';

      // ── Landing on tile ────────────────────────────────────────────
      case 'core:landed_on_tile':
        final tid = event['tile_id'] as String? ?? '';
        return 'Landed on $tid';

      // ── Stock market ───────────────────────────────────────────────
      case 'core:shares_bought':
        final shares = event['shares'] as int? ?? 0;
        return 'Bought $shares shares';

      case 'core:shares_sold':
        final shares = event['shares'] as int? ?? 0;
        return 'Sold $shares shares';

      case 'core:stock_market_tick':
        return 'Stock market tick';

      // ── Config ─────────────────────────────────────────────────────
      case 'core:config_loaded':
        return 'Config loaded';

      case 'core:config_updated':
        return 'Config updated';

      // ── Command status ─────────────────────────────────────────────
      case 'core:command_accepted':
        return null; // Redundant — other events carry the info

      case 'core:command_rejected':
        final reason = event['reason'] as String? ?? 'unknown';
        return 'Rejected: $reason';

      case 'core:error':
        final reason = event['reason'] as String? ?? 'unknown';
        return 'Error: $reason';

      default:
        return null; // Unknown event → silently ignore
    }
  }
}
