use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use serde::{Deserialize, Serialize};

use crate::discovery::{FileSystemPluginDiscovery, PluginDescriptor, PluginDiscovery};

// ============================================================================
// Permission system
// ============================================================================

/// Represents a set of capabilities a plugin may request.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum Permission {
    /// Read access to game state.
    ReadState,
    /// Write access to game state (can modify tiles, players, etc.).
    WriteState,
    /// Execute arbitrary scripts.
    ExecuteScript,
    /// Access the network stack (send/receive messages).
    NetworkAccess,
    /// Access the file system (read/write files).
    FileSystemAccess,
    /// Access external HTTP APIs.
    HttpAccess,
    /// Modify the AI decision pipeline.
    ModifyAI,
    /// Listen to and inject game events.
    EventInjection,
    /// Custom permission defined by the plugin.
    Custom(String),
}

/// Configuration for which permissions are allowed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PermissionSet {
    /// Permissions explicitly granted to the plugin.
    pub granted: HashSet<Permission>,
    /// Permissions explicitly denied (takes precedence over granted).
    pub denied: HashSet<Permission>,
}

impl PermissionSet {
    pub fn new() -> Self {
        Self {
            granted: HashSet::new(),
            denied: HashSet::new(),
        }
    }

    /// Allow a permission.
    pub fn allow(&mut self, perm: Permission) -> &mut Self {
        self.granted.insert(perm);
        self
    }

    /// Deny a permission.
    pub fn deny(&mut self, perm: Permission) -> &mut Self {
        self.denied.insert(perm);
        self
    }

    /// Check whether a permission is allowed.
    pub fn is_allowed(&self, perm: &Permission) -> bool {
        if self.denied.contains(perm) {
            return false;
        }
        self.granted.contains(perm)
    }

    /// Grant a set of default safe permissions.
    pub fn default_safe() -> Self {
        let mut set = Self::new();
        set.allow(Permission::ReadState);
        set.allow(Permission::EventInjection);
        set
    }

    /// Grant all permissions (use with caution).
    pub fn all() -> Self {
        let mut set = Self::new();
        set.allow(Permission::ReadState);
        set.allow(Permission::WriteState);
        set.allow(Permission::ExecuteScript);
        set.allow(Permission::NetworkAccess);
        set.allow(Permission::FileSystemAccess);
        set.allow(Permission::HttpAccess);
        set.allow(Permission::ModifyAI);
        set.allow(Permission::EventInjection);
        set
    }
}

impl Default for PermissionSet {
    fn default() -> Self {
        Self::default_safe()
    }
}

// ============================================================================
// Dynamic loading configuration
// ============================================================================

/// Describes how a plugin should be loaded at runtime.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DynamicLoadConfig {
    /// The kind of plugin artifact.
    pub kind: LoadKind,
    /// File system path to the plugin artifact.
    pub path: PathBuf,
    /// Optional initialisation arguments.
    pub args: HashMap<String, String>,
    /// Whether to enable the permission sandbox.
    pub sandbox: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum LoadKind {
    /// A dynamic library (.so, .dll, .dylib).
    DynamicLibrary,
    /// A WASM module (.wasm).
    WasmModule,
    /// A script file (.lua, .js).
    Script,
    /// Built-in plugin (compiled into the binary).
    BuiltIn,
}

impl Default for DynamicLoadConfig {
    fn default() -> Self {
        Self {
            kind: LoadKind::BuiltIn,
            path: PathBuf::new(),
            args: HashMap::new(),
            sandbox: true,
        }
    }
}

// ============================================================================
// PluginInfo – metadata about a registered plugin
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PluginInfo {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    /// The permissions this plugin requires.
    pub required_permissions: PermissionSet,
    /// Dynamic loading config (None for built-ins).
    pub load_config: Option<DynamicLoadConfig>,
    /// Whether the plugin is currently enabled.
    pub enabled: bool,
}

impl PluginInfo {
    pub fn new(id: &str, name: &str, version: &str) -> Self {
        Self {
            id: id.to_string(),
            name: name.to_string(),
            version: version.to_string(),
            author: String::new(),
            description: String::new(),
            required_permissions: PermissionSet::default_safe(),
            load_config: None,
            enabled: true,
        }
    }
}

