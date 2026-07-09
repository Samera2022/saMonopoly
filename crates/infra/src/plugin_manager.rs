use std::collections::HashMap;
use std::path::{Path, PathBuf};

use sa_monopoly_application::event_bus::EventBus;

use crate::map::{MapDefinition, MapPluginRef};
use crate::plugins::{
    Plugin, PluginInfo, PluginOrigin, PluginStatus,
};

/// Internal wrapper for a managed plugin
struct ManagedPlugin {
    info: PluginInfo,
    plugin: Box<dyn Plugin>,
    status: PluginStatus,
}

/// Unified plugin manager — manages local and map-bundled plugins
pub struct PluginManager {
    /// Locally installed plugins (persisted across maps)
    local_plugins: HashMap<String, ManagedPlugin>,
    /// Current map's bundled plugins
    bundled_plugins: HashMap<String, ManagedPlugin>,
    /// Mandatory plugin IDs (from current map)
    mandatory_plugins: Vec<String>,
    /// Currently active plugin IDs (loaded into EventBus)
    active_plugins: Vec<String>,
    /// Path to the plugins directory
    plugins_dir: PathBuf,
}

impl PluginManager {
    pub fn new(plugins_dir: PathBuf) -> Self {
        Self {
            local_plugins: HashMap::new(),
            bundled_plugins: HashMap::new(),
            mandatory_plugins: Vec::new(),
            active_plugins: Vec::new(),
            plugins_dir,
        }
    }

    // ─── Local plugin management ───

    /// Scan the plugins directory and load all discovered plugins
    pub fn discover_local(&mut self) -> Result<Vec<String>, String> {
        let mut discovered = Vec::new();
        if !self.plugins_dir.exists() {
            std::fs::create_dir_all(&self.plugins_dir)
                .map_err(|e| format!("Failed to create plugins dir: {}", e))?;
            return Ok(discovered);
        }

        let entries = std::fs::read_dir(&self.plugins_dir)
            .map_err(|e| format!("Failed to read plugins dir: {}", e))?;

        for entry in entries {
            let entry = entry.map_err(|e| format!("Entry error: {}", e))?;
            let path = entry.path();
            if path.is_dir() {
                // Directory-based plugin: look for meta.json inside
                let meta_path = path.join("meta.json");
                if meta_path.exists() {
                    let content = std::fs::read_to_string(&meta_path)
                        .map_err(|e| format!("Failed to read meta.json: {}", e))?;
                    let info: PluginInfo = serde_json::from_str(&content)
                        .map_err(|e| format!("Invalid meta.json: {}", e))?;
                    let plugin_id = info.id.clone();
                    self.local_plugins.insert(plugin_id.clone(), ManagedPlugin {
                        info,
                        plugin: Box::new(crate::plugins::DescriptorPlugin::from_descriptor(
                            &crate::discovery::PluginDescriptor {
                                id: plugin_id.clone(),
                                version: "0.1.0".to_string(),
                                path: path.clone(),
                            }
                        )),
                        status: PluginStatus::Disabled,
                    });
                    discovered.push(plugin_id);
                }
            } else if path.extension().map(|e| e == "wasm").unwrap_or(false) {
                // Standalone WASM plugin
                let plugin_id = path.file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("unknown")
                    .to_string();
                let info = PluginInfo::new_local(&plugin_id, &plugin_id, "0.1.0", path.clone());
                self.local_plugins.insert(plugin_id.clone(), ManagedPlugin {
                    info,
                    plugin: Box::new(crate::plugins::DescriptorPlugin::from_descriptor(
                        &crate::discovery::PluginDescriptor {
                            id: plugin_id.clone(),
                            version: "0.1.0".to_string(),
                            path,
                        }
                    )),
                    status: PluginStatus::Disabled,
                });
                discovered.push(plugin_id);
            }
        }
        Ok(discovered)
    }

