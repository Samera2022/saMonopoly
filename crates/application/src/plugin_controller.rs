//! Plugin controller — bridges Flutter plugin toggle UI to the Rust engine.
//!
//! Stores enable/disable state for each plugin and exposes FFI functions
//! so the Flutter side can actually enable/disable plugins at runtime.
//!
//! The EventBus subscribers check this controller before processing events.

use std::collections::HashSet;
use std::sync::Mutex;

/// Global plugin controller state.
static PLUGIN_STATE: once_cell::sync::Lazy<PluginController> =
    once_cell::sync::Lazy::new(PluginController::new);

/// Thread-safe plugin enable/disable state.
pub struct PluginController {
    enabled: Mutex<HashSet<String>>,
}

impl PluginController {
    fn new() -> Self {
        let mut enabled = HashSet::new();
        // Default: example plugins enabled
        enabled.insert("dice_stats".to_string());
        enabled.insert("treasure_hunt".to_string());
        enabled.insert("event_logger".to_string());
        enabled.insert("bridge_broadcaster".to_string());
        Self {
            enabled: Mutex::new(enabled),
        }
    }

    pub fn global() -> &'static Self {
        &PLUGIN_STATE
    }

    /// Check if a plugin is currently enabled.
    pub fn is_enabled(&self, plugin_id: &str) -> bool {
        self.enabled.lock().unwrap().contains(plugin_id)
    }

    /// Enable a plugin by ID.
    pub fn enable(&self, plugin_id: &str) {
        self.enabled.lock().unwrap().insert(plugin_id.to_string());
    }

    /// Disable a plugin by ID.
    pub fn disable(&self, plugin_id: &str) {
        self.enabled.lock().unwrap().remove(plugin_id);
    }

    /// Toggle a plugin and return its new state.
    pub fn toggle(&self, plugin_id: &str) -> bool {
        let mut enabled = self.enabled.lock().unwrap();
        if enabled.contains(plugin_id) {
            enabled.remove(plugin_id);
            false
        } else {
            enabled.insert(plugin_id.to_string());
            true
        }
    }
}

// ─── C FFI exports for Flutter dart:ffi ──────────────────────────────────────

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// Enable or disable a plugin at runtime.
///
/// Input JSON format: `{"plugin_id":"dice_stats","enable":true}`
/// Returns JSON: `{"ok":true,"enabled":true}`
///
/// # Safety
/// `input` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sa_engine_plugin_ctl(input: *const c_char) -> *mut c_char {
    let input_str = unsafe {
        if input.is_null() {
            return CString::new(r#"{"error":"null input"}"#)
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

    let result = (|| -> Result<String, String> {
        let cmd: serde_json::Value =
            serde_json::from_str(input_str).map_err(|e| format!("invalid json: {e}"))?;

        let plugin_id = cmd["plugin_id"]
            .as_str()
            .ok_or_else(|| "missing plugin_id".to_string())?;
        let enable = cmd["enable"].as_bool().ok_or_else(|| "missing enable".to_string())?;

        if enable {
            PluginController::global().enable(plugin_id);
        } else {
            PluginController::global().disable(plugin_id);
        }

        Ok(serde_json::json!({"ok": true, "enabled": enable}).to_string())
    })();

    let output = match result {
        Ok(json) => json,
        Err(err) => format!(r#"{{"error":"{}"}}"#, err),
    };

    CString::new(output).unwrap_or_default().into_raw()
}
