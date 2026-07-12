/// Game rule constants, synced with the Rust domain crate.
///
/// These constants MUST match the corresponding values in:
/// - `crates/domain/src/tile.rs`      — tile type IDs
/// - `crates/domain/src/property.rs`  — rent / upgrade cost formulas
/// - `crates/domain/src/state.rs`     — BASE_JAIL_TURNS
/// - `crates/domain/src/lottery.rs`   — lottery constants
/// - `crates/application/src/builtin/commands.rs` — tax, bail, mortgage, etc.
///
/// When updating Rust constants, update these to match.
library;

import 'bridge_client.dart';

// ============================================================================
// Tile type IDs (must match crates/domain/src/tile.rs)
// ============================================================================
class TileTypes {
  static const String start = 'core:start';
  static const String ordinaryProperty = 'core:ordinary_property';
  static const String specialProperty = 'core:special_property';
  static const String extensionProperty = 'core:extension_property';
  static const String chance = 'core:chance';
  static const String cardShop = 'core:card_shop';
  static const String lottery = 'core:lottery';
  static const String bank = 'core:bank';
  static const String jail = 'core:jail';
  static const String hospital = 'core:hospital';
  static const String goToJail = 'core:go_to_jail';
}

/// Normalized PascalCase tile kind strings (stripped of `core:` prefix,
/// snake_case → PascalCase).
class TileKindNames {
  static const String start = 'Start';
  static const String ordinaryProperty = 'OrdinaryProperty';
  static const String specialProperty = 'SpecialProperty';
  static const String extensionProperty = 'ExtensionProperty';
  static const String chance = 'Chance';
  static const String cardShop = 'CardShop';
  static const String lottery = 'Lottery';
  static const String bank = 'Bank';
  static const String jail = 'Jail';
  static const String hospital = 'Hospital';
  static const String goToJail = 'Jail';
}

// ============================================================================
// Rent & upgrade formulas (must match crates/domain/src/property.rs)
// ============================================================================
class PropertyFormulas {
  /// Rent = base_price * (1 + upgrade_level) / 10
  static const int rentRatioNum = 1;
  static const int rentRatioDen = 10;

  /// Upgrade cost = base_price * (1 + upgrade_level) / 3
  static const int upgradeCostRatioNum = 1;
  static const int upgradeCostRatioDen = 3;

  /// Calculate rent for a property.
  static int rent(int basePrice, int upgradeLevel) {
    return basePrice * (rentRatioNum + upgradeLevel) ~/ rentRatioDen;
  }

  /// Calculate upgrade cost for a property.
  static int upgradeCost(int basePrice, int upgradeLevel) {
    return basePrice * (upgradeCostRatioNum + upgradeLevel) ~/ upgradeCostRatioDen;
  }
}

// ============================================================================
// Game state defaults (must match crates/domain/src/state.rs)
// ============================================================================
class GameDefaults {
  /// Default number of jail turns (GameState::BASE_JAIL_TURNS).
  static const int baseJailTurns = 3;

  /// Maximum property upgrade level.
  static const int maxUpgradeLevel = 3;
}

// ============================================================================
// Lottery constants (must match crates/domain/src/lottery.rs)
// ============================================================================
class LotteryConstants {
  /// Base jackpot (LotteryState::BASE_JACKPOT).
  static const int baseJackpot = 500;

  /// Jackpot increment per turn (LotteryState::JACKPOT_PER_TURN).
  static const int jackpotPerTurn = 10;

  /// Base ticket price (LotteryState::BASE_TICKET_PRICE).
  static const int baseTicketPrice = 50;

  /// Draw cycle length (every N turns).
  static const int drawCycle = 15;

  /// Number range for player picks (1..pickRange).
  static const int pickRange = 50;
}

// ============================================================================
// Built-in command constants (must match crates/application/src/builtin/commands.rs)
// ============================================================================
class CommandConstants {
  /// Passing-start bonus ($200).
  static const int passStartBonus = 200;

  /// Income Tax amount ($200).
  static const int incomeTax = 200;

  /// Luxury Tax amount ($100).
  static const int luxuryTax = 100;

  /// Free Parking bonus ($200).
  static const int freeParkingBonus = 200;

  /// Bail amount per jail turn ($50).
  static const int bailPerTurn = 50;

  /// Mortgage credit amount ($100).
  static const int mortgageAmount = 100;

  /// Redemption fee ($110).
  static const int redeemAmount = 110;

  /// Shares price multiplier (shares * 100).
  static const int sharesPriceMultiplier = 100;

  /// Starting cash per player ($1500).
  static const int startingCash = 1500;

  /// Max players default.
  static const int maxPlayers = 4;

  /// Hospital recovery turns default.
  static const int hospitalRecoveryTurns = 2;

  /// Card prices (engine-side validation).
  static const int cardPriceGetOutOfJail = 150;
  static const int cardPriceBonus200 = 100;
  static const int cardPriceDoubleRent = 200;
}

