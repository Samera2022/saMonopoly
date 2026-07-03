use std::collections::HashMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::discovery::BuildScriptConfig;
use crate::map::MapDefinition;

// ============================================================================
// Content pack
// ============================================================================

/// A content pack containing one or more game maps.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContentPack {
    /// Unique identifier (e.g. "classic-pack").
    pub id: String,
    /// Semantic version string.
    pub version: String,
    /// Human-readable display name (optional, falls back to `id`).
    #[serde(default)]
    pub name: String,
    /// Description of the content pack.
    #[serde(default)]
    pub description: String,
    /// Author / maintainer information.
    #[serde(default)]
    pub author: String,
    /// Ordered list of map definitions in this pack.
    #[serde(default)]
    pub maps: Vec<MapDefinition>,
    /// Arbitrary metadata (i18n keys, tags, etc.).
    #[serde(default)]
    pub metadata: HashMap<String, String>,
    /// Build-time configuration (not serialised).
    #[serde(skip)]
    pub build_config: Option<BuildScriptConfig>,
}

impl ContentPack {
    /// Create a new content pack with the given ID and version.
    pub fn new(id: &str, version: &str) -> Self {
        Self {
            id: id.to_string(),
            version: version.to_string(),
            name: String::new(),
            description: String::new(),
            author: String::new(),
            maps: Vec::new(),
            metadata: HashMap::new(),
            build_config: None,
        }
    }

    /// Set the display name.
    pub fn with_name(mut self, name: &str) -> Self {
        self.name = name.to_string();
        self
    }

    /// Add a map to this pack.
    pub fn add_map(mut self, map: MapDefinition) -> Self {
        self.maps.push(map);
        self
    }

    /// Add a metadata key-value pair.
    pub fn with_metadata(mut self, key: &str, value: &str) -> Self {
        self.metadata.insert(key.to_string(), value.to_string());
        self
    }

    /// Set the build script configuration for this pack.
    pub fn with_build_config(mut self, config: BuildScriptConfig) -> Self {
        self.build_config = Some(config);
        self
    }

    /// Return the effective display name.
    pub fn display_name(&self) -> &str {
        if self.name.is_empty() { &self.id } else { &self.name }
    }
}

// ============================================================================
// Content pack catalog
// ============================================================================

/// A catalog of all known content packs.
#[derive(Debug, Clone)]
pub struct ContentCatalog {
    /// Packs keyed by ID.
    packs: HashMap<String, ContentPack>,
    /// Ordered list of pack IDs (discovery order).
    order: Vec<String>,
}

impl ContentCatalog {
    pub fn new() -> Self {
        Self {
            packs: HashMap::new(),
            order: Vec::new(),
        }
    }

    /// Register a content pack.
    pub fn register(&mut self, pack: ContentPack) -> Result<(), String> {
        let id = pack.id.clone();
        if self.packs.contains_key(&id) {
            return Err(format!("content pack '{}' already registered", id));
        }
        self.packs.insert(id.clone(), pack);
        self.order.push(id);
        Ok(())
    }

    /// Get a content pack by ID.
    pub fn get(&self, id: &str) -> Option<&ContentPack> {
        self.packs.get(id)
    }

    /// Remove a content pack by ID.
    pub fn remove(&mut self, id: &str) -> Option<ContentPack> {
        let pack = self.packs.remove(id);
        if pack.is_some() {
            self.order.retain(|i| i != id);
        }
        pack
    }

    /// List all registered pack IDs.
    pub fn list_ids(&self) -> &[String] {
        &self.order
    }

    /// Iterate over all packs.
    pub fn iter(&self) -> impl Iterator<Item = &ContentPack> {
        self.order.iter().filter_map(move |id| self.packs.get(id))
    }

    /// Return the number of registered packs.
    pub fn len(&self) -> usize {
        self.packs.len()
    }

    /// Return true if no packs are registered.
    pub fn is_empty(&self) -> bool {
        self.packs.is_empty()
    }

    /// Find a map across all registered packs by its ID.
    ///
    /// Returns `(pack_id, map)` if found.
    pub fn find_map(&self, map_id: &str) -> Option<(&str, &MapDefinition)> {
        for pack in self.iter() {
            if let Some(map) = pack.maps.iter().find(|m| m.id == map_id) {
                return Some((&pack.id, map));
            }
        }
        None
    }
}

