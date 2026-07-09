use std::path::Path;

use libloading::Library;

use sa_monopoly_application::event_bus::EventBus;

use crate::plugins::Plugin;

/// A loaded dynamic-library plugin.
///
/// Holds the `libloading::Library` handle so the shared library stays resident
/// for as long as the plugin is alive. Dropping this struct will unload the
/// library, which **must not** happen while the plugin's code is still
/// referenced (e.g. via EventBus subscribers / hooks).
pub struct DynamicLibPlugin {
    /// The loaded dynamic library handle (.so / .dll / .dylib).
    #[allow(dead_code)]
    library: Library,
    /// The plugin identifier, extracted from the loaded plugin.
    plugin_id: String,
}

impl DynamicLibPlugin {
    /// Load a dynamic library at `path`, look up the `create_plugin` symbol,
    /// call it, and register the returned [`Plugin`] with the given [`EventBus`].
    ///
    /// # Safety
    ///
    /// - The dynamic library **must** export an
    ///   `extern "C" fn create_plugin() -> *mut dyn Plugin` symbol.
    /// - The returned `*mut dyn Plugin` must be a valid, heap-allocated object
    ///   that can be safely taken ownership of via `Box::from_raw`.
    /// - The caller must ensure the returned [`DynamicLibPlugin`] outlives any
    ///   references to the plugin's code (subscribers, hooks, vtables) that
    ///   have been registered on the `EventBus`.
    pub fn load(path: &Path, bus: &mut EventBus) -> Result<Self, String> {
        // Safety: opening a native library performs arbitrary external code.
        let lib = unsafe {
            Library::new(path).map_err(|e| {
                format!(
                    "Failed to load dynamic library '{}': {}",
                    path.display(),
                    e
                )
            })?
        };

        // Safety: the `create_plugin` symbol must point to a valid
        // `extern "C" fn() -> *mut dyn Plugin` exported by the library.
        let create_fn: libloading::Symbol<
            unsafe extern "C" fn() -> *mut dyn Plugin,
        > = unsafe {
            lib.get(b"create_plugin").map_err(|e| {
                format!(
                    "Symbol 'create_plugin' not found in '{}': {}",
                    path.display(),
                    e
                )
            })?
        };

        // Safety: the function pointer loaded above is valid.  We must also
        // assume the returned `*mut dyn Plugin` is a valid heap allocation.
        let plugin_ptr = unsafe { create_fn() };

        // Safety: take ownership of the boxed plugin returned by the library.
        let mut plugin: Box<dyn Plugin> = unsafe { Box::from_raw(plugin_ptr) };

        let plugin_id = plugin.id().to_string();
        log::info!(
            "Loaded dynamic plugin '{}' from '{}'",
            plugin_id,
            path.display()
        );

        // Register the plugin's subscribers and hooks with the EventBus.
        plugin.register_subscribers(bus);
        plugin.register_pre_hooks(bus);
        plugin.register_post_hooks(bus);

        Ok(Self {
            library: lib,
            plugin_id,
        })
    }

    /// Return the plugin identifier.
    pub fn plugin_id(&self) -> &str {
        &self.plugin_id
    }
}

// ============================================================================
// The DynamicLibPlugin does **not** implement Drop that unregisters from
// EventBus — the caller is responsible for managing that lifecycle.
// When `library` is dropped, the shared library is unloaded.  Any vtables
// or function pointers pointing into that library become dangling, so the
// caller must ensure the EventBus has been cleaned up first.
// ============================================================================