// ============================================================================
// Chance card constants (must match simulated values in builtin/tiles.rs)
// ============================================================================
class ChanceCardConstants {
  /// Advance to Go. Collect $200
  static const int advanceGo = 200;
  /// Bank error in your favor. Collect $200
  static const int bankError = 200;
  /// Doctor's fee. Pay $50
  static const int doctorFee = 50;
  /// Holiday fund matures. Collect $100
  static const int holidayFund = 100;
  /// Income tax refund. Collect $20
  static const int taxRefund = 20;
  /// Pay hospital fees of $100
  static const int hospitalFees = 100;
  /// Receive $25 consultancy fee
  static const int consultancyFee = 25;
  /// Street repairs: $40 per house
  static const int streetRepairs = 40;
  /// Crossword competition. Collect $100
  static const int crosswordPrize = 100;
}

// ============================================================================
// Property kind strings (must match Rust PropertyKind serialization)
// ============================================================================
class PropertyKindNames {
  static const String ordinary = 'Ordinary';
  static const String special = 'Special';
  static const String extension = 'Extension';
}

// ============================================================================
// Dynamic constants loader — reads from Rust engine via BridgeClient
// ============================================================================

/// Loads game constants from the Rust engine at startup.
///
/// All constants MUST be loaded from the Rust engine. If [load] has not been
/// called, or the engine returned null data, every accessor throws.
class GameConstants {
  static Map<String, dynamic>? _data;

  /// Load constants from the given [BridgeClient].
  ///
  /// Must be called once at startup after the bridge client is initialised.
  static void load(BridgeClient client) {
    _data = client.gameConstants;
    if (_data == null) {
      throw Exception('Failed to load game constants from Rust engine');
    }
  }

  static void _ensureLoaded() {
    if (_data == null) {
      throw Exception(
        'GameConstants not loaded. Call GameConstants.load() at startup.',
      );
    }
  }

  // ── Tile types ──────────────────────────────────────────────────────────
  static String get tileTypeStart {
    _ensureLoaded();
    return _data!['tile_types']!['start'] as String;
  }
  static String get tileTypeOrdinaryProperty {
    _ensureLoaded();
    return _data!['tile_types']!['ordinary_property'] as String;
  }
  static String get tileTypeSpecialProperty {
    _ensureLoaded();
    return _data!['tile_types']!['special_property'] as String;
  }
  static String get tileTypeExtensionProperty {
    _ensureLoaded();
    return _data!['tile_types']!['extension_property'] as String;
  }
  static String get tileTypeChance {
    _ensureLoaded();
    return _data!['tile_types']!['chance'] as String;
  }
  static String get tileTypeCardShop {
    _ensureLoaded();
    return _data!['tile_types']!['card_shop'] as String;
  }
  static String get tileTypeLottery {
    _ensureLoaded();
    return _data!['tile_types']!['lottery'] as String;
  }
  static String get tileTypeBank {
    _ensureLoaded();
    return _data!['tile_types']!['bank'] as String;
  }
  static String get tileTypeJail {
    _ensureLoaded();
    return _data!['tile_types']!['jail'] as String;
  }
  static String get tileTypeHospital {
    _ensureLoaded();
    return _data!['tile_types']!['hospital'] as String;
  }
  static String get tileTypeGoToJail {
    _ensureLoaded();
    return _data!['tile_types']!['go_to_jail'] as String;
  }

  // ── Rent formula ────────────────────────────────────────────────────────
  static int get rentRatioNum {
    _ensureLoaded();
    return (_data!['rent_formula']!['ratio_num'] as num).toInt();
  }
  static int get rentRatioDen {
    _ensureLoaded();
    return (_data!['rent_formula']!['ratio_den'] as num).toInt();
  }
  static int get upgradeCostRatioNum {
    _ensureLoaded();
    return (_data!['upgrade_cost_formula']!['ratio_num'] as num).toInt();
  }
  static int get upgradeCostRatioDen {
    _ensureLoaded();
    return (_data!['upgrade_cost_formula']!['ratio_den'] as num).toInt();
  }

  // ── Game defaults ───────────────────────────────────────────────────────
  static int get baseJailTurns {
    _ensureLoaded();
    return (_data!['game_defaults']!['base_jail_turns'] as num).toInt();
  }
  static int get maxUpgradeLevel {
    _ensureLoaded();
    return (_data!['game_defaults']!['max_upgrade_level'] as num).toInt();
  }
  static int get startingCash {
    _ensureLoaded();
    return (_data!['game_defaults']!['starting_cash'] as num).toInt();
  }
  static int get maxPlayers {
    _ensureLoaded();
    return (_data!['game_defaults']!['max_players'] as num).toInt();
  }
  static int get passStartBonus {
    _ensureLoaded();
    return (_data!['game_defaults']!['pass_start_bonus'] as num).toInt();
  }
  static int get hospitalRecoveryTurns {
    _ensureLoaded();
    return (_data!['game_defaults']!['hospital_recovery_turns'] as num).toInt();
  }

