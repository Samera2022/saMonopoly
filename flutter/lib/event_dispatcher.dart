/// Event dispatcher — processes all [BridgeResponse] events and drives UI actions.
///
/// Instead of main.dart checking only `response.event[0]` with ad-hoc if/else
/// chains, this class dispatches every event in `response.allEvents` to a
/// dedicated handler.  Each handler returns an optional log message.
///
/// ## Usage
/// ```dart
/// // Register a global subscriber
/// EventDispatcher.subscribe('core:card_shop_landed', EventSubscriber(
///   handler: (_) => _showCardShopDialog(),
///   isUiAction: true,  // deferrable UI action
/// ));
///
/// // Dispatch with deferred UI actions
/// final result = EventDispatcher.dispatch(
///   response: response,
///   deferUiActions: true,
/// );
///
/// // Apply final state + execute deferred UI actions
/// setState(() {
///   _currentState = response.state;
///   _gameState = _buildGameState(response.state, lastEvent: result.lastLog);
/// });
/// for (final action in result.pendingUiActions) {
///   action.execute();
/// }
/// ```
library;

import 'package:flutter/foundation.dart';

import 'game_constants.dart';
import 'bridge_client.dart';

/// Subscriber for a specific event type.
///
/// Use [EventDispatcher.subscribe] to register this subscriber for a given
/// event type.  When [isUiAction] is `true` and the dispatch mode has
/// [deferUiActions] enabled, the action is deferred into
/// [DispatchResult.pendingUiActions] instead of being executed immediately.
class EventSubscriber {
  /// The event handler function.
  final void Function(Map<String, dynamic> event) handler;

  /// Whether this subscriber triggers a UI action (e.g., a dialog).
  /// When `true` and the dispatch uses `deferUiActions: true`, the action
  /// is collected into [DispatchResult.pendingUiActions] rather than invoked
  /// inline.
  final bool isUiAction;

  const EventSubscriber({
    required this.handler,
    this.isUiAction = false,
  });
}

/// A deferred UI action that can be executed later.
///
/// Produced by [EventDispatcher.dispatch] when `deferUiActions` is `true`
/// and a matching subscriber has [EventSubscriber.isUiAction] set to `true`.
class UiAction {
  /// The subscriber that produced this action.
  final EventSubscriber subscriber;

  /// The event data that triggered this action.
  final Map<String, dynamic> event;

  const UiAction({
    required this.subscriber,
    required this.event,
  });

  /// Execute the subscriber's handler with the event.
  void execute() => subscriber.handler(event);
}

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

  /// Pending UI actions deferred by [deferUiActions] mode.
  ///
  /// When [EventDispatcher.dispatch] is called with `deferUiActions: true`,
  /// subscribers that have [EventSubscriber.isUiAction] set to `true` are
  /// collected here instead of being executed immediately.
  final List<UiAction> pendingUiActions;

  const DispatchResult({
    this.logs = const [],
    this.hadError = false,
    this.dice1 = 0,
    this.dice2 = 0,
    this.isJailRoll = false,
    this.pendingUiActions = const [],
  });
}

/// Central event dispatcher.
///
/// Provides a subscriber-based API with deferred UI action support.
class EventDispatcher {
  // ═══════════════════════════════════════════════════════════════════════════
  // Static subscription registry
  // ═══════════════════════════════════════════════════════════════════════════

  static final Map<String, List<EventSubscriber>> _subscribers = {};

  /// Register a [subscriber] for the given [eventType].
  ///
  /// All future [dispatch] calls that process an event matching [eventType]
  /// will invoke this subscriber's handler.
  static void subscribe(String eventType, EventSubscriber subscriber) {
    _subscribers.putIfAbsent(eventType, () => []);
    _subscribers[eventType]!.add(subscriber);
  }

