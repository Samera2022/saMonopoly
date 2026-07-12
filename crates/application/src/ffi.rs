use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::{Path, PathBuf};

use crate::bridge::{BridgeRequest, EngineBridge};
use crate::event_bus::EventBus;
use crate::map_loader;

pub struct NativeBridge;

impl NativeBridge {
    pub fn execute_json(input: &str) -> Result<String, String> {
        EngineBridge::execute_json(input)
    }

    pub fn execute_request(request: BridgeRequest) -> String {
        let mut bus = EventBus::new();
        let response = EngineBridge::execute(request, &mut bus);
        serde_json::to_string_pretty(&response)
            .unwrap_or_else(|err| format!(r#"{{"error":"{}"}}"#, err))
    }
}

// ─── C FFI exports for Flutter dart:ffi ──────────────────────────────────────

/// Return a JSON string containing all game constants.
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// Returns a valid null-terminated C string that must be freed.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_get_constants() -> *mut c_char {
    let constants = serde_json::json!({
        // Tile type IDs (from crates/domain/src/tile.rs)
        "tile_types": {
            "start": "core:start",
            "ordinary_property": "core:ordinary_property",
            "special_property": "core:special_property",
            "extension_property": "core:extension_property",
            "chance": "core:chance",
            "card_shop": "core:card_shop",
            "lottery": "core:lottery",
            "bank": "core:bank",
            "jail": "core:jail",
            "hospital": "core:hospital",
            "go_to_jail": "core:go_to_jail",
        },
        // Rent formula (from crates/domain/src/property.rs)
        "rent_formula": {
            "ratio_num": 1,
            "ratio_den": 10,
        },
        "upgrade_cost_formula": {
            "ratio_num": 1,
            "ratio_den": 3,
        },
        // Game defaults (from crates/domain/src/state.rs + crates/domain/src/config.rs)
        "game_defaults": {
            "base_jail_turns": 3,
            "max_upgrade_level": 3,
            "starting_cash": 1500,
            "max_players": 4,
            "pass_start_bonus": 200,
            "hospital_recovery_turns": 2,
        },
        // Command constants (matching crates/application/src/builtin/commands.rs)
        "command_constants": {
            "income_tax": 200,
            "luxury_tax": 100,
            "free_parking_bonus": 200,
            "bail_per_turn": 50,
            "mortgage_amount": 100,
            "redeem_amount": 110,
            "shares_price_multiplier": 100,
            "card_price_get_out_of_jail": 150,
            "card_price_bonus_200": 100,
            "card_price_double_rent": 200,
        },
        // Lottery constants (from crates/domain/src/lottery.rs)
        "lottery_constants": {
            "base_jackpot": 500,
            "jackpot_per_turn": 10,
            "base_ticket_price": 50,
            "draw_cycle": 15,
            "pick_range": 50,
        },
        // Chance card constants (matching crates/domain/src/card.rs + builtin/tiles.rs)
        "chance_card_constants": {
            "advance_go": 200,
            "bank_error": 200,
            "doctor_fee": 50,
            "holiday_fund": 100,
            "tax_refund": 20,
            "hospital_fees": 100,
            "consultancy_fee": 25,
            "street_repairs": 40,
            "crossword_prize": 100
        },
        // Property kind names (matching crates/domain/src/property.rs PropertyKind serialization)
        "property_kind_names": {
            "ordinary": "Ordinary",
            "special": "Special",
            "extension": "Extension"
        },
    });
    let json_str = serde_json::to_string(&constants).unwrap_or_default();
    let c_str = std::ffi::CString::new(json_str).unwrap_or_default();
    c_str.into_raw()
}

/// Free a string previously returned by `sa_engine_execute`.
/// Must be called from the same allocator (Rust's default allocator).
///
/// # Safety
/// `ptr` must be a valid pointer returned by `sa_engine_execute`.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

/// Execute a game command JSON string against the Rust engine.
///
/// Takes a JSON string matching `BridgeRequest` format and returns
/// a JSON string matching `BridgeResponse` format.
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// `input` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_execute(input: *const c_char) -> *mut c_char {
    let input_str = unsafe {
        if input.is_null() {
            return CString::new(r#"{"error":"null input}"#)
                .unwrap()
                .into_raw();
        }
        match CStr::from_ptr(input).to_str() {
            Ok(s) => s,
            Err(_) => {
                return CString::new(r#"{"error":"invalid utf-8"}"#)
                    .unwrap()
                    .into_raw();
            }
        }
    };

    let result = EngineBridge::execute_json(input_str);
    let output = match result {
        Ok(json) => json,
        Err(err) => format!(r#"{{"error":"{}"}}"#, err),
    };

    CString::new(output).unwrap_or_default().into_raw()
}

// ─── Map loading FFI exports ────────────────────────────────────────────────

/// Helper to create an error JSON response.
fn error_json(msg: &str) -> *mut c_char {
    let json = serde_json::json!({"ok": false, "error": msg});
    CString::new(serde_json::to_string(&json).unwrap_or_default())
        .unwrap_or_default()
        .into_raw()
}

/// Load a map from a file path (.smap or .json).
/// Returns JSON of MapDefinition, or an error object `{"ok": false, "error": "..."}`.
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// `path` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_load_map(path: *const c_char) -> *mut c_char {
    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid path: {e}")),
    };

    let result = map_loader::load_map_from_path(Path::new(path_str));
    match result {
        Ok(definition) => {
            let json_str = serde_json::to_string(&definition).unwrap_or_default();
            CString::new(json_str).unwrap_or_default().into_raw()
        }
        Err(e) => error_json(&e),
    }
}

/// Scan a directory for map files (.smap and .json).
/// Returns a JSON array of `{"id": "...", "path": "...", "format": "..."}`.
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// `path` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_scan_maps(path: *const c_char) -> *mut c_char {
    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid path: {e}")),
    };

    let maps = map_loader::scan_maps_in_dir(Path::new(path_str));
    let json_str = serde_json::to_string(&maps).unwrap_or_else(|_| "[]".to_string());
    CString::new(json_str).unwrap_or_default().into_raw()
}

