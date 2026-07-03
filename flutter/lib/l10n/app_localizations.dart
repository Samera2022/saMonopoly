import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

// ============================================================================
// AppLocalizations – simple JSON-based i18n for Flutter
//
// Usage:
//   final l10n = AppLocalizations.of(context);
//   print(l10n.translate('game.roll'));
//   print(l10n.translate('dialog.buyPropertyQuestion', {'price': '\$200'}));
// ============================================================================

class AppLocalizations {
  final Locale locale;
  final Map<String, String> _strings;

  AppLocalizations(this.locale, this._strings);

  /// Supported locales.
  static const List<Locale> supportedLocales = [
    Locale('en', ''),
    Locale('zh', ''),
  ];

  /// Fallback locale when the user's locale is not found.
  static const Locale fallbackLocale = Locale('en', '');

  /// Get the current [AppLocalizations] from the widget tree.
  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  /// Translate a key with optional positional parameters.
  ///
  /// Parameters are substituted using `{paramName}` syntax in the string.
  String translate(String key, [Map<String, String>? params]) {
    final raw = _strings[key];
    if (raw == null) {
      // Fallback: try English
      return _fallback(key, params);
    }

    if (params == null || params.isEmpty) {
      return raw;
    }

    var result = raw;
    params.forEach((k, v) {
      result = result.replaceAll('{$k}', v);
    });
    return result;
  }

  /// Shorthand for [translate].
  String call(String key, [Map<String, String>? params]) =>
      translate(key, params);

  /// Try to look up the key in the English fallback data.
  String _fallback(String key, Map<String, String>? params) {
    const fallbackData = <String, String>{
      'app.title': 'saMonopoly',
      'game.roll': 'Roll',
      'game.buy': 'Buy',
      'game.endTurn': 'End Turn',
      'game.trade': 'Trade',
      'game.cardShop': 'Card Shop',
      'game.settings': 'Settings',
      'game.startGame': 'Start Game',
      'game.cash': 'Cash',
      'game.players': 'Players',
      'game.playerName': 'Name',
      'game.cancel': 'Cancel',
      'game.confirm': 'Confirm',
      'game.skip': 'Skip',
      'game.bid': 'Bid',
      'game.close': 'Close',
      'game.buyCard': 'Buy Card',
      'log.gameStarted': 'Game started',
      'log.rolled': 'Rolled {dice1} + {dice2} = {total}',
      'log.turnEnded': 'Turn ended',
      'log.boughtProperty': 'Player bought {tile}',
      'log.noProperty': 'No property to buy here',
    };

    final raw = fallbackData[key];
    if (raw == null) return key; // Return the key itself as last resort

    if (params == null || params.isEmpty) return raw;
    var result = raw;
    params.forEach((k, v) {
      result = result.replaceAll('{$k}', v);
    });
    return result;
  }
}

// ============================================================================
// AppLocalizationsDelegate
// ============================================================================

class AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocalizations.supportedLocales.any((l) =>
        l.languageCode == locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    final strings = await _loadStrings(locale);
    return AppLocalizations(locale, strings);
  }

  @override
  bool shouldReload(covariant AppLocalizationsDelegate old) => false;

  /// Load strings from the asset bundle for the given locale.
  ///
  /// Falls back to English if the locale file is not available.
  Future<Map<String, String>> _loadStrings(Locale locale) async {
    final localeName = locale.languageCode;
    try {
      final data =
          await rootBundle.loadString('assets/i18n/$localeName.json');
      final decoded = jsonDecode(data) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      // Fallback to English
      try {
        final data = await rootBundle.loadString('assets/i18n/en.json');
        final decoded = jsonDecode(data) as Map<String, dynamic>;
        return decoded.map((k, v) => MapEntry(k, v as String));
      } catch (_) {
        return {};
      }
    }
  }
}