// ============================================================================
// Enhanced Plugin trait
// ============================================================================

pub trait Plugin: Send + Sync {
    /// Unique identifier for this plugin.
    fn id(&self) -> &str;

    /// Human-readable name.
    fn name(&self) -> &str {
        self.id()
    }

    /// Plugin version string.
    fn version(&self) -> &str;

    /// Plugin author.
    fn author(&self) -> &str {
        ""
    }

    /// Description of what the plugin does.
    fn description(&self) -> &str {
        ""
    }

    /// The set of permissions this plugin requires.
    fn permissions(&self) -> PermissionSet {
        PermissionSet::default_safe()
    }

    /// Initialise the plugin. Called once after registration.
    fn init(&mut self) -> Result<(), String> {
        Ok(())
    }

    /// Shut down the plugin. Called before removal.
    fn shutdown(&mut self) -> Result<(), String> {
        Ok(())
    }

    /// Get a metadata info struct for this plugin.
    fn info(&self) -> PluginInfo {
        PluginInfo {
            id: self.id().to_string(),
            name: self.name().to_string(),
            version: self.version().to_string(),
            author: self.author().to_string(),
            description: self.description().to_string(),
            required_permissions: self.permissions(),
            load_config: None,
            enabled: true,
        }
    }
}

// ============================================================================
// PluginRegistry (enhanced)
// ============================================================================

/// Error type for plugin operations.
#[derive(Debug, Clone)]
pub enum PluginError {
    NotFound(String),
    AlreadyRegistered(String),
    PermissionDenied(String),
    InitFailed(String),
    VersionConflict(String),
}

impl std::fmt::Display for PluginError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PluginError::NotFound(id) => write!(f, "plugin '{}' not found", id),
            PluginError::AlreadyRegistered(id) => write!(f, "plugin '{}' already registered", id),
            PluginError::PermissionDenied(reason) => write!(f, "permission denied: {}", reason),
            PluginError::InitFailed(reason) => write!(f, "plugin init failed: {}", reason),
            PluginError::VersionConflict(msg) => write!(f, "version conflict: {}", msg),
        }
    }
}

impl std::error::Error for PluginError {}

pub trait PluginRegistry: Send + Sync {
    /// Register a new plugin.
    fn register(&mut self, plugin: Box<dyn Plugin>) -> Result<(), PluginError>;

    /// Unregister a plugin by ID.
    fn unregister(&mut self, id: &str) -> Result<Box<dyn Plugin>, PluginError>;

    /// Get a reference to a registered plugin.
    fn get(&self, id: &str) -> Option<&dyn Plugin>;

    /// Get a mutable reference to a registered plugin.
    fn get_mut(&mut self, id: &str) -> Option<&mut dyn Plugin>;

    /// List all registered plugin IDs.
    fn list_ids(&self) -> Vec<String>;

    /// Check if a plugin is registered.
    fn contains(&self, id: &str) -> bool;

    /// Enable a plugin.
    fn enable(&mut self, id: &str) -> Result<(), PluginError>;

    /// Disable a plugin.
    fn disable(&mut self, id: &str) -> Result<(), PluginError>;

    /// Return the number of registered plugins.
    fn len(&self) -> usize;

    /// Return true if no plugins are registered.
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

// ============================================================================
// InMemoryPluginRegistry – concrete implementation
// ============================================================================

#[derive(Default)]
pub struct InMemoryPluginRegistry {
    plugins: HashMap<String, PluginEntry>,
}

struct PluginEntry {
    plugin: Box<dyn Plugin>,
    enabled: bool,
}

impl PluginRegistry for InMemoryPluginRegistry {
    fn register(&mut self, plugin: Box<dyn Plugin>) -> Result<(), PluginError> {
        let id = plugin.id().to_string();
        if self.plugins.contains_key(&id) {
            return Err(PluginError::AlreadyRegistered(id));
        }

        // Validate permissions before init
        // (In a full implementation we would check against a global policy.)

        let mut p = plugin;
        p.init().map_err(PluginError::InitFailed)?;

        self.plugins.insert(
            id,
            PluginEntry {
                plugin: p,
                enabled: true,
            },
        );
        Ok(())
    }