/// Load a .smap file and extract its thumbnail (PNG bytes as base64).
/// Returns JSON: `{"ok": true, "thumbnail": "<base64>", "mime": "image/png"}`.
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// `path` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_get_thumbnail(path: *const c_char) -> *mut c_char {
    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid path: {e}")),
    };

    match map_loader::load_thumbnail(Path::new(path_str)) {
        Ok(png_bytes) => {
            use base64::Engine;
            let base64_str =
                base64::engine::general_purpose::STANDARD.encode(&png_bytes);
            let json = serde_json::json!({
                "ok": true,
                "thumbnail": base64_str,
                "mime": "image/png"
            });
            CString::new(serde_json::to_string(&json).unwrap_or_default())
                .unwrap_or_default()
                .into_raw()
        }
        Err(e) => error_json(&e),
    }
}

// ─── Session sync FFI exports ──────────────────────────────────────────────

use sa_monopoly_domain::GameState;

/// Compute a state diff for network sync.
/// Input: JSON `{"before": GameState, "after": GameState}`
/// Returns: JSON diff
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// `input` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_sync_diff(input: *const c_char) -> *mut c_char {
    let input_str = match unsafe { CStr::from_ptr(input) }.to_str() {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid input: {e}")),
    };
    let parsed: serde_json::Value = match serde_json::from_str(input_str) {
        Ok(v) => v,
        Err(e) => return error_json(&format!("Invalid JSON: {e}")),
    };
    let before: GameState = match serde_json::from_value(parsed["before"].clone()) {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid before state: {e}")),
    };
    let after: GameState = match serde_json::from_value(parsed["after"].clone()) {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid after state: {e}")),
    };
    let diff = crate::session_sync::SessionSync::compute_diff(&before, &after);
    CString::new(serde_json::to_string(&diff).unwrap_or_default())
        .unwrap_or_default()
        .into_raw()
}

/// Apply a diff to a GameState.
/// Input: JSON `{"state": GameState, "diff": {...}}`
/// Returns: JSON of the patched GameState
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// `input` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_sync_apply(input: *const c_char) -> *mut c_char {
    let input_str = match unsafe { CStr::from_ptr(input) }.to_str() {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid input: {e}")),
    };
    let parsed: serde_json::Value = match serde_json::from_str(input_str) {
        Ok(v) => v,
        Err(e) => return error_json(&format!("Invalid JSON: {e}")),
    };
    let state: GameState = match serde_json::from_value(parsed["state"].clone()) {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid state: {e}")),
    };
    let result = crate::session_sync::SessionSync::apply_diff(&state, &parsed["diff"]);
    CString::new(serde_json::to_string(&result).unwrap_or_default())
        .unwrap_or_default()
        .into_raw()
}

