use std::fs;
use std::path::{Path, PathBuf};

// ============================================================================
// Plugin discovery
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginDescriptor {
    pub id: String,
    pub version: String,
    pub path: PathBuf,
}

pub trait PluginDiscovery {
    fn discover(&self, root: &Path) -> Result<Vec<PluginDescriptor>, String>;
}

pub struct FileSystemPluginDiscovery;

impl PluginDiscovery for FileSystemPluginDiscovery {
    fn discover(&self, root: &Path) -> Result<Vec<PluginDescriptor>, String> {
        let mut descriptors = Vec::new();
        if !root.exists() {
            return Ok(descriptors);
        }

        for entry in fs::read_dir(root).map_err(|err| err.to_string())? {
            let entry = entry.map_err(|err| err.to_string())?;
            let path = entry.path();
            if path.is_dir() {
                let id = path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or("unknown")
                    .to_string();
                descriptors.push(PluginDescriptor {
                    id,
                    version: "0.1.0".to_string(),
                    path,
                });
            }
        }

        Ok(descriptors)
    }
}

// ============================================================================
// Content pack discovery
// ============================================================================

/// Describes a discovered content pack on the file system.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContentPackDescriptor {
    /// Unique identifier for the content pack.
    pub id: String,
    /// Version string.
    pub version: String,
    /// Path to the content pack manifest (JSON) or directory.
    pub path: PathBuf,
    /// Path to the content pack's resource directory (if any).
    pub resource_path: Option<PathBuf>,
}

/// Trait for discovering content packs from a storage location.
pub trait ContentDiscovery {
    fn discover_content(&self, root: &Path) -> Result<Vec<ContentPackDescriptor>, String>;
}

/// File-system based content pack discovery.
///
/// Scans the given root directory for:
/// - `*.pack.json` files (manifests)
/// - Sub-directories containing a `pack.json` or `manifest.json`
pub struct FileSystemContentDiscovery;

impl ContentDiscovery for FileSystemContentDiscovery {
    fn discover_content(&self, root: &Path) -> Result<Vec<ContentPackDescriptor>, String> {
        let mut descriptors = Vec::new();
        if !root.exists() {
            return Ok(descriptors);
        }

        for entry in fs::read_dir(root).map_err(|err| err.to_string())? {
            let entry = entry.map_err(|err| err.to_string())?;
            let path = entry.path();

            if path.is_dir() {
                // Check for manifest files inside the directory
                let manifest_paths = [
                    path.join("pack.json"),
                    path.join("manifest.json"),
                    path.join("content.json"),
                ];

                let mut found = false;
                for manifest_path in &manifest_paths {
                    if manifest_path.exists() {
                        let id = path
                            .file_name()
                            .and_then(|n| n.to_str())
                            .unwrap_or("unknown")
                            .to_string();
                        descriptors.push(ContentPackDescriptor {
                            id,
                            version: "0.1.0".to_string(),
                            path: manifest_path.clone(),
                            resource_path: Some(path.clone()),
                        });
                        found = true;
                        break;
                    }
                }

                // If no manifest found but the directory has a recognizable
                // structure, still add it as a content pack.
                if !found {
                    let id = path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("unknown")
                        .to_string();
                    descriptors.push(ContentPackDescriptor {
                        id,
                        version: "0.1.0".to_string(),
                        path: path.clone(),
                        resource_path: Some(path.clone()),
                    });
                }
            } else if let Some(ext) = path.extension() {
                // Standalone manifest files
                if ext == "json" {
                    if let Some(stem) = path.file_stem() {
                        let name = stem.to_string_lossy().to_string();
                        // Only pick up files that look like pack manifests
                        if name.contains("pack") || name.contains("manifest") || name.contains("content") {
                            descriptors.push(ContentPackDescriptor {
                                id: name,
                                version: "0.1.0".to_string(),
                                path,
                                resource_path: None,
                            });
                        }
                    }
                }
            }
        }

        Ok(descriptors)
    }
}

// ============================================================================
// Build script configuration
// ============================================================================