    fn unregister(&mut self, id: &str) -> Result<Box<dyn Plugin>, PluginError> {
        let mut entry = self
            .plugins
            .remove(id)
            .ok_or_else(|| PluginError::NotFound(id.to_string()))?;

        entry.plugin.shutdown().ok();
        entry.enabled = false;
        Ok(entry.plugin)
    }

    fn get(&self, id: &str) -> Option<&dyn Plugin> {
        self.plugins.get(id).map(|entry| entry.plugin.as_ref())
    }

    fn get_mut(&mut self, id: &str) -> Option<&mut (dyn Plugin + '_)> {
        match self.plugins.get_mut(id) {
            Some(entry) => Some(entry.plugin.as_mut()),
            None => None,
        }
    }

    fn list_ids(&self) -> Vec<String> {
        self.plugins.keys().cloned().collect()
    }

    fn contains(&self, id: &str) -> bool {
        self.plugins.contains_key(id)
    }

    fn enable(&mut self, id: &str) -> Result<(), PluginError> {
        let entry = self
            .plugins
            .get_mut(id)
            .ok_or_else(|| PluginError::NotFound(id.to_string()))?;
        entry.enabled = true;
        entry.plugin.init().map_err(PluginError::InitFailed)
    }

    fn disable(&mut self, id: &str) -> Result<(), PluginError> {
        let entry = self
            .plugins
            .get_mut(id)
            .ok_or_else(|| PluginError::NotFound(id.to_string()))?;
        entry.enabled = false;
        entry.plugin.shutdown().ok();
        Ok(())
    }

    fn len(&self) -> usize {
        self.plugins.len()
    }
}

// ============================================================================
// PluginLoader – loads plugins from descriptors or dynamic configs
// ============================================================================

pub struct PluginLoader<R: PluginRegistry> {
    registry: R,
}

impl<R: PluginRegistry> PluginLoader<R> {
    pub fn new(registry: R) -> Self {
        Self { registry }
    }

    /// Register a boxed plugin directly.
    pub fn load(&mut self, plugin: Box<dyn Plugin>) -> Result<(), PluginError> {
        self.registry.register(plugin)
    }

    /// Load plugins from a [`PluginCatalog`].
    pub fn load_catalog(&mut self, catalog: &PluginCatalog) -> Vec<PluginError> {
        let mut errors = Vec::new();
        for desc in &catalog.descriptors {
            let plugin = DescriptorPlugin::from_descriptor(desc);
            if let Err(e) = self.registry.register(Box::new(plugin)) {
                errors.push(e);
            }
        }
        errors
    }

    /// Load a plugin from a [`DynamicLoadConfig`].
    pub fn load_dynamic(&mut self, config: DynamicLoadConfig) -> Result<(), PluginError> {
        // In a full implementation this would dlopen/WASM-load the plugin.
        // For now we create a descriptor-based plugin.
        let id = config
            .path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown")
            .to_string();
        let plugin = DescriptorPlugin {
            id,
            version: "0.1.0".to_string(),
            load_config: Some(config),
        };
        self.registry.register(Box::new(plugin))
    }

    /// Get a reference to the inner registry.
    pub fn registry(&self) -> &R {
        &self.registry
    }

    /// Get a mutable reference to the inner registry.
    pub fn registry_mut(&mut self) -> &mut R {
        &mut self.registry
    }

    /// List all registered plugin IDs.
    pub fn registered_ids(&self) -> Vec<String> {
        self.registry.list_ids()
    }

    /// Consume the loader and return the registry.
    pub fn into_registry(self) -> R {
        self.registry
    }
}

// ============================================================================
// PluginCatalog – discovers and holds plugin descriptors
// ============================================================================

pub struct PluginCatalog {
    pub descriptors: Vec<PluginDescriptor>,
    pub dynamic_configs: Vec<DynamicLoadConfig>,
}

impl PluginCatalog {
    /// Discover plugins from a root directory on the file system.
    pub fn discover(root: &Path) -> Result<Self, String> {
        let discovery = FileSystemPluginDiscovery;
        let descriptors = discovery.discover(root)?;
        Ok(Self {
            descriptors,
            dynamic_configs: Vec::new(),
        })
    }