impl Default for ContentCatalog {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================================
// Content loader
// ============================================================================

pub trait ContentLoader {
    /// Load a single content pack from a JSON string.
    fn load_json(&self, input: &str) -> Result<ContentPack, String>;

    /// Load a content pack from a file path.
    fn load_file(&self, path: &Path) -> Result<ContentPack, String>;

    /// Load all content packs from a directory into a catalog.
    fn load_directory(&self, dir: &Path, catalog: &mut ContentCatalog) -> Result<usize, String>;
}

/// JSON-based content loader.
pub struct JsonContentLoader;

impl ContentLoader for JsonContentLoader {
    fn load_json(&self, input: &str) -> Result<ContentPack, String> {
        let mut pack: ContentPack = serde_json::from_str(input).map_err(|err| err.to_string())?;
        // Apply defaults
        if pack.name.is_empty() {
            pack.name = pack.id.clone();
        }
        Ok(pack)
    }

    fn load_file(&self, path: &Path) -> Result<ContentPack, String> {
        let content = std::fs::read_to_string(path).map_err(|err| err.to_string())?;
        self.load_json(&content)
    }

    fn load_directory(&self, dir: &Path, catalog: &mut ContentCatalog) -> Result<usize, String> {
        if !dir.exists() {
            return Ok(0);
        }

        let mut count = 0;
        for entry in std::fs::read_dir(dir).map_err(|err| err.to_string())? {
            let entry = entry.map_err(|err| err.to_string())?;
            let path = entry.path();

            if path.is_dir() {
                // Look for pack.json or manifest.json inside
                for manifest_name in &["pack.json", "manifest.json", "content.json"] {
                    let manifest_path = path.join(manifest_name);
                    if manifest_path.exists() {
                        match self.load_file(&manifest_path) {
                            Ok(pack) => {
                                if catalog.register(pack).is_ok() {
                                    count += 1;
                                }
                            }
                            Err(e) => {
                                eprintln!(
                                    "Warning: failed to load pack from '{}': {}",
                                    manifest_path.display(),
                                    e
                                );
                            }
                        }
                        break;
                    }
                }
            } else if let Some(ext) = path.extension() {
                if ext == "json" {
                    match self.load_file(&path) {
                        Ok(pack) => {
                            if catalog.register(pack).is_ok() {
                                count += 1;
                            }
                        }
                        Err(e) => {
                            eprintln!(
                                "Warning: failed to load '{}': {}",
                                path.display(),
                                e
                            );
                        }
                    }
                }
            }
        }

        Ok(count)
    }
}

/// A loader that wraps another loader and validates maps after loading.
pub struct ValidatingContentLoader<L: ContentLoader> {
    inner: L,
    validator: Box<dyn crate::map::MapValidator>,
}

impl<L: ContentLoader> ValidatingContentLoader<L> {
    pub fn new(inner: L, validator: Box<dyn crate::map::MapValidator>) -> Self {
        Self { inner, validator }
    }
}

impl<L: ContentLoader> ContentLoader for ValidatingContentLoader<L> {
    fn load_json(&self, input: &str) -> Result<ContentPack, String> {
        let pack = self.inner.load_json(input)?;
        // Validate each map
        for map in &pack.maps {
            self.validator
                .validate(map)
                .map_err(|errors| format!("map '{}' validation failed: {:?}", map.id, errors))?;
        }
        Ok(pack)
    }

    fn load_file(&self, path: &Path) -> Result<ContentPack, String> {
        let pack = self.inner.load_file(path)?;
        for map in &pack.maps {
            self.validator
                .validate(map)
                .map_err(|errors| format!("map '{}' validation failed: {:?}", map.id, errors))?;
        }
        Ok(pack)
    }

