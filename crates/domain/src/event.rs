use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::any::Any;

/// Base trait for all events.
///
/// Every event type has a string `event_type` (e.g. `"core:dice_rolled"`)
/// and a `category` ("game" for state mutations, "ui" for Flutter display).
/// The `category` is stored in [`AnyEvent.category`] during serialization so
/// subscribers can distinguish game events from UI events at runtime.
pub trait GameEvent: Send + Sync + 'static {
    fn event_type(&self) -> &'static str;
    fn source(&self) -> &str {
        "core"
    }
    fn as_any(&self) -> &dyn Any;
    /// Returns `"game"`, `"ui"`, or `"plugin"`.
    /// Default is `"game"`; override for UI-only events.
    fn category(&self) -> &'static str {
        "game"
    }
}

/// Marker trait for UI-only events (dialog triggers, etc.).
/// Events implementing this trait should override `category()` to return `"ui"`.
pub trait UIEvent: GameEvent {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AnyEvent {
    Typed {
        event_type: String,
        source: String,
        payload: Box<serde_json::value::RawValue>,
        timestamp: u64,
        category: String,
    },
    Custom {
        event_type: String,
        source: String,
        payload: serde_json::Value,
        timestamp: u64,
        category: String,
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
            category: event.category().to_string(),
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

    pub fn category(&self) -> &str {
        match self {
            AnyEvent::Typed { category, .. } => category,
            AnyEvent::Custom { category, .. } => category,
        }
    }

    pub fn is_game(&self) -> bool { self.category() == "game" }
    pub fn is_ui(&self) -> bool { self.category() == "ui" }
}

pub fn timestamp_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
