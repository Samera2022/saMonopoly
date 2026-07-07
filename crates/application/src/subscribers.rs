use log;

use crate::bridge::BridgeResponse;
use crate::event_bus::{AnyEvent, EventAction, EventSubscriber, SubscriberPriority};
use crate::events::GameEvent;
use crate::scheduler::Scheduler;
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
        if let AnyEvent::Core(core_event) = event {
            let response = BridgeResponse {
                event: core_event.clone(),
                state: state.clone(),
            };
            let _ = self.bridge_tx.try_send(response);
        }
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

    fn on_event(&mut self, event: &AnyEvent, state: &GameState) -> EventAction {
        if let AnyEvent::Core(GameEvent::TurnAdvanced { turn, .. }) = event {
            let effects = self.scheduler.tick(*turn);
            for effect in effects {
                self.execute_effect(effect, state);
            }
        }
        EventAction::Continue
    }
}
