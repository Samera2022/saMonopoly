use std::collections::HashSet;
use std::sync::Arc;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use sa_monopoly_domain::GameState;
use sa_monopoly_domain::event::AnyEvent as DomainAnyEvent;
use crate::command_handler::CommandHandlerRegistry;
use crate::tile_behavior::TileBehaviorRegistry;
use crate::ports::RngService;

// ---------------------------------------------------------------------------
// 2.1 AnyEvent
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnyEvent {
    pub event_type: String,
    pub source: String,
    pub payload: serde_json::Value,
    pub timestamp: u64,
}

impl AnyEvent {
    pub fn new(event_type: &str, source: &str, payload: serde_json::Value) -> Self {
        Self {
            event_type: event_type.to_string(),
            source: source.to_string(),
            payload,
            timestamp: timestamp_now(),
        }
    }

    pub fn event_type(&self) -> &str {
        &self.event_type
    }

    pub fn source(&self) -> &str {
        &self.source
    }
}

fn timestamp_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

// ---------------------------------------------------------------------------
// 2.2 SubscriberPriority
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum SubscriberPriority {
    First = 0,
    Early = 1,
    Normal = 2,
    Late = 3,
    Last = 4,
}

// ---------------------------------------------------------------------------
// 2.3 EventAction
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub enum EventAction {
    Continue,
    Consume,
    Modify(AnyEvent),
}

// ---------------------------------------------------------------------------
// 2.4 EventSubscriber (sync)
// ---------------------------------------------------------------------------

pub trait EventSubscriber: Send + Sync {
    fn id(&self) -> &str;
    fn interested_types(&self) -> Vec<&'static str> {
        Vec::new()
    }
    fn priority(&self) -> SubscriberPriority {
        SubscriberPriority::Last
    }
    fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction;
}

// ---------------------------------------------------------------------------
// 2.5 AsyncEventSubscriber
// ---------------------------------------------------------------------------

#[async_trait]
pub trait AsyncEventSubscriber: Send + Sync {
    fn id(&self) -> &str;
    fn interested_types(&self) -> Vec<&'static str> {
        Vec::new()
    }
    fn priority(&self) -> SubscriberPriority {
        SubscriberPriority::Last
    }
    async fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction;
}

// ---------------------------------------------------------------------------
// 2.6 EventMiddleware
// ---------------------------------------------------------------------------

pub trait EventMiddleware: Send + Sync {
    fn id(&self) -> &str;
    fn process(&mut self, event: AnyEvent) -> Option<AnyEvent>;
}

// ---------------------------------------------------------------------------
// 2.7 LoggingMiddleware
// ---------------------------------------------------------------------------

pub struct LoggingMiddleware;

impl EventMiddleware for LoggingMiddleware {
    fn id(&self) -> &str {
        "core.logger"
    }

    fn process(&mut self, event: AnyEvent) -> Option<AnyEvent> {
        log::info!("[EVENT] {} from {}", event.event_type(), event.source());
        Some(event)
    }
}

// ---------------------------------------------------------------------------
// 2.8 FilterMiddleware
// ---------------------------------------------------------------------------

pub struct FilterMiddleware {
    allowed_types: HashSet<String>,
}

impl FilterMiddleware {
    pub fn new(allowed_types: HashSet<String>) -> Self {
        Self { allowed_types }
    }
}

impl EventMiddleware for FilterMiddleware {
    fn id(&self) -> &str {
        "filter"
    }

    fn process(&mut self, event: AnyEvent) -> Option<AnyEvent> {
        if self.allowed_types.contains(event.event_type()) {
            Some(event)
        } else {
            None
        }
    }
}

// ---------------------------------------------------------------------------
// Internal subscriber entries
// ---------------------------------------------------------------------------

pub(crate) struct SubscriberEntry {
    subscriber: Box<dyn EventSubscriber>,
    priority: SubscriberPriority,
    registered_at: usize,
}

pub(crate) struct AsyncSubscriberEntry {
    /// Wrapped in Arc<Mutex<..>> so that we can cheaply clone the Arc
    /// into a tokio::spawn task while keeping the original in the registry.
    subscriber: Arc<Mutex<Box<dyn AsyncEventSubscriber>>>,
    priority: SubscriberPriority,
    registered_at: usize,
}

// ---------------------------------------------------------------------------
// 2.9 EventBus — the central engine hub
// ---------------------------------------------------------------------------

pub struct EventBus {
    pub middlewares: Vec<Box<dyn EventMiddleware>>,
    pub(crate) subscribers: Vec<SubscriberEntry>,
    pub(crate) async_subscribers: Vec<AsyncSubscriberEntry>,
    pub command_handlers: CommandHandlerRegistry,
    pub tile_behaviors: TileBehaviorRegistry,
    sorted: bool,
    custom_events: Vec<AnyEvent>,
}

impl EventBus {
    pub fn new() -> Self {
        Self {
            middlewares: Vec::new(),
            subscribers: Vec::new(),
            async_subscribers: Vec::new(),
            command_handlers: CommandHandlerRegistry::new(),
            tile_behaviors: TileBehaviorRegistry::new(),
            sorted: true,
            custom_events: Vec::new(),
        }
    }

    pub fn add_middleware(&mut self, m: Box<dyn EventMiddleware>) {
        self.middlewares.push(m);
    }