  /// Unregister a [subscriber] from the given [eventType].
  ///
  /// If the subscriber was not registered, this is a no-op.
  static void unsubscribe(String eventType, EventSubscriber subscriber) {
    final list = _subscribers[eventType];
    if (list == null) return;
    list.remove(subscriber);
    if (list.isEmpty) {
      _subscribers.remove(eventType);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Dispatch
  // ═══════════════════════════════════════════════════════════════════════════

  /// Process all events in [response] and return a [DispatchResult].
  ///
  /// ## Parameters
  ///
  /// * [response] — the bridge response containing events and state.
  /// * [deferUiActions] — when `true`, subscribers with
  ///   [EventSubscriber.isUiAction] set to `true` are collected into
  ///   [DispatchResult.pendingUiActions] instead of being invoked
  ///   immediately.  Non-UI-action subscribers (`isUiAction == false`) are
  ///   always invoked immediately regardless of this flag.
  static DispatchResult dispatch({
    required BridgeResponse response,
    bool deferUiActions = false,
  }) {
    final logs = <String>[];
    bool hadError = false;
    int dice1 = 0, dice2 = 0;
    bool isJailRoll = false;
    final pendingActions = <UiAction>[];

    for (final event in response.allEvents) {
      final type = event['event_type'] as String? ?? '';

      // ── Log handling ──────────────────────────────────────────────
      final log = _handleLog(type, event);
      if (log != null) {
        logs.add(log);
      }

      // ── Subscriber dispatch ────────────────────────────────────────
      final subscribers = _subscribers[type];
      if (subscribers != null) {
        for (final subscriber in subscribers) {
          if (deferUiActions && subscriber.isUiAction) {
            // Defer: collect into pendingUiActions for later execution
            pendingActions.add(UiAction(
              subscriber: subscriber,
              event: event,
            ));
          } else {
            // Execute immediately
            subscriber.handler(event);
          }
        }
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
      pendingUiActions: pendingActions,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal: log message generator
  // ═══════════════════════════════════════════════════════════════════════════

  /// Generate a log message for a single event.
  ///
  /// Returns a human-readable log string, or `null` if the event should
  /// produce no log output.
  static String? _handleLog(
    String type,
    Map<String, dynamic> event,
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
        final turns = event['turns'] as int? ?? GameDefaults.baseJailTurns;
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

      // ── Cards / property ──────────────────────────────────────────
      case 'core:card_drawn':
        final cardId = event['card_id'] as String? ?? '';
        debugPrint('[TRACE] Flutter received core:card_drawn event: card_id=$cardId');
        return 'Drew card: $cardId';

      case 'core:property_bought_event':
        final pid = event['player_id'] as String? ?? '';
        final prop = event['property'] as Map<String, dynamic>?;
        final tid = prop?['tile_id'] as String? ?? '';
        return '$pid bought $tid';

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
        return 'Landed on Card Shop';

      // ── Lottery ────────────────────────────────────────────────────
      case 'core:lottery_landed':
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

      case 'core:player_turn_started':
        final pid = event['player_id'] as String? ?? '';
        return 'Turn: $pid';

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
        return 'Auction started for $tid (starting bid: \$$bid)';

      case 'core:bid_placed':
        final pid = event['player_id'] as String? ?? '';
        final amount = event['amount'] as int? ?? 0;
        return '$pid bids \$$amount';

      case 'core:trade_proposed':
        return 'Trade proposed';

      // ── Tax / bonus ────────────────────────────────────────────────
      case 'core:income_tax_paid':
        final amount = event['amount'] as int? ?? 0;
        return 'Income tax paid: \$$amount';

      case 'core:luxury_tax_paid':
        final amount = event['amount'] as int? ?? 0;
        return 'Luxury tax paid: \$$amount';

      case 'core:free_parking_bonus':
        final amount = event['amount'] as int? ?? 0;
        return 'Free parking bonus: \$$amount';

      case 'core:bank_bonus':
        final amount = event['amount'] as int? ?? 0;
        return 'Bank bonus: \$$amount';

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

/// Property data snapshot matching Rust's PropertyData
class PropertyData {
  final String tileId;
  final String kind;
  final int basePrice;
  final String? owner;
  final int upgradeLevel;
  final List<String> linkedTargets;

  PropertyData({
    required this.tileId,
    required this.kind,
    required this.basePrice,
    this.owner,
    required this.upgradeLevel,
    required this.linkedTargets,
  });

  factory PropertyData.fromJson(Map<String, dynamic> json) {
    return PropertyData(
      tileId: json['tile_id'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
      basePrice: (json['base_price'] as num?)?.toInt() ?? 0,
      owner: json['owner'] as String?,
      upgradeLevel: (json['upgrade_level'] as num?)?.toInt() ?? 0,
      linkedTargets: (json['linked_targets'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }
}

/// Card data snapshot matching Rust's CardData
class CardData {
  final String id;
  final String nameKey;
  final String effectKey;

  CardData({required this.id, required this.nameKey, required this.effectKey});

  factory CardData.fromJson(Map<String, dynamic> json) {
    return CardData(
      id: json['id'] as String? ?? '',
      nameKey: json['name_key'] as String? ?? '',
      effectKey: json['effect_key'] as String? ?? '',
    );
  }
}

/// Dice result matching Rust's DiceResult
class DiceResult {
  final int dice1;
  final int dice2;
  final bool isSeven;
  final int consecutive;

  DiceResult({
    required this.dice1,
    required this.dice2,
    required this.isSeven,
    required this.consecutive,
  });
}