    /// Install a plugin from a file path (copy to plugins dir)
    pub fn install_local(&mut self, source_path: &Path) -> Result<String, String> {
        let file_name = source_path.file_name()
            .and_then(|s| s.to_str())
            .ok_or_else(|| "Invalid file name".to_string())?;
        let dest_path = self.plugins_dir.join(file_name);
        std::fs::copy(source_path, &dest_path)
            .map_err(|e| format!("Failed to copy plugin: {}", e))?;
        self.discover_local()?;
        Ok(file_name.to_string())
    }

    /// Uninstall a local plugin
    pub fn uninstall_local(&mut self, plugin_id: &str, bus: &mut EventBus) -> Result<(), String> {
        // Deactivate if active
        if self.active_plugins.contains(&plugin_id.to_string()) {
            self.disable_plugin(plugin_id, bus)?;
        }

        // Remove from local_plugins and delete files
        if let Some(managed) = self.local_plugins.remove(plugin_id) {
            if let PluginOrigin::Local { install_path, .. } = &managed.info.origin {
                if install_path.exists() {
                    if install_path.is_dir() {
                        std::fs::remove_dir_all(install_path)
                            .map_err(|e| format!("Failed to remove plugin dir: {}", e))?;
                    } else {
                        std::fs::remove_file(install_path)
                            .map_err(|e| format!("Failed to remove plugin file: {}", e))?;
                    }
                }
            }
            Ok(())
        } else {
            Err(format!("Plugin '{}' not found", plugin_id))
        }
    }

    // ─── Map-bundled plugin management ───

    /// Load a map's plugin declarations (clears previous bundled plugins)
    pub fn load_map_plugins(&mut self, map: &MapDefinition) -> Vec<MapPluginRef> {
        self.bundled_plugins.clear();
        self.mandatory_plugins.clear();

        for plugin_ref in &map.plugins {
            let plugin_id = plugin_ref.id.clone();
            if plugin_ref.mandatory {
                self.mandatory_plugins.push(plugin_id.clone());
            }

            // For bundled plugins, create a ManagedPlugin from the embedded data
            if plugin_ref.source == crate::map::MapPluginSource::Bundled {
                if let Some(_data) = &plugin_ref.bundled_data {
                    let info = PluginInfo::new_bundled(
                        &plugin_id, &plugin_ref.name, &plugin_ref.min_version,
                        &map.id, &plugin_id, plugin_ref.mandatory,
                    );
                    let plugin = crate::plugins::DescriptorPlugin::from_descriptor(
                        &crate::discovery::PluginDescriptor {
                            id: plugin_id.clone(),
                            version: plugin_ref.min_version.clone(),
                            path: PathBuf::new(),
                        }
                    );
                    self.bundled_plugins.insert(plugin_id, ManagedPlugin {
                        info,
                        plugin: Box::new(plugin),
                        status: PluginStatus::Disabled,
                    });
                }
            }
        }

        map.plugins.clone()
    }

    // ─── Enable/Disable ───

    /// Enable a plugin and register it with the EventBus
    pub fn enable_plugin(&mut self, plugin_id: &str, bus: &mut EventBus) -> Result<(), String> {
        if self.active_plugins.contains(&plugin_id.to_string()) {
            return Ok(()); // already active
        }

        let managed = self.get_plugin_mut(plugin_id)
            .ok_or_else(|| format!("Plugin '{}' not found", plugin_id))?;

        // Register subscribers, commands, tile behaviors
        managed.plugin.register_subscribers(bus);
        managed.plugin.register_pre_hooks(bus);
        managed.plugin.register_post_hooks(bus);
        
        // Mark as active
        managed.status = PluginStatus::Active;
        self.active_plugins.push(plugin_id.to_string());
        Ok(())
    }

    /// Disable a plugin and unregister from EventBus (cannot disable mandatory plugins)
    pub fn disable_plugin(&mut self, plugin_id: &str, bus: &mut EventBus) -> Result<(), String> {
        if self.mandatory_plugins.contains(&plugin_id.to_string()) {
            return Err(format!("Cannot disable mandatory plugin '{}'", plugin_id));
        }

        // Unsubscribe from EventBus
        bus.unsubscribe(plugin_id);
        // Unregister command handlers
        bus.command_handlers.unregister_plugin(plugin_id);
        // Unregister tile behaviors
        bus.tile_behaviors.unregister_plugin(plugin_id);

        // Update status
        if let Some(managed) = self.get_plugin_mut(plugin_id) {
            managed.status = PluginStatus::Disabled;
        }
        self.active_plugins.retain(|id| id != plugin_id);
        Ok(())
    }

