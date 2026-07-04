use std::fs;
use std::path::PathBuf;

pub trait SaveStore {
    fn save(&self, key: &str, data: &[u8]) -> Result<(), String>;
    fn load(&self, key: &str) -> Result<Vec<u8>, String>;
}

#[derive(Default)]
pub struct MemorySaveStore {
    #[allow(dead_code)]
    data: std::collections::HashMap<String, Vec<u8>>,
}

impl MemorySaveStore {
    pub fn new() -> Self {
        Self {
            data: std::collections::HashMap::new(),
        }
    }
}

impl SaveStore for MemorySaveStore {
    fn save(&self, _key: &str, _data: &[u8]) -> Result<(), String> {
        Ok(())
    }

    fn load(&self, _key: &str) -> Result<Vec<u8>, String> {
        Ok(Vec::new())
    }
}

pub struct FileSaveStore {
    root: PathBuf,
}

impl FileSaveStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    fn path_for(&self, key: &str) -> PathBuf {
        self.root.join(format!("{key}.sav"))
    }
}

impl SaveStore for FileSaveStore {
    fn save(&self, key: &str, data: &[u8]) -> Result<(), String> {
        fs::create_dir_all(&self.root).map_err(|err| err.to_string())?;
        fs::write(self.path_for(key), data).map_err(|err| err.to_string())
    }

    fn load(&self, key: &str) -> Result<Vec<u8>, String> {
        fs::read(self.path_for(key)).map_err(|err| err.to_string())
    }
}
