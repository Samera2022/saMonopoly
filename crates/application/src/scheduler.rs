use sa_monopoly_domain::{PlayerId, TurnNumber};
use serde::{Deserialize, Serialize};

/// The kind of effect to apply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum EffectKind {
    /// Release a player from jail.
    ReleaseFromJail(PlayerId),
    /// Release a player from hospital.
    ReleaseFromHospital(PlayerId),
    /// A stock-market tick event.
    StockMarketTick,
    /// Expiry of a specific card for a player.
    CardExpiry {
        player_id: PlayerId,
        card_id: String,
    },
    /// Periodic interest accrual.
    InterestAccrual,
    /// A custom / catch-all effect.
    Custom(String),
    /// Lottery draw event (fires every 15 turns).
    LotteryDraw,
}

/// A timed effect scheduled to fire at (or after) `trigger_turn`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimedEffect {
    /// Unique identifier for this scheduled effect.
    pub id: String,
    /// The turn number at which this effect should trigger.
    pub trigger_turn: TurnNumber,
    /// The effect payload.
    pub effect: EffectKind,
    /// Whether this effect should be re-scheduled after it fires.
    pub recurring: bool,
    /// Number of turns between recurring triggers.
    /// `None` means the effect fires only once (recurring must be `false` in
    /// that case, but the scheduler does not enforce this invariant).
    pub interval_turns: Option<TurnNumber>,
}

/// A scheduler that manages timed effects.
pub trait Scheduler {
    /// Schedule a new timed effect.
    fn schedule(&mut self, effect: TimedEffect);

    /// Cancel a previously scheduled effect by its `id`.
    fn cancel(&mut self, effect_id: &str);

    /// Advance the scheduler to `current_turn` and return all effects that
    /// should fire on or before this turn.
    fn tick(&mut self, current_turn: TurnNumber) -> Vec<TimedEffect>;
}

/// A simple [`Scheduler`] implementation backed by a [`Vec<TimedEffect>`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct VecScheduler {
    effects: Vec<TimedEffect>,
}

impl Scheduler for VecScheduler {
    fn schedule(&mut self, effect: TimedEffect) {
        self.effects.push(effect);
    }

    fn cancel(&mut self, effect_id: &str) {
        self.effects.retain(|e| e.id != effect_id);
    }

    fn tick(&mut self, current_turn: TurnNumber) -> Vec<TimedEffect> {
        let mut ready = Vec::new();
        let mut remaining = Vec::new();

        for effect in self.effects.drain(..) {
            if effect.trigger_turn <= current_turn {
                ready.push(effect);
            } else {
                remaining.push(effect);
            }
        }

        // Re-schedule recurring effects for their next trigger turn.
        for effect in &ready {
            if effect.recurring {
                if let Some(interval) = effect.interval_turns {
                    let next = TimedEffect {
                        trigger_turn: current_turn + interval,
                        ..effect.clone()
                    };
                    remaining.push(next);
                }
            }
        }

        self.effects = remaining;
        ready
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedule_and_tick_single() {
        let mut sched = VecScheduler::default();
        let effect = TimedEffect {
            id: "e1".into(),
            trigger_turn: 5,
            effect: EffectKind::InterestAccrual,
            recurring: false,
            interval_turns: None,
        };
        sched.schedule(effect);

        let ready = sched.tick(4);
        assert!(ready.is_empty(), "should not fire before trigger_turn");

        let ready = sched.tick(5);
        assert_eq!(ready.len(), 1);
        assert_eq!(ready[0].id, "e1");
    }

    #[test]
    fn cancel_effect() {
        let mut sched = VecScheduler::default();
        sched.schedule(TimedEffect {
            id: "e2".into(),
            trigger_turn: 3,
            effect: EffectKind::StockMarketTick,
            recurring: false,
            interval_turns: None,
        });
        sched.cancel("e2");
        let ready = sched.tick(10);
        assert!(ready.is_empty());
    }

    #[test]
    fn recurring_effect_reschedules() {
        let mut sched = VecScheduler::default();
        sched.schedule(TimedEffect {
            id: "recur".into(),
            trigger_turn: 2,
            effect: EffectKind::InterestAccrual,
            recurring: true,
            interval_turns: Some(3),
        });

        let ready = sched.tick(2);
        assert_eq!(ready.len(), 1);
        assert_eq!(ready[0].id, "recur");

        // After tick(2) the effect should have been re-scheduled for turn 5.
        let ready = sched.tick(4);
        assert!(ready.is_empty(), "re-scheduled effect shouldn't fire at 4");

        let ready = sched.tick(5);
        assert_eq!(ready.len(), 1, "re-scheduled effect should fire at 5");
    }
}
