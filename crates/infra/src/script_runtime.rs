use std::path::Path;
use std::fs;

use crate::scripting::ScriptEngineKind;
use sa_monopoly_application::event_bus::{PreEventHook, PreEventAction, SubscriberPriority};
use sa_monopoly_domain::GameState;

/// A ScriptPreHook wraps a ScriptEngine and implements PreEventHook,
/// allowing Lua scripts to intercept commands before execution.
///
/// The script must define a global `on_pre_command(command_type, payload_json)`
/// function that returns a JSON string.
///
/// # Safety
/// `ScriptEngine` contains `mlua::Lua` which uses `Rc` internally and is
/// not `Send + Sync`. The caller must ensure that `ScriptPreHook` is only
/// used within a single-threaded context (which holds for the current FFI
/// architecture where each `execute_json` call creates a fresh `EventBus`).
pub struct ScriptPreHook {
    pub id: String,
    pub engine: ScriptEngine,
}

// SAFETY: ScriptPreHook is used in a single-threaded FFI context where
// each execute_json call creates a fresh EventBus.
unsafe impl Send for ScriptPreHook {}
unsafe impl Sync for ScriptPreHook {}

impl ScriptPreHook {
    pub fn new(id: &str, engine: ScriptEngine) -> Self {
        Self { id: id.to_string(), engine }
    }
}

impl PreEventHook for ScriptPreHook {
    fn id(&self) -> &str {
        &self.id
    }

    fn priority(&self) -> SubscriberPriority {
        SubscriberPriority::Normal
    }

    fn on_pre_command(
        &mut self,
        command_type: &str,
        payload: &serde_json::Value,
        _state: &GameState,
    ) -> PreEventAction {
        let script = format!(
            "return on_pre_command('{}', '{}')",
            command_type.replace('\'', "\\'"),
            payload.to_string().replace('\'', "\\'"),
        );

        let result = match &mut self.engine {
            ScriptEngine::Lua(lua) => {
                let result: Result<String, _> = lua.load(&script).eval();
                result.map_err(|e| format!("Lua error: {e}"))
            }
            ScriptEngine::JavaScript(_ctx) => {
                Err("JS pre-hook not yet supported".to_string())
            }
        };

        match result {
            Ok(json_str) => {
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(&json_str) {
                    match val["action"].as_str() {
                        Some("cancel") => {
                            let reason = val["reason"].as_str().unwrap_or("script_cancelled");
                            PreEventAction::Cancel(reason.to_string())
                        }
                        Some("modify") => {
                            if let Some(modified) = val.get("payload").cloned() {
                                PreEventAction::Modify(modified)
                            } else {
                                PreEventAction::Continue
                            }
                        }
                        _ => PreEventAction::Continue,
                    }
                } else {
                    PreEventAction::Continue
                }
            }
            Err(e) => {
                log::warn!("[ScriptPreHook:{}] Script error: {}", self.id, e);
                PreEventAction::Continue
            }
        }
    }
}

// ---------------------------------------------------------------------------
// ScriptEngine – Lua / JavaScript runtime wrapper
// ---------------------------------------------------------------------------

/// A real scripting engine that can execute Lua 5.4 or JavaScript source code.
///
/// Each variant holds its own engine instance:
/// - [`Lua`](ScriptEngine::Lua) wraps an [`mlua::Lua`] state
/// - [`JavaScript`](ScriptEngine::JavaScript) wraps a [`boa_engine::Context`]
#[derive(Debug)]
pub enum ScriptEngine {
    /// Lua 5.4 engine backed by `mlua`.
    Lua(mlua::Lua),
    /// JavaScript engine backed by `boa_engine`.
    JavaScript(boa_engine::Context),
}