    fn load_directory(&self, dir: &Path, catalog: &mut ContentCatalog) -> Result<usize, String> {
        self.inner.load_directory(dir, catalog)
    }
}

// ============================================================================
// Convenience: build the default catalog
// ============================================================================

/// Create a [`ContentCatalog`] pre-populated with packs from the standard
/// content directory.
pub fn default_content_catalog(content_root: &Path) -> ContentCatalog {
    let mut catalog = ContentCatalog::new();
    let loader = JsonContentLoader;
    let _ = loader.load_directory(content_root, &mut catalog);
    catalog
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use crate::map::BasicMapValidator;

    use super::*;

    #[test]
    fn test_content_pack_new() {
        let pack = ContentPack::new("test-pack", "1.0.0").with_name("Test Pack");
        assert_eq!(pack.id, "test-pack");
        assert_eq!(pack.version, "1.0.0");
        assert_eq!(pack.display_name(), "Test Pack");
    }

    #[test]
    fn test_content_pack_display_name_fallback() {
        let pack = ContentPack::new("fallback-id", "1.0.0");
        assert_eq!(pack.display_name(), "fallback-id");
    }

    #[test]
    fn test_content_catalog_register_and_get() {
        let mut catalog = ContentCatalog::new();
        let pack = ContentPack::new("p1", "1.0.0");
        catalog.register(pack).unwrap();
        assert!(catalog.get("p1").is_some());
        assert_eq!(catalog.len(), 1);
    }

    #[test]
    fn test_content_catalog_duplicate_fails() {
        let mut catalog = ContentCatalog::new();
        catalog
            .register(ContentPack::new("dup", "1.0.0"))
            .unwrap();
        let result = catalog.register(ContentPack::new("dup", "2.0.0"));
        assert!(result.is_err());
    }

    #[test]
    fn test_content_catalog_remove() {
        let mut catalog = ContentCatalog::new();
        catalog
            .register(ContentPack::new("p1", "1.0.0"))
            .unwrap();
        assert!(catalog.remove("p1").is_some());
        assert!(catalog.is_empty());
    }

    #[test]
    fn test_content_catalog_list_ids() {
        let mut catalog = ContentCatalog::new();
        catalog
            .register(ContentPack::new("a", "1.0.0"))
            .unwrap();
        catalog
            .register(ContentPack::new("b", "1.0.0"))
            .unwrap();
        let ids = catalog.list_ids();
        assert_eq!(ids.len(), 2);
        assert!(ids.contains(&"a".to_string()));
        assert!(ids.contains(&"b".to_string()));
    }

    #[test]
    fn test_json_content_loader_valid_json() {
        let loader = JsonContentLoader;
        let json = r#"
        {
            "id": "test-pack",
            "version": "0.1.0",
            "name": "Test",
            "maps": []
        }
        "#;
        let pack = loader.load_json(json).unwrap();
        assert_eq!(pack.id, "test-pack");
        assert_eq!(pack.maps.len(), 0);
    }

    #[test]
    fn test_json_content_loader_invalid_json() {
        let loader = JsonContentLoader;
        let result = loader.load_json("not json");
        assert!(result.is_err());
    }

    #[test]
    fn test_validating_content_loader() {
        let inner = JsonContentLoader;
        let validator = BasicMapValidator;
        let loader = ValidatingContentLoader::new(inner, Box::new(validator));

        let json = r#"
        {
            "id": "valid-pack",
            "version": "0.1.0",
            "maps": []
        }
        "#;
        let result = loader.load_json(json);
        assert!(result.is_ok());
    }

    #[test]
    fn test_content_catalog_find_map() {
        let mut catalog = ContentCatalog::new();

        let map = MapDefinition {
            id: "map1".to_string(),
            version: "1.0.0".to_string(),
            name_key: "maps.map1".to_string(),
            tiles: vec![],
            rules: crate::map::MapRules {
                allow_custom_topology: false,
                allow_stock_market: false,
                allow_lottery: false,
                allow_card_system: false,
            },
        };

        let pack = ContentPack::new("p1", "1.0.0").add_map(map);
        catalog.register(pack).unwrap();

        let found = catalog.find_map("map1");
        assert!(found.is_some());
        let (pack_id, map) = found.unwrap();
        assert_eq!(pack_id, "p1");
        assert_eq!(map.id, "map1");
    }

    #[test]
    fn test_default_catalog_empty_root() {
        let catalog = default_content_catalog(Path::new("/tmp/nonexistent_catalog_path"));
        assert!(catalog.is_empty());
    }
}