    pub fn subscribe(&mut self, sub: Box<dyn EventSubscriber>) {
        let priority = sub.priority();
        let registered_at = self.subscribers.len();
        self.subscribers.push(SubscriberEntry {
            subscriber: sub,
            priority,
            registered_at,
        });
        self.sorted = false;
    }

    pub fn subscribe_async(&mut self, sub: Box<dyn AsyncEventSubscriber>) {
        let priority = sub.priority();
        let registered_at = self.async_subscribers.len();
        self.async_subscribers.push(AsyncSubscriberEntry {
            subscriber: Arc::new(Mutex::new(sub)),
            priority,
            registered_at,
        });
        self.sorted = false;
    }

    pub fn unsubscribe(&mut self, id: &str) {
        self.subscribers.retain(|e| e.subscriber.id() != id);
        self.async_subscribers.retain(|e| {
            e.subscriber
                .try_lock()
                .map(|guard| guard.id() != id)
                .unwrap_or(true)
        });
    }

    // ─── Core game loop entry points ───

    /// Execute a command via the CommandHandlerRegistry
    pub fn execute_command(
        &mut self,
        command: DomainAnyEvent,
        state: &mut GameState,
        rng: &mut dyn RngService,
    ) {
        let command_type = command.event_type().to_string();
        // Use a raw pointer to split borrows: command_handlers (mutable)
        // and self (mutable for the bus parameter) are different fields.
        let handlers_ptr: *mut CommandHandlerRegistry = &mut self.command_handlers;
        // SAFETY: command_handlers is the only field mutated through dispatch().
        // The &mut self passed as bus does not alias command_handlers.
        let dispatched = unsafe {
            (*handlers_ptr).dispatch(&command_type, state, command, rng, self)
        };
        if !dispatched {
            self.publish_error(&format!("unknown command: {command_type}"), state);
        }
    }

    /// Resolve a tile landing via the TileBehaviorRegistry
    pub fn resolve_tile(
        &mut self,
        tile_type: &str,
        state: &mut GameState,
        tile_id: &str,
        rng: &mut dyn RngService,
    ) {
        // Use a raw pointer to split borrows: tile_behaviors (read-only)
        // and self (mutable for the bus parameter) are different fields.
        let behaviors_ptr: *const TileBehaviorRegistry = &self.tile_behaviors;
        // SAFETY: tile_behaviors is not mutated during execute() — it only reads
        // the registry. The &mut self passed as bus does not alias tile_behaviors.
        let executed = unsafe { (*behaviors_ptr).execute(tile_type, state, tile_id, rng, self) };
        if !executed {
            log::warn!("No behavior registered for tile type: {tile_type}");
        }
    }

    // ─── Event publishing ───

    /// Publish a custom (ad-hoc) event with arbitrary JSON payload
    pub fn publish_custom(
        &mut self,
        event_type: &str,
        source: &str,
        payload: serde_json::Value,
        state: &GameState,
    ) {
        let event = AnyEvent {
            event_type: event_type.to_string(),
            source: source.to_string(),
            payload,
            timestamp: timestamp_now(),
        };
        self.publish_any(event, state);
    }

    /// Publish an error as a custom "core:error" event
    pub fn publish_error(&mut self, reason: &str, state: &GameState) {
        self.publish_custom(
            "core:error",
            "core",
            serde_json::json!({ "reason": reason }),
            state,
        );
    }

    /// Publish a pre-constructed AnyEvent
    pub fn publish_any(&mut self, event: AnyEvent, state: &GameState) {
        self.publish_internal(event, state);
    }

    // ─── Internal dispatch ───

    fn publish_internal(&mut self, event: AnyEvent, state: &GameState) {
        // 1. Middleware chain
        let mut event = Some(event);
        for m in &mut self.middlewares {
            if let Some(e) = event.take() {
                event = m.process(e);
            } else {
                return;
            }
        }

        let Some(event) = event else {
            return;
        };

        // 2. Collect events for bridge response
        self.custom_events.push(event.clone());

        // 3. Sort subscribers by priority (stable sort preserves registration order)
        if !self.sorted {
            self.subscribers.sort_by_key(|e| (e.priority, e.registered_at));
            self.async_subscribers
                .sort_by_key(|e| (e.priority, e.registered_at));
            self.sorted = true;
        }

        // 4. Dispatch to sync subscribers with interested_types filtering
        for entry in &mut self.subscribers {
            let types = entry.subscriber.interested_types();
            if !types.is_empty() && !types.contains(&event.event_type.as_str()) {
                continue;
            }
            match entry.subscriber.on_event(&event, state) {
                EventAction::Continue => {}
                EventAction::Consume => break,
                EventAction::Modify(_) => break,
            }
        }

        // 5. Dispatch to async subscribers (fire-and-forget)
        for entry in &self.async_subscribers {
            let sub_arc = Arc::clone(&entry.subscriber);
            let event = event.clone();
            let state = state.clone();
            tokio::spawn(async move {
                let mut guard = sub_arc.lock().await;
                guard.on_event(&event, &state).await;
            });
        }
    }

    /// Drain collected custom events (used by bridge to flush response queue)
    pub fn drain_custom_events(&mut self) -> Vec<AnyEvent> {
        std::mem::take(&mut self.custom_events)
    }
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new()
    }
}
