use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use crate::bridge::{BridgeRequest, EngineBridge};
use crate::event_bus::EventBus;

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

    let result = EngineBridge::execute_json(input_str);
    let output = match result {
        Ok(json) => json,
        Err(err) => format!(r#"{{"error":"{}"}}"#, err),
    };

    CString::new(output).unwrap_or_default().into_raw()
}
