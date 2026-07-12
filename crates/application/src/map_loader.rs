//! Map loading utilities for FFI.
//!
//! These functions load map data (.smap and .json) without depending on the
//! `sa-monopoly-infra` crate, avoiding a circular dependency
//! (infra already depends on application).

use std::io::{Cursor, Read};
use std::path::Path;

use sa_monopoly_domain::map::MapDefinition;

/// Result of loading a .smap file (subset of infra's SmapResult).
pub struct LoadedSmap {
    pub definition: MapDefinition,
    pub thumbnail_png: Option<Vec<u8>>,
}

/// Load a map from a file path. Supports both .smap (ZIP) and .json formats.
pub fn load_map_from_path(path: &Path) -> Result<MapDefinition, String> {
    let path_str = path.to_string_lossy();
    if path_str.ends_with(".smap") {
        let smap = load_smap(path)?;
        Ok(smap.definition)
    } else {
        let content =
            std::fs::read_to_string(path).map_err(|e| format!("Failed to read file: {e}"))?;
        let definition: MapDefinition =
            serde_json::from_str(&content).map_err(|e| format!("Invalid JSON: {e}"))?;
        Ok(definition)
    }
}

/// Load a .smap file and return its contents.
pub fn load_smap(path: &Path) -> Result<LoadedSmap, String> {
    let bytes =
        std::fs::read(path).map_err(|e| format!("Failed to read {}: {}", path.display(), e))?;
    parse_smap_bytes(&bytes)
}

/// Parse a .smap (ZIP archive) from raw bytes.
pub fn parse_smap_bytes(bytes: &[u8]) -> Result<LoadedSmap, String> {
    let cursor = Cursor::new(bytes);
    let mut archive =
        zip::ZipArchive::new(cursor).map_err(|e| format!("Invalid ZIP archive: {e}"))?;

    // Extract map.json (required)
    let map_json = read_entry(&mut archive, "map.json")
        .ok_or_else(|| "Missing required entry 'map.json'".to_string())?;
    let definition: MapDefinition = serde_json::from_slice(&map_json)
        .map_err(|e| format!("Invalid map.json: {e}"))?;

    // Extract thumbnail.png (optional)
    let thumbnail_png = read_entry(&mut archive, "thumbnail.png");

    Ok(LoadedSmap {
        definition,
        thumbnail_png,
    })
}

/// Read a named entry from a ZIP archive.
fn read_entry<R: Read + std::io::Seek>(
    archive: &mut zip::ZipArchive<R>,
    name: &str,
) -> Option<Vec<u8>> {
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).ok()?;
        let entry_name = entry.name().to_string();
        if entry_name == name || entry_name.ends_with(&format!("/{name}")) {
            let mut buf = Vec::new();
            entry.read_to_end(&mut buf).ok()?;
            return Some(buf);
        }
    }
    None
}

/// Scan a directory for map files (.smap and .json).
pub fn scan_maps_in_dir(path: &Path) -> Vec<serde_json::Value> {
    let mut maps = Vec::new();
    if !path.exists() {
        return maps;
    }
    if let Ok(entries) = std::fs::read_dir(path) {
        for entry in entries.flatten() {
            let p = entry.path();
            let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("");
            if ext == "smap" || ext == "json" {
                if let Some(name) = p.file_stem().and_then(|n| n.to_str()) {
                    maps.push(serde_json::json!({
                        "id": name,
                        "path": p.to_string_lossy(),
                        "format": ext,
                    }));
                }
            }
        }
    }
    maps
}

/// Load thumbnail PNG bytes from a .smap file.
pub fn load_thumbnail(path: &Path) -> Result<Vec<u8>, String> {
    let bytes =
        std::fs::read(path).map_err(|e| format!("Failed to read {}: {}", path.display(), e))?;
    let cursor = Cursor::new(bytes);
    let mut archive =
        zip::ZipArchive::new(cursor).map_err(|e| format!("Invalid ZIP archive: {e}"))?;
    read_entry(&mut archive, "thumbnail.png")
        .ok_or_else(|| "No thumbnail found in .smap".to_string())
}
