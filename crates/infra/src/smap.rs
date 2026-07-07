use std::collections::HashMap;
use std::io::{Cursor, Read};
use std::path::Path;

use zip::ZipArchive;

use crate::map::MapDefinition;

// ============================================================================
// .smap loader – extracts map data from ZIP packages
//
// Format:
//   classic.smap
//   ├── map.json              # Map definition (required)
//   ├── thumbnail.png         # Thumbnail image (optional)
//   ├── lang/
//   │   ├── zh.json           # Chinese translations (optional)
//   │   ├── en.json           # English translations (optional)
//   │   └── ...               # Other locales
//   └── rules.json            # Custom rules override (optional)
// ============================================================================

/// Result of loading a .smap file.
#[derive(Debug)]
pub struct SmapResult {
    pub definition: MapDefinition,
    pub thumbnail_png: Option<Vec<u8>>,
    /// Locale-specific translations from `lang/*.json`.
    /// Key = locale code (e.g. "zh", "en"), value = name_key → display name.
    pub localizations: HashMap<String, HashMap<String, String>>,
    /// Plugins extracted from the plugins/ directory inside the .smap
    pub plugins: HashMap<String, Vec<u8>>, // plugin_id → raw bytes
}

/// Load a .smap file from a file path.
pub fn load_smap(path: &Path) -> Result<SmapResult, String> {
    let file =
        std::fs::read(path).map_err(|e| format!("Failed to read {}: {}", path.display(), e))?;
    parse_smap_bytes(&file, &path.display().to_string())
}

/// Load a .smap from raw bytes (e.g. embedded or network).
pub fn parse_smap_bytes(bytes: &[u8], source: &str) -> Result<SmapResult, String> {
    let cursor = Cursor::new(bytes);
    let mut archive =
        ZipArchive::new(cursor).map_err(|e| format!("{}: invalid ZIP: {}", source, e))?;

    // ── Extract map.json (required) ───────────────────────────────────────
    let map_json = read_entry_by_name(&mut archive, "map.json")
        .ok_or_else(|| format!("{}: missing required entry 'map.json'", source))?;
    let mut definition: MapDefinition = serde_json::from_slice(&map_json)
        .map_err(|e| format!("{}: invalid map.json: {}", source, e))?;

    // ── Extract thumbnail.png (optional) ──────────────────────────────────
    let thumbnail_png = read_entry_by_name(&mut archive, "thumbnail.png");

    // ── Extract lang/*.json files (optional) ──────────────────────────────
    let localizations = extract_localizations(&mut archive);

    // ── Extract plugins/ directory entries (optional) ─────────────────────
    let plugins = extract_plugins(&mut archive);

    // ── Populate bundled_data for plugin refs with source == Bundled ──────
    for plugin_ref in &mut definition.plugins {
        if plugin_ref.source == crate::map::MapPluginSource::Bundled {
            if let Some(data) = plugins.get(&plugin_ref.id) {
                plugin_ref.bundled_data = Some(data.clone());
            }
        }
    }

    Ok(SmapResult {
        definition,
        thumbnail_png,
        localizations,
        plugins,
    })
}

/// Extract all `lang/*.json` files from the archive.
fn extract_localizations(
    archive: &mut ZipArchive<Cursor<&[u8]>>,
) -> HashMap<String, HashMap<String, String>> {
    let mut result = HashMap::new();

    for i in 0..archive.len() {
        let (name, data) = match get_entry_name_and_data(archive, i) {
            Some(v) => v,
            None => continue,
        };

        // Match lang/*.json
        if !name.starts_with("lang/") && !name.starts_with("lang\\") {
            continue;
        }
        if !name.ends_with(".json") {
            continue;
        }

        // Extract locale code: "lang/zh.json" → "zh"
        let locale = name
            .trim_start_matches("lang/")
            .trim_start_matches("lang\\")
            .trim_end_matches(".json")
            .to_string();

        // Parse JSON
        if let Ok(parsed) = serde_json::from_slice::<HashMap<String, String>>(&data) {
            result.insert(locale, parsed);
        }
    }

    result
}

/// Extract all plugin files from the `plugins/` directory inside the archive.
fn extract_plugins(
    archive: &mut ZipArchive<Cursor<&[u8]>>,
) -> HashMap<String, Vec<u8>> {
    let mut plugins = HashMap::new();
    for i in 0..archive.len() {
        let mut entry = match archive.by_index(i) {
            Ok(e) => e,
            Err(_) => continue,
        };
        let name = entry.name().to_string();
        if !name.starts_with("plugins/") || name.ends_with('/') {
            continue;
        }
        let plugin_id = name.trim_start_matches("plugins/").to_string();
        let mut data = Vec::new();
        if entry.read_to_end(&mut data).is_ok() {
            plugins.insert(plugin_id, data);
        }
    }
    plugins
}

/// Get the name and data of an entry at a given index.
fn get_entry_name_and_data(
    archive: &mut ZipArchive<Cursor<&[u8]>>,
    index: usize,
) -> Option<(String, Vec<u8>)> {
    let mut entry = archive.by_index(index).ok()?;
    let name = entry.name().to_string();
    let mut buf = Vec::new();
    entry.read_to_end(&mut buf).ok()?;
    Some((name, buf))
}

/// Find and read an entry by name (exact or suffix match).
/// Uses a two-pass approach to avoid overlapping mutable borrows.
fn read_entry_by_name(archive: &mut ZipArchive<Cursor<&[u8]>>, name: &str) -> Option<Vec<u8>> {
    // Pass 1: find the index
    let mut target_idx: Option<usize> = None;
    for i in 0..archive.len() {
        if let Ok(file) = archive.by_index(i) {
            let fname = file.name().to_string();
            if fname == name || fname.ends_with(&format!("/{}", name)) {
                target_idx = Some(i);
                break;
            }
        }
    }

    // Pass 2: read the data
    let idx = target_idx?;
    let mut entry = archive.by_index(idx).ok()?;
    let mut buf = Vec::new();
    entry.read_to_end(&mut buf).ok()?;
    Some(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_load_invalid_zip() {
        let result = parse_smap_bytes(b"not a zip file", "test");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("invalid ZIP"));
    }
}
