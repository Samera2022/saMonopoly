#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventResult {
    Default,
    Allow,
    Deny,
}

#[derive(Debug, Clone)]
pub struct CancellableEvent {
    pub event_type: String,
    pub source: String,
    pub payload: serde_json::Value,
    canceled: bool,
    result: EventResult,
}

impl CancellableEvent {
    pub fn new(event_type: &str, source: &str, payload: serde_json::Value) -> Self {
        Self {
            event_type: event_type.to_string(),
            source: source.to_string(),
            payload,
            canceled: false,
            result: EventResult::Default,
        }
    }

    pub fn set_canceled(&mut self, canceled: bool) {
        self.canceled = canceled;
    }

    pub fn is_canceled(&self) -> bool {
        self.canceled
    }

    pub fn set_result(&mut self, result: EventResult) {
        self.result = result;
    }

    pub fn get_result(&self) -> EventResult {
        self.result
    }
}