impl ScriptEngine {
    /// Create a new script engine of the given kind.
    ///
    /// # Errors
    ///
    /// Returns an error string if the engine kind is not supported by this
    /// module (e.g. [`ScriptEngineKind::Wasm`] or [`ScriptEngineKind::Simple`]).
    pub fn new(kind: ScriptEngineKind) -> Result<Self, String> {
        match kind {
            ScriptEngineKind::Lua => {
                let lua = mlua::Lua::new();
                Ok(ScriptEngine::Lua(lua))
            }
            ScriptEngineKind::JavaScript => {
                let context = boa_engine::Context::default();
                Ok(ScriptEngine::JavaScript(context))
            }
            ScriptEngineKind::Wasm => {
                Err("WASM engine is not supported by ScriptEngine; use the wasm_runtime module instead".to_string())
            }
            ScriptEngineKind::Simple => {
                Err("Simple engine is not supported by ScriptEngine; use SimpleScriptHost instead".to_string())
            }
        }
    }

    /// Execute a script source string.
    ///
    /// # Errors
    ///
    /// Returns an error string if the script fails to compile or run.
    pub fn run(&mut self, source: &str) -> Result<(), String> {
        match self {
            ScriptEngine::Lua(lua) => {
                lua.load(source)
                    .exec()
                    .map_err(|e| format!("Lua execution error: {}", e))
            }
            ScriptEngine::JavaScript(context) => {
                let source = boa_engine::Source::from_bytes(source.as_bytes());
                context
                    .eval(source)
                    .map_err(|e| format!("JavaScript execution error: {}", e))?;
                Ok(())
            }
        }
    }

    /// Load and execute a script from a file.
    ///
    /// # Errors
    ///
    /// Returns an error string if the file cannot be read or the script fails
    /// to compile or run.
    pub fn run_file(&mut self, path: &Path) -> Result<(), String> {
        let source = fs::read_to_string(path)
            .map_err(|e| format!("Failed to read script file '{}': {}", path.display(), e))?;
        self.run(&source)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // ---- Lua tests ---------------------------------------------------------

    #[test]
    fn test_lua_new_and_run() {
        let mut engine = ScriptEngine::new(ScriptEngineKind::Lua).unwrap();
        engine.run("x = 1 + 2").unwrap();
    }

    #[test]
    fn test_lua_syntax_error() {
        let mut engine = ScriptEngine::new(ScriptEngineKind::Lua).unwrap();
        let result = engine.run("invalid lua syntax @@@");
        assert!(result.is_err());
    }

    // ---- JavaScript tests --------------------------------------------------

    #[test]
    fn test_js_new_and_run() {
        let mut engine = ScriptEngine::new(ScriptEngineKind::JavaScript).unwrap();
        engine.run("let x = 1 + 2;").unwrap();
    }

    #[test]
    fn test_js_syntax_error() {
        let mut engine = ScriptEngine::new(ScriptEngineKind::JavaScript).unwrap();
        let result = engine.run("invalid js syntax @@@");
        assert!(result.is_err());
    }

    // ---- Unsupported engine kinds ------------------------------------------

    #[test]
    fn test_wasm_kind_returns_error() {
        let result = ScriptEngine::new(ScriptEngineKind::Wasm);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("WASM"));
    }

    #[test]
    fn test_simple_kind_returns_error() {
        let result = ScriptEngine::new(ScriptEngineKind::Simple);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Simple"));
    }

    // ---- run_file tests ----------------------------------------------------

    #[test]
    fn test_run_file_nonexistent() {
        let mut engine = ScriptEngine::new(ScriptEngineKind::Lua).unwrap();
        let result = engine.run_file(Path::new("/nonexistent/script.lua"));
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Failed to read script file"));
    }

    // ========================================================================
    // Integration tests: ScriptPreHook with EventBus
    // ========================================================================

    use sa_monopoly_application::event_bus::EventBus;
    use sa_monopoly_application::builtin::commands::register_core_commands;
    use sa_monopoly_application::builtin::tiles::register_core_tile_behaviors;
    use sa_monopoly_domain::{GameState, RuleSetRef, Board, Player, tile::Tile, property::{Property, PropertyKind}};

