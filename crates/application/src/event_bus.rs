use std::collections::HashSet;
use std::sync::Arc;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use crate::events::GameEvent;
use sa_monopoly_domain::GameState;

// ---------------------------------------------------------------------------
// 2.1 AnyEvent
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum AnyEvent {
    Core(GameEvent),
    Custom {
        event_type: String,
        source: String,
        payload: serde_json::Value,
        timestamp: u64,
    },
}

impl AnyEvent {
    pub fn event_type(&self) -> &str {
        match self {
            AnyEvent::Core(e) => e.event_type(),
            AnyEvent::Custom { event_type, .. } => event_type.as_str(),
        }
    }

    pub fn source(&self) -> &str {
        match self {
            AnyEvent::Core(_) => "core",
            AnyEvent::Custom { source, .. } => source.as_str(),
        }
    }
}

// ---------------------------------------------------------------------------
// Helper: provide an `event_type()` on `GameEvent` for AnyEvent::event_type()
// ---------------------------------------------------------------------------

impl GameEvent {
    pub fn event_type(&self) -> &'static str {
        match self {
            GameEvent::GameStarted => "game_started",
            GameEvent::CommandAccepted { .. } => "command_accepted",
            GameEvent::CommandRejected { .. } => "command_rejected",
            GameEvent::TurnAdvanced { .. } => "turn_advanced",
            GameEvent::PlayerMoved { .. } => "player_moved",
            GameEvent::PropertyBought { .. } => "property_bought",
            GameEvent::RentPaid { .. } => "rent_paid",
            GameEvent::StateSaved { .. } => "state_saved",
            GameEvent::StateLoaded { .. } => "state_loaded",
            GameEvent::PlayerSentToJail { .. } => "player_sent_to_jail",
            GameEvent::PlayerSentToHospital { .. } => "player_sent_to_hospital",
            GameEvent::PlayerReleasedFromJail { .. } => "player_released_from_jail",
            GameEvent::PlayerReleasedFromHospital { .. } => "player_released_from_hospital",
            GameEvent::CardDrawn { .. } => "card_drawn",
            GameEvent::CardEffectExecuted { .. } => "card_effect_executed",
            GameEvent::LotteryResult { .. } => "lottery_result",
            GameEvent::StockMarketTick { .. } => "stock_market_tick",
            GameEvent::TradeCompleted { .. } => "trade_completed",
            GameEvent::AuctionStarted { .. } => "auction_started",
            GameEvent::AuctionBid { .. } => "auction_bid",
            GameEvent::AuctionWon { .. } => "auction_won",
            GameEvent::AuctionEnded { .. } => "auction_ended",
            GameEvent::PropertyMortgaged { .. } => "property_mortgaged",
            GameEvent::PropertyRedeemed { .. } => "property_redeemed",
            GameEvent::PlayerBankrupt { .. } => "player_bankrupt",
            GameEvent::PlayerEliminated { .. } => "player_eliminated",
            GameEvent::DiceRolled { .. } => "dice_rolled",
            GameEvent::ExtraTurn { .. } => "extra_turn",
            GameEvent::ThreeDoublesToJail { .. } => "three_doubles_to_jail",
            GameEvent::CardShopList { .. } => "card_shop_list",
            GameEvent::CardBought { .. } => "card_bought",
            GameEvent::CardConsumed { .. } => "card_consumed",
            GameEvent::SharesBought { .. } => "shares_bought",
            GameEvent::SharesSold { .. } => "shares_sold",
            GameEvent::GameWon { .. } => "game_won",
            GameEvent::ConfigLoaded { .. } => "config_loaded",
            GameEvent::ConfigUpdated { .. } => "config_updated",
            GameEvent::LotteryAvailable { .. } => "lottery_available",
            GameEvent::LotteryTicketBought { .. } => "lottery_ticket_bought",
            GameEvent::LotteryDrawResult { .. } => "lottery_draw_result",
            GameEvent::CardUsed { .. } => "card_used",
            GameEvent::BailPaid { .. } => "bail_paid",
        }
    }
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
        "logging"
    }

    fn process(&mut self, event: AnyEvent) -> Option<AnyEvent> {
        log::info!(
            "[EventBus] {} from {}",
            event.event_type(),
            event.source()
        );
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
// 2.9 EventBus
// ---------------------------------------------------------------------------

struct SubscriberEntry {
    subscriber: Box<dyn EventSubscriber>,
    priority: SubscriberPriority,
    registered_at: usize,
}

struct AsyncSubscriberEntry {
    /// Wrapped in Arc<Mutex<..>> so that we can cheaply clone the Arc
    /// into a tokio::spawn task while keeping the original in the registry.
    subscriber: Arc<Mutex<Box<dyn AsyncEventSubscriber>>>,
    priority: SubscriberPriority,
    registered_at: usize,
}

pub struct EventBus {
    middlewares: Vec<Box<dyn EventMiddleware>>,
    sync_subscribers: Vec<SubscriberEntry>,
    async_subscribers: Vec<AsyncSubscriberEntry>,
    sorted: bool,
}

impl EventBus {
    pub fn new() -> Self {
        Self {
            middlewares: Vec::new(),
            sync_subscribers: Vec::new(),
            async_subscribers: Vec::new(),
            sorted: false,
        }
    }

    pub fn add_middleware(&mut self, m: Box<dyn EventMiddleware>) {
        self.middlewares.push(m);
    }

    pub fn subscribe(&mut self, sub: Box<dyn EventSubscriber>) {
        let priority = sub.priority();
        let registered_at = self.sync_subscribers.len();
        self.sync_subscribers.push(SubscriberEntry {
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
        self.sync_subscribers.retain(|e| e.subscriber.id() != id);
        self.async_subscribers.retain(|e| {
            // Try to lock briefly to check the id. If the lock is
            // contended we skip removal (subscriber is busy in a task).
            e.subscriber
                .try_lock()
                .map(|guard| guard.id() != id)
                .unwrap_or(true)
        });
    }

    pub fn publish(&mut self, event: GameEvent, state: &GameState) {
        let any_event = AnyEvent::Core(event);
        self.publish_any(any_event, state);
    }

    pub fn publish_custom(
        &mut self,
        event_type: &str,
        source: &str,
        payload: serde_json::Value,
        state: &GameState,
    ) {
        let any_event = AnyEvent::Custom {
            event_type: event_type.to_string(),
            source: source.to_string(),
            payload,
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
        };
        self.publish_any(any_event, state);
    }

    fn publish_any(&mut self, event: AnyEvent, state: &GameState) {
        // --- Middleware chain ---
        let mut event = Some(event);
        for m in &mut self.middlewares {
            if let Some(e) = event.take() {
                event = m.process(e);
            } else {
                // A middleware returned None → event was consumed/dropped
                return;
            }
        }

        let Some(event) = event else {
            return;
        };

        // --- Sort subscribers by priority (stable sort preserves registration order) ---
        if !self.sorted {
            self.sync_subscribers
                .sort_by_key(|e| (e.priority, e.registered_at));
            self.async_subscribers
                .sort_by_key(|e| (e.priority, e.registered_at));
            self.sorted = true;
        }

        // --- Dispatch to sync subscribers ---
        for entry in &mut self.sync_subscribers {
            // Check interested_types before dispatching
            let types = entry.subscriber.interested_types();
            if !types.is_empty() && !types.contains(&event.event_type()) {
                continue;
            }
            let action = entry.subscriber.on_event(&event, state);
            match action {
                EventAction::Continue => {}
                EventAction::Consume => break,
                EventAction::Modify(_modified) => {
                    break;
                }
            }
        }

        // --- Dispatch to async subscribers (fire-and-forget) ---
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
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new()
    }
}
