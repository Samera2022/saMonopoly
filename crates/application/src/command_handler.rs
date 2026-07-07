use std::collections::HashMap;
use sa_monopoly_domain::GameState;
use sa_monopoly_domain::event::AnyEvent;
use crate::event_bus::EventBus;
use crate::ports::RngService;

/// Command handler signature: processes a command event, mutates state, publishes events
pub type CommandHandler = Box<
    dyn FnMut(&mut GameState, AnyEvent, &mut dyn RngService, &mut EventBus) + Send + Sync
>;

/// Registry of command handlers keyed by command type string
pub struct CommandHandlerRegistry {
    handlers: HashMap<String, (CommandHandler, String)>, // (handler, plugin_id)
}

impl CommandHandlerRegistry {
    pub fn new() -> Self {
        Self { handlers: HashMap::new() }
    }

    /// Register a command handler for a specific command type
    pub fn register(
        &mut self,
        command_type: &str,
        plugin_id: &str,
        handler: CommandHandler,
    ) -> Result<(), String> {
        if self.handlers.contains_key(command_type) {
            return Err(format!("command handler '{}' already registered", command_type));
        }
        self.handlers.insert(
            command_type.to_string(),
            (handler, plugin_id.to_string()),
        );
        Ok(())
    }

    /// Remove all handlers registered by a plugin
    pub fn unregister_plugin(&mut self, plugin_id: &str) {
        self.handlers.retain(|_, (_, pid)| pid != plugin_id);
    }

    /// Dispatch a command to its registered handler
    /// Returns true if a handler was found and executed
    pub fn dispatch(
        &mut self,
        command_type: &str,
        state: &mut GameState,
        event: AnyEvent,
        rng: &mut dyn RngService,
        bus: &mut EventBus,
    ) -> bool {
        if let Some((handler, _)) = self.handlers.get_mut(command_type) {
            handler(state, event, rng, bus);
            true
        } else {
            false
        }
    }
}