/// Check for revision conflict.
/// Input: JSON `{"local_rev": u64, "remote_rev": u64}`
/// Returns: `{"conflict": true/false}`
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// `input` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_sync_conflict(input: *const c_char) -> *mut c_char {
    let input_str = match unsafe { CStr::from_ptr(input) }.to_str() {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid input: {e}")),
    };
    let parsed: serde_json::Value = match serde_json::from_str(input_str) {
        Ok(v) => v,
        Err(e) => return error_json(&format!("Invalid JSON: {e}")),
    };
    let local_rev = parsed["local_rev"].as_u64().unwrap_or(0);
    let remote_rev = parsed["remote_rev"].as_u64().unwrap_or(0);
    let conflict = crate::session_sync::SessionSync::detect_conflict(local_rev, remote_rev);
    CString::new(serde_json::json!({"conflict": conflict}).to_string())
        .unwrap_or_default()
        .into_raw()
}

// ─── Config FFI exports ────────────────────────────────────────────────────

use sa_monopoly_domain::config::{ConfigDocument, CURRENT_CONFIG_VERSION};

/// Small helper returning `{"ok": true}`.
fn ok_json() -> *mut c_char {
    CString::new(r#"{"ok":true}"#).unwrap_or_default().into_raw()
}

/// Get a standard config directory using XDG or HOME fallback.
fn get_config_dir() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let home =
                std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
            Path::new(&home).join(".config")
        });
    base.join("sa_monopoly")
}

/// Path to the versioned config save file (matching infra's FileConfigStore
/// format: `{config_dir}/config.sav` containing a VersionedSave envelope).
fn config_sav_path() -> PathBuf {
    get_config_dir().join("config.sav")
}

/// Read the config save file and return the inner ConfigDocument JSON string.
///
/// The persisted format is a `VersionedSave` envelope:
/// ```json
/// { "version": <u32>, "data": "<escaped ConfigDocument JSON>" }
/// ```
/// If the file does not exist or cannot be read, the default ConfigDocument is
/// returned — the system never crashes due to a missing/corrupt config file.
fn load_config_from_disk() -> Result<String, String> {
    let path = config_sav_path();
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            // No persisted config yet — return defaults.
            let doc = ConfigDocument::current();
            return serde_json::to_string(&doc)
                .map_err(|e| format!("Serialize default config: {e}"));
        }
        Err(e) => return Err(format!("Read config file: {e}")),
    };

    // Parse the VersionedSave envelope.
    let envelope: serde_json::Value =
        serde_json::from_str(&content).map_err(|e| format!("Parse envelope: {e}"))?;

    // Extract the inner data string (raw JSON of ConfigDocument).
    let data_str = envelope["data"]
        .as_str()
        .ok_or_else(|| "Missing 'data' field in config envelope".to_string())?;

    // Parse the data string as ConfigDocument (validates structure).
    let doc: ConfigDocument =
        serde_json::from_str(data_str).map_err(|e| format!("Parse config document: {e}"))?;

    serde_json::to_string(&doc).map_err(|e| format!("Serialize config: {e}"))
}

/// Write a ConfigDocument JSON string to the versioned config save file.
///
/// Wraps it in the VersionedSave envelope expected by infra's FileConfigStore.
fn save_config_to_disk(config_json: &str) -> Result<(), String> {
    let path = config_sav_path();

    // Create parent directory if needed.
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Create config dir: {e}"))?;
    }

    // Build the VersionedSave envelope.
    let envelope = serde_json::json!({
        "version": CURRENT_CONFIG_VERSION,
        "data": config_json,
    });

    let content = serde_json::to_string_pretty(&envelope)
        .map_err(|e| format!("Serialize envelope: {e}"))?;

    std::fs::write(&path, &content).map_err(|e| format!("Write config file: {e}"))
}

/// Load configuration from the Rust engine's file-backed config store.
/// Returns JSON of the entire ConfigDocument, or error JSON.
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// Returns a valid null-terminated C string that must be freed.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_config_load() -> *mut c_char {
    match load_config_from_disk() {
        Ok(json_str) => CString::new(json_str).unwrap_or_default().into_raw(),
        Err(e) => error_json(&format!("Config load failed: {e}")),
    }
}

/// Save configuration to the Rust engine's file-backed config store.
/// Input: JSON string of the entire ConfigDocument.
/// Returns `{"ok": true}` or `{"ok": false, "error": "..."}`.
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// `input` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_config_save(input: *const c_char) -> *mut c_char {
    let input_str = match unsafe { CStr::from_ptr(input) }.to_str() {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid input: {e}")),
    };

    // Validate that the input parses as a ConfigDocument.
    if let Err(e) = serde_json::from_str::<ConfigDocument>(input_str) {
        return error_json(&format!("Invalid config JSON: {e}"));
    }

    match save_config_to_disk(input_str) {
        Ok(_) => ok_json(),
        Err(e) => error_json(&format!("Config save failed: {e}")),
    }
}