    fn make_test_state() -> (EventBus, GameState) {
        let mut bus = EventBus::new();
        register_core_commands(&mut bus.command_handlers);
        register_core_tile_behaviors(&mut bus.tile_behaviors);
        let state = GameState {
            board: Board {
                tiles: vec![
                    Tile { id: "start".into(), name_key: "tile.start".into(), kind: "core:start".into(), linked_property_kind: None },
                    Tile { id: "prop_1".into(), name_key: "tile.prop_1".into(), kind: "core:ordinary_property".into(), linked_property_kind: Some(PropertyKind::Ordinary) },
                ],
                properties: vec![Property {
                    tile_id: "prop_1".into(), name_key: "prop.prop_1".into(), kind: PropertyKind::Ordinary,
                    base_price: 100, rent: vec![10], upgrade_level: 0,
                    owner: Some("player_2".into()), is_mortgaged: false, linked_targets: vec![],
                }],
                graph: Default::default(), auto_link_rent: false,
            },
            players: vec![
                Player { id: "player_1".into(), name: "Alice".into(), cash: 1000, position: "prop_1".into(), is_ai: false, is_llm_controlled: false, jail_turns: 0, hospital_turns: 0, owned_cards: vec![], stock_shares: 0, team_id: None },
                Player { id: "player_2".into(), name: "Bob".into(), cash: 500, position: "start".into(), is_ai: false, is_llm_controlled: false, jail_turns: 0, hospital_turns: 0, owned_cards: vec![], stock_shares: 0, team_id: None },
            ],
            ruleset: RuleSetRef { id: "test".into(), version: "0.1.0".into() },
            current_turn: 0, active_player_index: 0, seed: 42,
            decks: vec![], stock_market: None, active_auction: None,
            consecutive_doubles: 0, max_upgrade_level: 3, extension_upgrade_enabled: false,
            group_rent_enabled: false, lottery_state: None, bail_abuse_count: 0,
        };
        (bus, state)
    }

    /// 生产验证 1: Lua 插件通过 ScriptPreHook 取消租金
    #[test]
    fn test_lua_plugin_cancels_rent() {
        let (mut bus, mut state) = make_test_state();

        let mut engine = ScriptEngine::new(ScriptEngineKind::Lua).unwrap();
        let plugin_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent().unwrap().parent().unwrap()
            .join("examples/plugins/free_rent.lua");
        engine.run_file(&plugin_path).expect("Lua plugin should load");

        bus.register_pre_hook(Box::new(ScriptPreHook::new("test:lua_free_rent", engine)));

        let cash_before = state.players[0].cash;
        bus.execute_command(
            serde_json::from_value(serde_json::json!({"Custom":{"event_type":"core:command:pay_rent","source":"core","payload":{"player_id":"player_1","tile_id":"prop_1"},"timestamp":0}})).unwrap(),
            &mut state, &mut crate::rng::XorShift64::new(42),
        );

        assert_eq!(state.players[0].cash, cash_before, "Lua plugin should cancel rent on prop_1");
        log::info!("[TEST] ✅ Lua plugin 'free_rent.lua' cancelled rent successfully");
    }

    /// 生产验证 2: Lua 插件不影响其他命令
    #[test]
    fn test_lua_plugin_does_not_block_roll() {
        let (mut bus, mut state) = make_test_state();

        let mut engine = ScriptEngine::new(ScriptEngineKind::Lua).unwrap();
        let plugin_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent().unwrap().parent().unwrap()
            .join("examples/plugins/free_rent.lua");
        engine.run_file(&plugin_path).expect("Lua plugin should load");

        bus.register_pre_hook(Box::new(ScriptPreHook::new("test:lua_roll_check", engine)));

        // 验证: roll 命令没有被 Lua 插件拒绝（events 中不应有 command_rejected）
        let events_before = bus.drain_custom_events().len();
        bus.execute_command(
            serde_json::from_value(serde_json::json!({"Custom":{"event_type":"core:command:roll","source":"core","payload":{"player_id":"player_1"},"timestamp":0}})).unwrap(),
            &mut state, &mut crate::rng::XorShift64::new(5),
        );
        let events = bus.drain_custom_events();
        let has_rejected = events.iter().any(|e| e.event_type == "core:command_rejected");
        assert!(!has_rejected, "Roll should not be rejected by Lua plugin");
        log::info!("[TEST] ✅ Lua plugin does not block unrelated commands (no rejection)");
    }
}
