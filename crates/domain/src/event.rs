use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::any::Any;

pub trait GameEvent: Send + Sync + 'static {
    fn event_type(&self) -> &'static str;
    fn source(&self) -> &str {
        "core"
    }
    fn as_any(&self) -> &dyn Any;
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AnyEvent {
    Typed {
        event_type: String,
        source: String,
        payload: Box<serde_json::value::RawValue>,
        timestamp: u64,
    },
    Custom {
        event_type: String,
        source: String,
        payload: serde_json::Value,
        timestamp: u64,
    },
}

impl AnyEvent {
    pub fn from_typed<E: GameEvent + Serialize>(event: &E) -> Result<Self, serde_json::Error> {
        let json = serde_json::to_string(event)?;
        let payload = serde_json::value::RawValue::from_string(json)?;
        Ok(AnyEvent::Typed {
            event_type: event.event_type().to_string(),
            source: event.source().to_string(),
            payload,
            timestamp: timestamp_now(),
        })
    }

    pub fn into_typed<E: GameEvent + DeserializeOwned>(self) -> Result<E, serde_json::Error> {
        match self {
            AnyEvent::Typed { payload, .. } => serde_json::from_str(payload.get()),
            AnyEvent::Custom { payload, .. } => serde_json::from_value(payload),
        }
    }

    pub fn event_type(&self) -> &str {
        match self {
            AnyEvent::Typed { event_type, .. } => event_type,
            AnyEvent::Custom { event_type, .. } => event_type,
        }
    }

    pub fn source(&self) -> &str {
        match self {
            AnyEvent::Typed { source, .. } => source,
            AnyEvent::Custom { source, .. } => source,
        }
    }
}

pub fn timestamp_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
