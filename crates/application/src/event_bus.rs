use std::collections::HashSet;
use std::sync::Arc;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use sa_monopoly_domain::GameState;
use sa_monopoly_domain::event::AnyEvent as DomainAnyEvent;
use sa_monopoly_domain::GameEvent;
use crate::cancellable_event::CancellableEvent;
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

impl AnyEvent {
    /// Deserialize the JSON payload into a typed event struct.
    /// Works for events published via `publish_typed()` since those
    /// embed the full struct data as JSON in `payload`.
    pub fn into_typed<E: serde::de::DeserializeOwned>(self) -> Result<E, serde_json::Error> {
        serde_json::from_value(self.payload)
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
// PreEventAction
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub enum PreEventAction {
    Continue,
    Cancel(String),
    Modify(serde_json::Value),
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
    fn on_event(&mut self, event: &AnyEvent, state: &mut GameState) -> EventAction;
}

// ---------------------------------------------------------------------------
// PreEventHook
// ---------------------------------------------------------------------------

pub trait PreEventHook: Send + Sync {
    fn id(&self) -> &str;
    fn priority(&self) -> SubscriberPriority { SubscriberPriority::Normal }
    fn on_pre_command(&mut self, command_type: &str, payload: &serde_json::Value, state: &GameState) -> PreEventAction;
}

// ---------------------------------------------------------------------------
// PostEventHook
// ---------------------------------------------------------------------------

pub trait PostEventHook: Send + Sync {
    fn id(&self) -> &str;
    fn priority(&self) -> SubscriberPriority { SubscriberPriority::Normal }
    fn on_post_command(&mut self, command_type: &str, state: &GameState, events: &[AnyEvent]);
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
    async fn on_event(&mut self, event: &AnyEvent, state: &mut GameState) -> EventAction;
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
// Hook entries
// ---------------------------------------------------------------------------

pub(crate) struct PreHookEntry {
    pub hook: Box<dyn PreEventHook>,
    pub priority: SubscriberPriority,
    pub registered_at: usize,
}

pub(crate) struct PostHookEntry {
    pub hook: Box<dyn PostEventHook>,
    pub priority: SubscriberPriority,
    pub registered_at: usize,
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
    pub(crate) pre_hooks: Vec<PreHookEntry>,
    pub(crate) post_hooks: Vec<PostHookEntry>,
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
            pre_hooks: Vec::new(),
            post_hooks: Vec::new(),
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

    pub fn register_pre_hook(&mut self, hook: Box<dyn PreEventHook>) {
        let priority = hook.priority();
        self.pre_hooks.push(PreHookEntry { hook, priority, registered_at: self.pre_hooks.len() });
        self.sorted = false;
    }

    pub fn register_post_hook(&mut self, hook: Box<dyn PostEventHook>) {
        let priority = hook.priority();
        self.post_hooks.push(PostHookEntry { hook, priority, registered_at: self.post_hooks.len() });
        self.sorted = false;
    }

    pub fn unregister_pre_hook(&mut self, id: &str) {
        self.pre_hooks.retain(|e| e.hook.id() != id);
    }

    pub fn unregister_post_hook(&mut self, id: &str) {
        self.post_hooks.retain(|e| e.hook.id() != id);
    }

    // ─── Core game loop entry points ───

    /// Execute a command via the CommandHandlerRegistry, with pre/post hook support
    pub fn execute_command(
        &mut self,
        command: DomainAnyEvent,
        state: &mut GameState,
        rng: &mut dyn RngService,
    ) {
        let command_type = command.event_type().to_string();

        // 1. Extract payload for pre-hooks
        let payload = match &command {
            DomainAnyEvent::Typed { payload, .. } => {
                serde_json::from_str(payload.get()).unwrap_or(serde_json::Value::Null)
            }
            DomainAnyEvent::Custom { payload, .. } => payload.clone(),
        };

        // 2. Fire pre-hooks
        let pre_action = self.fire_pre_hooks(&command_type, &payload, state);

        // 3. Handle pre-hook result
        let command = match pre_action {
            PreEventAction::Cancel(reason) => {
                self.publish_custom(
                    "core:command_rejected",
                    "core",
                    serde_json::json!({
                        "reason": reason,
                        "cancelled_by_plugin": true,
                        "command_type": command_type,
                    }),
                    state,
                );
                return;
            }
            PreEventAction::Modify(modified_payload) => {
                // Rebuild as a Custom variant with the modified payload
                DomainAnyEvent::Custom {
                    event_type: command_type.clone(),
                    source: command.source().to_string(),
                    payload: modified_payload,
                    timestamp: sa_monopoly_domain::event::timestamp_now(),
                }
            }
            PreEventAction::Continue => command,
        };

        // 4. Record current event count so we can isolate new events for post-hooks
        let prev_events_len = self.custom_events.len();

        // 5. Dispatch via raw pointer to split borrows (same pattern as before)
        let handlers_ptr: *mut CommandHandlerRegistry = &mut self.command_handlers;
        // SAFETY: command_handlers is the only field mutated through dispatch().
        // The &mut self passed as bus does not alias command_handlers.
        let dispatched = unsafe {
            (*handlers_ptr).dispatch(&command_type, state, command, rng, self)
        };
        if !dispatched {
            self.publish_error(&format!("unknown command: {command_type}"), state);
        }

        // 6. Fire post-hooks with events produced by this command execution
        let new_events: Vec<AnyEvent> = self.custom_events[prev_events_len..].to_vec();
        self.fire_post_hooks(&command_type, state, &new_events);
    }

    // ─── Pre / Post hook helpers ───

    /// Run all pre-hooks for the given command, returning the first non-Continue action.
    /// Hooks are sorted by (priority, registered_at) before execution.
    fn fire_pre_hooks(
        &mut self,
        command_type: &str,
        payload: &serde_json::Value,
        state: &GameState,
    ) -> PreEventAction {
        // Stable sort by priority then registration order
        self.pre_hooks.sort_by_key(|e| (e.priority, e.registered_at));

        for entry in &mut self.pre_hooks {
            let action = entry.hook.on_pre_command(command_type, payload, state);
            match action {
                PreEventAction::Continue => continue,
                other => return other,
            }
        }
        PreEventAction::Continue
    }

    /// Notify all post-hooks about events produced by a completed command.
    /// Hooks are sorted by (priority, registered_at) before execution.
    fn fire_post_hooks(
        &mut self,
        command_type: &str,
        state: &GameState,
        events: &[AnyEvent],
    ) {
        // Stable sort by priority then registration order
        self.post_hooks.sort_by_key(|e| (e.priority, e.registered_at));

        for entry in &mut self.post_hooks {
            entry.hook.on_post_command(command_type, state, events);
        }
    }

    /// 在命令处理器内部触发 Pre-Event 钩子，返回一个 CancellableEvent。
    /// 钩子可以取消事件或修改 payload。
    pub fn fire_command_pre_hook(
        &mut self,
        hook_event_type: &str,
        payload: serde_json::Value,
        state: &GameState,
    ) -> CancellableEvent {
        let mut cancellable = CancellableEvent::new(hook_event_type, "core", payload.clone());
        // 遍历 pre_hooks，让它们检查/修改这个可取消事件
        for entry in &mut self.pre_hooks {
            let action = entry.hook.on_pre_command(hook_event_type, &cancellable.payload, state);
            match action {
                PreEventAction::Cancel(reason) => {
                    cancellable.set_canceled(true);
                    // 将取消原因保存到 payload 中
                    if let serde_json::Value::Object(ref mut map) = cancellable.payload {
                        map.insert("cancel_reason".to_string(), serde_json::Value::String(reason));
                    }
                    break;
                }
                PreEventAction::Modify(modified_payload) => {
                    cancellable.payload = modified_payload;
                }
                PreEventAction::Continue => {}
            }
        }
        cancellable
    }

    /// Resolve a tile landing via the TileBehaviorRegistry
    pub fn resolve_tile(
        &mut self,
        tile_type: &str,
        state: &mut GameState,
        tile_id: &str,
        rng: &mut dyn RngService,
    ) {
        log::info!("[TRACE] resolve_tile called: type='{tile_type}' id='{tile_id}'");
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
        state: &mut GameState,
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
    pub fn publish_error(&mut self, reason: &str, state: &mut GameState) {
        self.publish_custom(
            "core:error",
            "core",
            serde_json::json!({ "reason": reason }),
            state,
        );
    }

    /// Publish a typed event that implements GameEvent + Serialize.
    /// The event is serialized to JSON and published as a custom event.
    pub fn publish_typed<E: GameEvent + Serialize>(
        &mut self,
        event: &E,
        state: &mut GameState,
    ) {
        let payload = serde_json::to_value(event).unwrap_or_default();
        self.publish_custom(event.event_type(), event.source(), payload, state);
    }

    /// Publish a pre-constructed AnyEvent
    pub fn publish_any(&mut self, event: AnyEvent, state: &mut GameState) {
        self.publish_internal(event, state);
    }

    // ─── Internal dispatch ───

    fn publish_internal(&mut self, event: AnyEvent, state: &mut GameState) {
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

        // 2. Collect event for bridge response (clone of original)
        self.custom_events.push(event.clone());

        // 3. Sort subscribers by priority (stable sort preserves registration order)
        if !self.sorted {
            self.subscribers.sort_by_key(|e| (e.priority, e.registered_at));
            self.async_subscribers
                .sort_by_key(|e| (e.priority, e.registered_at));
            self.sorted = true;
        }

        // 4. Clone state for async subscribers before mutable borrow
        let state_clone = state.clone();

        // 5. Dispatch to sync subscribers with interested_types filtering
        //    Track modifications: each Modify chains onto the next subscriber,
        //    and the final modified event replaces the last entry in custom_events.
        let mut modified_event = event;
        let mut was_modified = false;
        for entry in &mut self.subscribers {
            let types = entry.subscriber.interested_types();
            if !types.is_empty() && !types.contains(&modified_event.event_type.as_str()) {
                continue;
            }
            match entry.subscriber.on_event(&modified_event, state) {
                EventAction::Continue => {}
                EventAction::Consume => break,
                EventAction::Modify(modified) => {
                    modified_event = modified;
                    was_modified = true;
                }
            }
        }

        // 5b. If any subscriber modified the event, replace the last entry
        //     in custom_events so the bridge sees the modified version.
        if was_modified {
            if let Some(last) = self.custom_events.last_mut() {
                *last = modified_event.clone();
            }
        }

        // 6. Dispatch to async subscribers (fire-and-forget) with the final event
        for entry in &self.async_subscribers {
            let sub_arc = Arc::clone(&entry.subscriber);
            let event = modified_event.clone();
            let mut state = state_clone.clone();
            tokio::spawn(async move {
                let mut guard = sub_arc.lock().await;
                guard.on_event(&event, &mut state).await;
            });
        }

        // 7. Drain pending events queued by subscribers (e.g. GameLogicHandler)
        //     and re-publish them through the normal event pipeline.
        let pending = std::mem::take(&mut state.pending_events);
        for pe in pending {
            let event = AnyEvent {
                event_type: pe.event_type,
                source: pe.source,
                payload: pe.payload,
                timestamp: timestamp_now(),
            };
            // Bypass middleware and re-entrancy guard by calling publish_internal directly.
            // This ensures pending events are also dispatched to subscribers.
            self.custom_events.push(event.clone());
            // Dispatch to sync subscribers only (avoid re-entrant async dispatch)
            let mut modified = event;
            for entry in &mut self.subscribers {
                let types = entry.subscriber.interested_types();
                if !types.is_empty() && !types.contains(&modified.event_type.as_str()) {
                    continue;
                }
                match entry.subscriber.on_event(&modified, state) {
                    EventAction::Continue => {}
                    EventAction::Consume => break,
                    EventAction::Modify(m) => {
                        modified = m;
                    }
                }
            }
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
