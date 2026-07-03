use crate::bridge::{BridgeRequest, EngineBridge};

pub struct NativeBridge;

impl NativeBridge {
    pub fn execute_json(input: &str) -> Result<String, String> {
        EngineBridge::execute_json(input)
    }

    pub fn execute_request(request: BridgeRequest) -> String {
        let response = EngineBridge::execute(request);
        serde_json::to_string_pretty(&response).unwrap_or_else(|err| format!(r#"{{"error":"{}"}}"#, err))
    }
}