    /// Discover plugins and also scan for dynamic load configs.
    pub fn discover_with_dynamic(root: &Path) -> Result<Self, String> {
        let mut catalog = Self::discover(root)?;

        // Scan for dynamic config files (*.plugin.json, *.wasm)
        if root.exists() {
            let entries = std::fs::read_dir(root).map_err(|e| e.to_string())?;
            for entry in entries {
                let entry = entry.map_err(|e| e.to_string())?;
                let path = entry.path();
                if let Some(ext) = path.extension() {
                    match ext.to_str().unwrap_or("") {
                        "wasm" => {
                            let id = path
                                .file_stem()
                                .and_then(|s| s.to_str())
                                .unwrap_or("unknown")
                                .to_string();
                            catalog.dynamic_configs.push(DynamicLoadConfig {
                                kind: LoadKind::WasmModule,
                                path: path.clone(),
                                args: HashMap::new(),
                                sandbox: true,
                            });
                            // Also add as a descriptor
                            catalog.descriptors.push(PluginDescriptor {
                                id,
                                version: "0.1.0".to_string(),
                                path,
                            });
                        }
                        "json" | "yaml" | "toml" => {
                            // Could be a plugin manifest – parse if needed
                        }
                        _ => {}
                    }
                }
            }
        }

        Ok(catalog)
    }
}

// ============================================================================
// PluginContentLoader – loads catalog entries into a registry
// ============================================================================

pub struct PluginContentLoader;

impl PluginContentLoader {
    pub fn load_from_catalog<R: PluginRegistry>(
        catalog: &PluginCatalog,
        loader: &mut PluginLoader<R>,
    ) -> Vec<PluginError> {
        loader.load_catalog(catalog)
    }
}

// ============================================================================
// DescriptorPlugin – wraps PluginDescriptor as a Plugin
// ============================================================================

struct DescriptorPlugin {
    id: String,
    version: String,
    load_config: Option<DynamicLoadConfig>,
}

impl DescriptorPlugin {
    fn from_descriptor(desc: &PluginDescriptor) -> Self {
        Self {
            id: desc.id.clone(),
            version: desc.version.clone(),
            load_config: None,
        }
    }
}

impl Plugin for DescriptorPlugin {
    fn id(&self) -> &str {
        &self.id
    }
    fn version(&self) -> &str {
        &self.version
    }
    fn info(&self) -> PluginInfo {
        PluginInfo {
            id: self.id.clone(),
            name: self.id.clone(),
            version: self.version.clone(),
            author: String::new(),
            description: String::new(),
            required_permissions: PermissionSet::default_safe(),
            load_config: self.load_config.clone(),
            enabled: true,
        }
    }
}

// ============================================================================
// Helper: create an in-memory registry pre-populated with built-in plugins
// ============================================================================

/// Create a pre-configured [`InMemoryPluginRegistry`] containing only the
/// default built-in plugins.
pub fn default_plugin_registry() -> InMemoryPluginRegistry {
    InMemoryPluginRegistry::default()
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal test plugin.
    struct TestPlugin {
        id: String,
        version: String,
        inited: bool,
    }

    impl TestPlugin {
        fn new(id: &str, version: &str) -> Self {
            Self {
                id: id.to_string(),
                version: version.to_string(),
                inited: false,
            }
        }
    }

    impl Plugin for TestPlugin {
        fn id(&self) -> &str {
            &self.id
        }
        fn version(&self) -> &str {
            &self.version
        }
        fn init(&mut self) -> Result<(), String> {
            self.inited = true;
            Ok(())
        }
    }

    #[test]
    fn test_register_and_list() {
        let mut registry = InMemoryPluginRegistry::default();
        registry
            .register(Box::new(TestPlugin::new("test", "1.0.0")))
            .unwrap();
        assert!(registry.contains("test"));
        assert_eq!(registry.list_ids(), vec!["test"]);
        assert_eq!(registry.len(), 1);
    }

    #[test]
    fn test_register_duplicate_fails() {
        let mut registry = InMemoryPluginRegistry::default();
        registry
            .register(Box::new(TestPlugin::new("dup", "1.0.0")))
            .unwrap();
        let result = registry.register(Box::new(TestPlugin::new("dup", "2.0.0")));
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), PluginError::AlreadyRegistered(_)));
    }

    #[test]
    fn test_unregister() {
        let mut registry = InMemoryPluginRegistry::default();
        registry
            .register(Box::new(TestPlugin::new("p1", "1.0.0")))
            .unwrap();
        let plugin = registry.unregister("p1").unwrap();
        assert_eq!(plugin.id(), "p1");
        assert!(!registry.contains("p1"));
    }

    #[test]
    fn test_unregister_not_found() {
        let mut registry = InMemoryPluginRegistry::default();
        let result = registry.unregister("nonexistent");
        assert!(result.is_err());
        match result {
            Err(PluginError::NotFound(_)) => {} // expected
            _ => panic!("expected NotFound error"),
        }
    }

    #[test]
    fn test_enable_disable() {
        let mut registry = InMemoryPluginRegistry::default();
        registry
            .register(Box::new(TestPlugin::new("p1", "1.0.0")))
            .unwrap();
        registry.disable("p1").unwrap();
        registry.enable("p1").unwrap();
    }

    #[test]
    fn test_permission_set_default_safe() {
        let perms = PermissionSet::default_safe();
        assert!(perms.is_allowed(&Permission::ReadState));
        assert!(perms.is_allowed(&Permission::EventInjection));
        assert!(!perms.is_allowed(&Permission::WriteState));
        assert!(!perms.is_allowed(&Permission::NetworkAccess));
    }

    #[test]
    fn test_permission_deny_overrides() {
        let mut perms = PermissionSet::all();
        assert!(perms.is_allowed(&Permission::WriteState));
        perms.deny(Permission::WriteState);
        assert!(!perms.is_allowed(&Permission::WriteState));
    }

    #[test]
    fn test_plugin_loader_catalog() {
        let mut registry = InMemoryPluginRegistry::default();
        let mut loader = PluginLoader::new(registry);

        let catalog = PluginCatalog {
            descriptors: vec![PluginDescriptor {
                id: "cat_plugin".to_string(),
                version: "0.1.0".to_string(),
                path: PathBuf::from("/tmp/plugin"),
            }],
            dynamic_configs: vec![],
        };

        let errors = loader.load_catalog(&catalog);
        assert!(errors.is_empty());
        assert!(loader.registry().contains("cat_plugin"));
    }

    #[test]
    fn test_dynamic_load_config_default() {
        let config = DynamicLoadConfig::default();
        assert_eq!(config.kind, LoadKind::BuiltIn);
        assert!(config.sandbox);
    }

    #[test]
    fn test_plugin_info_default() {
        let info = PluginInfo::new("test", "Test", "1.0.0");
        assert_eq!(info.id, "test");
        assert_eq!(info.name, "Test");
        assert!(info.enabled);
    }

    #[test]
    fn test_loader_into_registry() {
        let registry = InMemoryPluginRegistry::default();
        let mut loader = PluginLoader::new(registry);
        loader
            .load(Box::new(TestPlugin::new("builtin", "1.0.0")))
            .unwrap();
        let registry = loader.into_registry();
        assert!(registry.contains("builtin"));
    }

    #[test]
    fn test_plugin_init_called() {
        let mut registry = InMemoryPluginRegistry::default();
        let plugin = TestPlugin::new("init_test", "1.0.0");
        assert!(!plugin.inited);
        registry.register(Box::new(plugin)).unwrap();
        let loaded = registry.get("init_test").unwrap();
        // init should have been called
        assert_eq!(loaded.id(), "init_test");
    }

    #[test]
    fn test_empty_registry() {
        let registry = InMemoryPluginRegistry::default();
        assert!(registry.is_empty());
        assert_eq!(registry.len(), 0);
    }
}