    // ─── Queries ───

    pub fn list_local(&self) -> Vec<&PluginInfo> {
        self.local_plugins.values().map(|m| &m.info).collect()
    }

    pub fn list_bundled(&self) -> Vec<&PluginInfo> {
        self.bundled_plugins.values().map(|m| &m.info).collect()
    }

    pub fn mandatory_ids(&self) -> &[String] {
        &self.mandatory_plugins
    }

    pub fn active_ids(&self) -> &[String] {
        &self.active_plugins
    }

    pub fn status_of(&self, plugin_id: &str) -> Option<&PluginStatus> {
        self.get_plugin(plugin_id).map(|m| &m.status)
    }

    pub fn all_mandatory_active(&self) -> bool {
        self.mandatory_plugins.iter().all(|id| self.active_plugins.contains(id))
    }

    /// Clear all bundled plugins (when switching maps)
    pub fn clear_bundled(&mut self) {
        self.bundled_plugins.clear();
        self.mandatory_plugins.clear();
    }

    // ─── Plugin sync (multiplayer) ───

    /// Build a list of PluginSyncEntry for network broadcast
    pub fn build_sync_entries(&self) -> Vec<crate::plugins::PluginSyncEntry> {
        let mut entries = Vec::new();
        // Bundled plugins from current map
        for (id, managed) in &self.bundled_plugins {
            entries.push(crate::plugins::PluginSyncEntry {
                id: id.clone(),
                name: managed.info.name.clone(),
                min_version: managed.info.version.clone(),
                mandatory: self.mandatory_plugins.contains(id),
                source: "bundled".to_string(),
                enabled: self.active_plugins.contains(id),
                bundled_data: None,
            });
        }
        // Enabled local plugins
        for (id, managed) in &self.local_plugins {
            if self.active_plugins.contains(id) {
                entries.push(crate::plugins::PluginSyncEntry {
                    id: id.clone(),
                    name: managed.info.name.clone(),
                    min_version: managed.info.version.clone(),
                    mandatory: false,
                    source: "external".to_string(),
                    enabled: true,
                    bundled_data: None,
                });
            }
        }
        entries
    }

    /// Validate client ack against mandatory plugins
    pub fn validate_client_plugins(&self, missing: &[String]) -> Result<(), Vec<String>> {
        let mut unresolved = Vec::new();
        for mandatory_id in &self.mandatory_plugins {
            if missing.contains(mandatory_id) {
                unresolved.push(mandatory_id.clone());
            }
        }
        if unresolved.is_empty() { Ok(()) } else { Err(unresolved) }
    }

    // ─── Hot-plug: register into EventBus ───

    /// Register all active plugins' hooks/subscribers into the given EventBus.
    /// Used to inject active plugins after a fresh bus is created (e.g. in bridge).
    pub fn register_into_bus(&mut self, bus: &mut EventBus) {
        for id in self.active_plugins.clone() {
            if let Some(managed) = self.get_plugin_mut(&id) {
                managed.plugin.register_subscribers(bus);
                managed.plugin.register_pre_hooks(bus);
                managed.plugin.register_post_hooks(bus);
            }
        }
    }

    // ─── Helpers ───

    fn get_plugin(&self, id: &str) -> Option<&ManagedPlugin> {
        self.local_plugins.get(id)
            .or_else(|| self.bundled_plugins.get(id))
    }

    fn get_plugin_mut(&mut self, id: &str) -> Option<&mut ManagedPlugin> {
        if self.local_plugins.contains_key(id) {
            self.local_plugins.get_mut(id)
        } else {
            self.bundled_plugins.get_mut(id)
        }
    }
}
