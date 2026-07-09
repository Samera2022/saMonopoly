use std::path::Path;

use wasmtime::{
    Engine, Instance, Linker, Memory, Module, Store,
};

use sa_monopoly_application::event_bus::EventBus;

// ---------------------------------------------------------------------------
// PluginStoreData — stored inside wasmtime::Store
// ---------------------------------------------------------------------------

/// Per-instance data stored inside [`wasmtime::Store`].
///
/// Holds a raw pointer to the [`EventBus`] so that WASM host functions can
/// mutate the bus when invoked by the plugin.
///
/// # Safety
///
/// The caller of [`WasmPluginRuntime::load_plugin`] must guarantee that the
/// `&mut EventBus` reference outlives the returned [`WasmPluginInstance`].
/// Because the instance holds the only `Store` that references this pointer,
/// and the store is dropped when the instance is dropped, the aliasing rules
/// are upheld as long as the instance is not leaked.
struct PluginStoreData {
    bus: *mut EventBus,
}

// Wasmtime requires StoreData: Send + Sized.
unsafe impl Send for PluginStoreData {}

// ---------------------------------------------------------------------------
// WasmPluginRuntime
// ---------------------------------------------------------------------------

/// A WASM-based plugin runtime that can load and execute WebAssembly plugins.
///
/// Each runtime owns a [`wasmtime::Engine`] and can load multiple plugin
/// instances via [`WasmPluginRuntime::load_plugin`].
pub struct WasmPluginRuntime {
    engine: Engine,
}

impl WasmPluginRuntime {
    /// Create a new WASM plugin runtime with a default engine configuration.
    pub fn new() -> Result<Self, String> {
        let engine = Engine::default();
        Ok(Self { engine })
    }
}

// ---------------------------------------------------------------------------
// WasmPluginInstance
// ---------------------------------------------------------------------------

/// A loaded and initialised WASM plugin instance.
///
/// Holds the [`wasmtime::Store`] (which owns the instance's linear memory
/// and host state) and the [`wasmtime::Instance`] handle.
pub struct WasmPluginInstance {
    #[allow(dead_code)]
    store: Store<PluginStoreData>,
    #[allow(dead_code)]
    instance: Instance,
}