  // ── Command constants ───────────────────────────────────────────────────
  static int get incomeTax {
    _ensureLoaded();
    return (_data!['command_constants']!['income_tax'] as num).toInt();
  }
  static int get luxuryTax {
    _ensureLoaded();
    return (_data!['command_constants']!['luxury_tax'] as num).toInt();
  }
  static int get freeParkingBonus {
    _ensureLoaded();
    return (_data!['command_constants']!['free_parking_bonus'] as num).toInt();
  }
  static int get bailPerTurn {
    _ensureLoaded();
    return (_data!['command_constants']!['bail_per_turn'] as num).toInt();
  }
  static int get mortgageAmount {
    _ensureLoaded();
    return (_data!['command_constants']!['mortgage_amount'] as num).toInt();
  }
  static int get redeemAmount {
    _ensureLoaded();
    return (_data!['command_constants']!['redeem_amount'] as num).toInt();
  }
  static int get sharesPriceMultiplier {
    _ensureLoaded();
    return (_data!['command_constants']!['shares_price_multiplier'] as num).toInt();
  }
  static int get cardPriceGetOutOfJail {
    _ensureLoaded();
    return (_data!['command_constants']!['card_price_get_out_of_jail'] as num).toInt();
  }
  static int get cardPriceBonus200 {
    _ensureLoaded();
    return (_data!['command_constants']!['card_price_bonus_200'] as num).toInt();
  }
  static int get cardPriceDoubleRent {
    _ensureLoaded();
    return (_data!['command_constants']!['card_price_double_rent'] as num).toInt();
  }

  // ── Lottery constants ───────────────────────────────────────────────────
  static int get lotteryBaseJackpot {
    _ensureLoaded();
    return (_data!['lottery_constants']!['base_jackpot'] as num).toInt();
  }
  static int get lotteryJackpotPerTurn {
    _ensureLoaded();
    return (_data!['lottery_constants']!['jackpot_per_turn'] as num).toInt();
  }
  static int get lotteryBaseTicketPrice {
    _ensureLoaded();
    return (_data!['lottery_constants']!['base_ticket_price'] as num).toInt();
  }
  static int get lotteryDrawCycle {
    _ensureLoaded();
    return (_data!['lottery_constants']!['draw_cycle'] as num).toInt();
  }
  static int get lotteryPickRange {
    _ensureLoaded();
    return (_data!['lottery_constants']!['pick_range'] as num).toInt();
  }

  // ── Chance card constants ───────────────────────────────────────────────
  static int get chanceAdvanceGo {
    _ensureLoaded();
    return (_data!['chance_card_constants']!['advance_go'] as num).toInt();
  }
  static int get chanceBankError {
    _ensureLoaded();
    return (_data!['chance_card_constants']!['bank_error'] as num).toInt();
  }
  static int get chanceDoctorFee {
    _ensureLoaded();
    return (_data!['chance_card_constants']!['doctor_fee'] as num).toInt();
  }
  static int get chanceHolidayFund {
    _ensureLoaded();
    return (_data!['chance_card_constants']!['holiday_fund'] as num).toInt();
  }
  static int get chanceTaxRefund {
    _ensureLoaded();
    return (_data!['chance_card_constants']!['tax_refund'] as num).toInt();
  }
  static int get chanceHospitalFees {
    _ensureLoaded();
    return (_data!['chance_card_constants']!['hospital_fees'] as num).toInt();
  }
  static int get chanceConsultancyFee {
    _ensureLoaded();
    return (_data!['chance_card_constants']!['consultancy_fee'] as num).toInt();
  }
  static int get chanceStreetRepairs {
    _ensureLoaded();
    return (_data!['chance_card_constants']!['street_repairs'] as num).toInt();
  }
  static int get chanceCrosswordPrize {
    _ensureLoaded();
    return (_data!['chance_card_constants']!['crossword_prize'] as num).toInt();
  }

  // ── Property kind names ─────────────────────────────────────────────────
  static String get propertyKindOrdinary {
    _ensureLoaded();
    return _data!['property_kind_names']!['ordinary'] as String;
  }
  static String get propertyKindSpecial {
    _ensureLoaded();
    return _data!['property_kind_names']!['special'] as String;
  }
  static String get propertyKindExtension {
    _ensureLoaded();
    return _data!['property_kind_names']!['extension'] as String;
  }
}

// ============================================================================
// Tile kind normalization helpers
// ============================================================================

/// Strip "core:" prefix and convert snake_case to PascalCase.
///
/// Examples:
///   "core:ordinary_property" → "OrdinaryProperty"
///   "ordinary_property"      → "OrdinaryProperty"
String normalizeKind(String kind) {
  final stripped = kind.startsWith('core:') ? kind.substring(5) : kind;
  return stripped
      .split('_')
      .map((s) => s.isNotEmpty ? '${s[0].toUpperCase()}${s.substring(1)}' : '')
      .join();
}

/// Check whether [kind] (after normalization) represents an ownable property
/// tile (OrdinaryProperty / SpecialProperty / ExtensionProperty).
bool isOwnablePropertyKind(String kind) {
  final normalized = normalizeKind(kind);
  return normalized == TileKindNames.ordinaryProperty ||
         normalized == TileKindNames.specialProperty ||
         normalized == TileKindNames.extensionProperty;
}
