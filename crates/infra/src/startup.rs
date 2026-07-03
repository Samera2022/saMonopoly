use crate::content::{ContentLoader, JsonContentLoader};
use crate::map::{BasicMapValidator, MapDefinition, MapValidator};

pub struct StartupPipeline;

impl StartupPipeline {
    pub fn load_and_validate_pack(input: &str) -> Result<Vec<MapDefinition>, Vec<String>> {
        let loader = JsonContentLoader;
        let pack = loader.load_json(input).map_err(|err| vec![err])?;
        let validator = BasicMapValidator;

        let mut errors = Vec::new();
        for map in &pack.maps {
            if let Err(mut map_errors) = validator.validate(map) {
                errors.append(&mut map_errors);
            }
        }

        if errors.is_empty() {
            Ok(pack.maps)
        } else {
            Err(errors)
        }
    }
}