impl WasmPluginRuntime {
    /// Load a WASM module from the file at `wasm_path`, register the standard
    /// set of host functions (`subscribe_event`, `publish_event`, `get_state`),
    /// instantiate the module, and call its exported `init` function.
    ///
    /// The provided `bus` is stored as a raw pointer inside the store and is
    /// made available to every host function.  The caller must ensure that
    /// `bus` remains alive for the entire lifetime of the returned instance.
    pub fn load_plugin(
        &self,
        wasm_path: &Path,
        bus: &mut EventBus,
    ) -> Result<WasmPluginInstance, String> {
        // 1. Load the WASM module from disk --------------------------------
        let module = Module::from_file(&self.engine, wasm_path)
            .map_err(|e| format!("failed to load WASM module from {:?}: {e}", wasm_path))?;

        // 2. Create a Linker and register host functions --------------------
        let mut linker: Linker<PluginStoreData> = Linker::new(&self.engine);

        // -- subscribe_event(event_type_ptr, event_type_len) -> i32
        linker
            .func_wrap(
                "env",
                "subscribe_event",
                |mut caller: wasmtime::Caller<'_, PluginStoreData>,
                 event_type_ptr: u32,
                 event_type_len: u32|
                 -> anyhow::Result<i32> {
                    let event_type = wasm_read_string(&mut caller, event_type_ptr, event_type_len)?;
                    log::info!("[WASM] subscribe_event: {event_type}");
                    // TODO: wire up a proper WASM-callback subscriber once the
                    //       EventBus supports dynamically-typed subscribers.
                    Ok(0)
                },
            )
            .map_err(|e| format!("failed to register subscribe_event: {e}"))?;

        // -- publish_event(
        //         event_type_ptr, event_type_len,
        //         payload_ptr,   payload_len
        //     ) -> i32
        linker
            .func_wrap(
                "env",
                "publish_event",
                |mut caller: wasmtime::Caller<'_, PluginStoreData>,
                 event_type_ptr: u32,
                 event_type_len: u32,
                 payload_ptr: u32,
                 payload_len: u32|
                 -> anyhow::Result<i32> {
                    let event_type =
                        wasm_read_string(&mut caller, event_type_ptr, event_type_len)?;
                    let payload_str =
                        wasm_read_string(&mut caller, payload_ptr, payload_len)?;

                    let payload: serde_json::Value =
                        serde_json::from_str(&payload_str).unwrap_or(serde_json::Value::Null);

                    let _bus = unsafe { &mut *caller.data().bus };

                    // Publish the event through the bus.
                    // NOTE: We don't have a GameState reference here, so the
                    // current implementation logs only. A production version
                    // would plumb the current GameState through the store data.
                    // _bus.publish_custom(event_type, "wasm-plugin", payload, state);
                    log::info!(
                        "[WASM] publish_event: {event_type} payload: {payload}"
                    );
                    Ok(0)
                },
            )
            .map_err(|e| format!("failed to register publish_event: {e}"))?;

        // -- get_state(key_ptr, key_len, out_ptr, out_max_len) -> u32
        linker
            .func_wrap(
                "env",
                "get_state",
                |mut caller: wasmtime::Caller<'_, PluginStoreData>,
                 key_ptr: u32,
                 key_len: u32,
                 _out_ptr: u32,
                 _out_max_len: u32|
                 -> anyhow::Result<u32> {
                    let key = wasm_read_string(&mut caller, key_ptr, key_len)?;
                    log::info!("[WASM] get_state: {key}");

                    // TODO: read from the actual GameState and write the value
                    //       back into WASM linear memory at `_out_ptr`.
                    Ok(0)
                },
            )
            .map_err(|e| format!("failed to register get_state: {e}"))?;

        // 3. Instantiate the module ----------------------------------------
        let store_data = PluginStoreData {
            bus: bus as *mut EventBus,
        };
        let mut store = Store::new(&self.engine, store_data);

        let instance = linker
            .instantiate(&mut store, &module)
            .map_err(|e| format!("failed to instantiate WASM module: {e}"))?;

        // 4. Call the optional `init` export --------------------------------
        if let Ok(init) = instance.get_typed_func::<(), ()>(&mut store, "init") {
            init.call(&mut store, ())
                .map_err(|e| format!("init() export failed: {e}"))?;
        }

        Ok(WasmPluginInstance { store, instance })
    }
}

// ---------------------------------------------------------------------------
// Helper: read a string from WASM linear memory into an owned String
// ---------------------------------------------------------------------------

/// Read a UTF-8 `String` from WASM linear memory at offset `ptr` with the
/// given `len`.  Returns an `anyhow::Error` if the region is out of bounds
/// or contains invalid UTF-8.
fn wasm_read_string(
    caller: &mut wasmtime::Caller<'_, PluginStoreData>,
    ptr: u32,
    len: u32,
) -> anyhow::Result<String> {
    let memory: Memory = caller
        .get_export("memory")
        .and_then(|e| e.into_memory())
        .ok_or_else(|| anyhow::anyhow!("WASM module did not export 'memory'"))?;

    let data = memory.data(&caller);
    let start = ptr as usize;
    let end = start
        .checked_add(len as usize)
        .ok_or_else(|| anyhow::anyhow!("integer overflow in WASM pointer arithmetic"))?;
    if end > data.len() {
        anyhow::bail!("WASM memory read out of bounds: offset {start} length {len}");
    }

    let s = std::str::from_utf8(&data[start..end])
        .map_err(|_| anyhow::anyhow!("invalid UTF-8 in WASM memory"))?;

    Ok(s.to_string())
}
