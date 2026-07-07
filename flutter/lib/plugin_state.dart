/// Plugin enable state — shared between UI and game engine.
///
/// When the Rust FFI engine is available, toggles are sent to
/// [`sa_engine_plugin_ctl`] so the backend PluginController is updated.
/// When FFI is unavailable, only local state is used (Dart simulation).
library;

import 'bridge_client.dart';

class PluginState {
  static final PluginState _instance = PluginState._();
  factory PluginState() => _instance;
  PluginState._();

  /// Optional reference to the Rust engine for real enable/disable.
  RustEngineBinding? _engine;

  /// Connect to a Rust engine instance.
  void attachEngine(RustEngineBinding engine) {
    _engine = engine;
  }

  final Map<String, bool> _enabled = {};

  bool isEnabled(String pluginId) => _enabled[pluginId] ?? true;

  void setEnabled(String pluginId, bool value) {
    _enabled[pluginId] = value;
    // Call Rust FFI if engine is available
    _engine?.pluginCtl(pluginId, value);
  }

  bool get diceStatsEnabled => isEnabled('dice_stats');
  bool get treasureHuntEnabled => isEnabled('treasure_hunt');
}