/// Configuration for a build script that processes content packs at compile
/// time (e.g., embedding assets or generating code).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildScriptConfig {
    /// Whether to enable build-time content embedding.
    pub embed_content: bool,
    /// Directories to scan for content packs during the build.
    pub content_dirs: Vec<PathBuf>,
    /// Output directory for processed content (relative to `OUT_DIR`).
    pub output_dir: PathBuf,
    /// List of pack IDs to exclude from embedding.
    pub exclude_packs: Vec<String>,
}

impl Default for BuildScriptConfig {
    fn default() -> Self {
        Self {
            embed_content: false,
            content_dirs: vec![PathBuf::from("content/packs")],
            output_dir: PathBuf::from("content"),
            exclude_packs: Vec::new(),
        }
    }
}

impl BuildScriptConfig {
    /// Create a configuration that embeds all discovered content packs.
    pub fn embed_all() -> Self {
        Self {
            embed_content: true,
            ..Default::default()
        }
    }

    /// Add a content directory to scan.
    pub fn with_content_dir(mut self, dir: &str) -> Self {
        self.content_dirs.push(PathBuf::from(dir));
        self
    }
}

// ============================================================================
// Helper: discover all content packs and plugins from common roots
// ============================================================================

/// Result of a combined discovery scan.
pub struct DiscoveryResult {
    pub plugins: Vec<PluginDescriptor>,
    pub content_packs: Vec<ContentPackDescriptor>,
}

/// Discover both plugins and content packs from the standard project layout.
///
/// By default scans:
/// - `content/packs/` for content packs
/// - `plugins/` for plugins
pub fn discover_all(project_root: &Path) -> Result<DiscoveryResult, String> {
    let plugin_root = project_root.join("plugins");
    let content_root = project_root.join("content").join("packs");

    let plugin_discovery = FileSystemPluginDiscovery;
    let content_discovery = FileSystemContentDiscovery;

    let plugins = plugin_discovery.discover(&plugin_root).unwrap_or_default();
    let content_packs = content_discovery.discover_content(&content_root).unwrap_or_default();

    Ok(DiscoveryResult {
        plugins,
        content_packs,
    })
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_discover_plugins_nonexistent_root() {
        let discovery = FileSystemPluginDiscovery;
        let result = discovery.discover(Path::new("/tmp/nonexistent_path_12345"));
        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
    }

    #[test]
    fn test_discover_content_nonexistent_root() {
        let discovery = FileSystemContentDiscovery;
        let result = discovery.discover_content(Path::new("/tmp/nonexistent_path_12345"));
        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
    }

    #[test]
    fn test_build_script_config_default() {
        let config = BuildScriptConfig::default();
        assert!(!config.embed_content);
        assert_eq!(config.content_dirs.len(), 1);
        assert_eq!(config.content_dirs[0], PathBuf::from("content/packs"));
    }

    #[test]
    fn test_build_script_config_embed_all() {
        let config = BuildScriptConfig::embed_all();
        assert!(config.embed_content);
    }

    #[test]
    fn test_build_script_config_with_content_dir() {
        let config = BuildScriptConfig::default().with_content_dir("custom/packs");
        assert_eq!(config.content_dirs.len(), 2);
    }

    #[test]
    fn test_discover_all_nonexistent() {
        let result = discover_all(Path::new("/tmp/nonexistent_root_xyz"));
        assert!(result.is_ok());
        let res = result.unwrap();
        assert!(res.plugins.is_empty());
        assert!(res.content_packs.is_empty());
    }

    #[test]
    fn test_content_pack_descriptor_equality() {
        let a = ContentPackDescriptor {
            id: "test".to_string(),
            version: "1.0.0".to_string(),
            path: PathBuf::from("/a/b"),
            resource_path: None,
        };
        let b = ContentPackDescriptor {
            id: "test".to_string(),
            version: "1.0.0".to_string(),
            path: PathBuf::from("/a/b"),
            resource_path: None,
        };
        assert_eq!(a, b);
    }
}
