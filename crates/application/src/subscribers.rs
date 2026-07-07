use log;

use crate::bridge::BridgeResponse;
use crate::event_bus::{AnyEvent, EventAction, EventSubscriber, SubscriberPriority};
use sa_monopoly_domain::GameState;

// ---------------------------------------------------------------------------
// BridgeBroadcaster
// ---------------------------------------------------------------------------

pub struct BridgeBroadcaster {
    bridge_tx: tokio::sync::mpsc::Sender<BridgeResponse>,
}

impl BridgeBroadcaster {
    pub fn new(bridge_tx: tokio::sync::mpsc::Sender<BridgeResponse>) -> Self {
        Self { bridge_tx }
    }
}

impl EventSubscriber for BridgeBroadcaster {
    fn id(&self) -> &str {
        "core.bridge"
    }

    fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction {
        // Forward custom events (including domain events wrapped as custom)
        // to the bridge channel as BridgeResponse items
        let event_type = event.event_type().to_string();
        let response = BridgeResponse {
            events: vec![sa_monopoly_domain::event::AnyEvent::Custom {
                event_type,
                source: event.source().to_string(),
                payload: serde_json::json!({}),
                timestamp: 0,
            }],
            state: state.clone(),
        };
        let _ = self.bridge_tx.try_send(response);
        EventAction::Continue
    }
}

// ---------------------------------------------------------------------------
// EventLogger
// ---------------------------------------------------------------------------

pub struct EventLogger;

impl EventSubscriber for EventLogger {
    fn id(&self) -> &str {
        "core.logger"
    }

    fn priority(&self) -> SubscriberPriority {
        SubscriberPriority::Last
    }

    fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction {
        log::info!(
            "[TURN {}] {:?} (players: {})",
            state.current_turn,
            event,
            state.players.len()
        );
        EventAction::Continue
    }
}

// ---------------------------------------------------------------------------
// SchedulerBridge
// ---------------------------------------------------------------------------

pub struct SchedulerBridge {
    pub scheduler: crate::scheduler::VecScheduler,
}

impl SchedulerBridge {
    pub fn new(scheduler: crate::scheduler::VecScheduler) -> Self {
        Self { scheduler }
    }

    #[allow(dead_code)]
    fn execute_effect(
        &mut self,
        effect: crate::scheduler::TimedEffect,
        _state: &GameState,
    ) {
        log::info!("[Scheduler] Executing effect: {:?}", effect);
    }
}

impl EventSubscriber for SchedulerBridge {
    fn id(&self) -> &str {
        "core.scheduler"
    }

    fn interested_types(&self) -> Vec<&'static str> {
        vec!["turn_advanced"]
    }

    fn on_event(&mut self, event: &AnyEvent, _state: &GameState) -> EventAction {
        // Match on event_type string instead of enum variant
        if event.event_type() == "turn_advanced" {
            // Extract turn number from the event
            // For now, use current turn from state since we don't have typed access
            // The scheduler tick will be handled
        }
        EventAction::Continue
    }
}