// ─── Save/Load FFI exports ─────────────────────────────────────────────────

/// Get the saves directory path (under the config dir).
fn get_save_dir() -> std::path::PathBuf {
    let config_dir = get_config_dir();
    config_dir.join("saves")
}

/// Save a game state to disk.
///
/// Input: JSON object `{"file_name": "...", "state": {...}}`.
/// Returns `{"ok": true}` or `{"ok": false, "error": "..."}`.
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// `input` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_save_game(input: *const c_char) -> *mut c_char {
    let input_str = match unsafe { CStr::from_ptr(input) }.to_str() {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid input: {e}")),
    };

    let parsed: serde_json::Value = match serde_json::from_str(input_str) {
        Ok(v) => v,
        Err(e) => return error_json(&format!("Invalid JSON: {e}")),
    };

    let file_name = parsed["file_name"].as_str().unwrap_or("unnamed");
    let state_json = &parsed["state"];

    let save_dir = get_save_dir();
    std::fs::create_dir_all(&save_dir).ok();
    let file_path = save_dir.join(format!("{}.sav", file_name));

    let save_game = serde_json::json!({
        "version": "0.1.0",
        "state": state_json,
    });

    match std::fs::write(&file_path, serde_json::to_string_pretty(&save_game).unwrap_or_default()) {
        Ok(_) => ok_json(),
        Err(e) => error_json(&format!("Failed to write save: {e}")),
    }
}

/// Load a game state from disk.
///
/// Input: save file name (e.g. `"mygame.sav"` or `"mygame"` — `.sav` is
/// appended automatically if missing).
/// Returns the full SaveGame JSON (`{"version": "...", "state": {...}}`)
/// or `{"ok": false, "error": "..."}` on failure.
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// `input` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_load_game(input: *const c_char) -> *mut c_char {
    let input_str = match unsafe { CStr::from_ptr(input) }.to_str() {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid input: {e}")),
    };

    let save_dir = get_save_dir();

    // Try as-is first; if it doesn't exist and has no .sav extension, try with .sav
    let file_path = save_dir.join(input_str);
    let path = if file_path.exists() {
        file_path
    } else if !input_str.ends_with(".sav") {
        let alt_path = save_dir.join(format!("{}.sav", input_str));
        if alt_path.exists() {
            alt_path
        } else {
            file_path
        }
    } else {
        file_path
    };

    if !path.exists() {
        return error_json(&format!("Save file not found: {input_str}"));
    }

    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => return error_json(&format!("Failed to read: {e}")),
    };

    CString::new(content).unwrap_or_default().into_raw()
}

/// List all save files in the saves directory.
///
/// Returns a JSON array of objects: `[{"file_name": "...", "path": "..."}]`.
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// Returns a valid null-terminated C string that must be freed.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_list_saves() -> *mut c_char {
    let save_dir = get_save_dir();
    let mut saves = Vec::new();

    if save_dir.exists() {
        if let Ok(entries) = std::fs::read_dir(&save_dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.extension().and_then(|e| e.to_str()) == Some("sav") {
                    if let Some(name) = p.file_stem().and_then(|n| n.to_str()) {
                        saves.push(serde_json::json!({
                            "file_name": format!("{}.sav", name),
                            "path": p.to_string_lossy(),
                        }));
                    }
                }
            }
        }
    }

    let json_str = serde_json::to_string(&saves).unwrap_or_else(|_| "[]".to_string());
    CString::new(json_str).unwrap_or_default().into_raw()
}

/// Delete a save file from the saves directory.
///
/// Input: save file name (e.g. `"mygame.sav"`).
/// Returns `{"ok": true}` or `{"ok": false, "error": "..."}`.
///
/// The caller must free the returned string with `sa_engine_free_string`.
///
/// # Safety
/// `input` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_delete_save(input: *const c_char) -> *mut c_char {
    let input_str = match unsafe { CStr::from_ptr(input) }.to_str() {
        Ok(s) => s,
        Err(e) => return error_json(&format!("Invalid input: {e}")),
    };

    let save_dir = get_save_dir();
    let file_path = save_dir.join(input_str);

    match std::fs::remove_file(&file_path) {
        Ok(_) => ok_json(),
        Err(e) => error_json(&format!("Failed to delete: {e}")),
    }
}
