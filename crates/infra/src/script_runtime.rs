use std::collections::HashMap;

use crate::scripting::{ScriptEngineKind, ScriptHost, SimpleScriptHost};

/// A runtime environment for executing scripts with access to game state.
///
/// By default it uses [`SimpleScriptHost`] (a pure‑Rust evaluator), but it can
/// be configured to use any [`ScriptHost`] implementation.
pub struct ScriptRuntime {
    host: Box<dyn ScriptHost>,
}

impl ScriptRuntime {
    /// Create a new runtime backed by the given script host.
    pub fn new(host: Box<dyn ScriptHost>) -> Self {
        Self { host }
    }

    /// Create a runtime that uses the built‑in [`SimpleScriptHost`].
    pub fn with_simple_host() -> Self {
        Self {
            host: Box::new(SimpleScriptHost::new()),
        }
    }

    /// Execute a script in the given language.
    pub fn execute(&self, kind: ScriptEngineKind, source: &str) -> Result<(), String> {
        self.host.run(kind, source)
    }

    /// Evaluate an expression with a variable context and return an integer.
    pub fn eval(&self, expr: &str, context: &HashMap<String, i64>) -> Result<i64, String> {
        self.host.eval_expression(expr, context)
    }

    /// Register a named function that scripts can call.
    pub fn register_function(&mut self, name: &str, func: Box<dyn Fn(&[i64]) -> i64>) {
        self.host.register_function(name, func);
    }

    /// Return a reference to the inner host (for direct access if needed).
    pub fn host(&self) -> &dyn ScriptHost {
        self.host.as_ref()
    }
}

impl Default for ScriptRuntime {
    fn default() -> Self {
        Self::with_simple_host()
    }
}

// ---------------------------------------------------------------------------
// InlineScriptHost – kept for backward compatibility
// ---------------------------------------------------------------------------

pub struct InlineScriptHost;

impl ScriptHost for InlineScriptHost {
    fn run(&self, _kind: ScriptEngineKind, source: &str) -> Result<(), String> {
        if source.trim().is_empty() {
            Err("script source is empty".to_string())
        } else {
            Ok(())
        }
    }

    fn eval_expression(&self, _expr: &str, _context: &HashMap<String, i64>) -> Result<i64, String> {
        Err("InlineScriptHost does not support eval_expression".to_string())
    }

    fn register_function(&mut self, _name: &str, _func: Box<dyn Fn(&[i64]) -> i64>) {
        // no-op
    }
}

// ===========================================================================
// Game-context helpers
// ===========================================================================

/// Convenience helper that builds a variable context from game-state-like
/// key/value pairs and evaluates an expression against it.
pub fn eval_with_state(
    rt: &ScriptRuntime,
    expr: &str,
    state: &[(&str, i64)],
) -> Result<i64, String> {
    let ctx: HashMap<String, i64> = state.iter().map(|(k, v)| (k.to_string(), *v)).collect();
    rt.eval(expr, &ctx)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_runtime_with_simple_host() {
        let rt = ScriptRuntime::with_simple_host();
        let mut ctx = HashMap::new();
        ctx.insert("money".to_string(), 150);
        assert_eq!(rt.eval("{money} + 50", &ctx).unwrap(), 200);
    }

    #[test]
    fn test_eval_with_state_helper() {
        let rt = ScriptRuntime::with_simple_host();
        let result = eval_with_state(
            &rt,
            "{players} * 100 + {turn}",
            &[("players", 4), ("turn", 3)],
        )
        .unwrap();
        assert_eq!(result, 403);
    }

    #[test]
    fn test_register_function() {
        let mut rt = ScriptRuntime::with_simple_host();
        rt.register_function("square", Box::new(|args| args[0] * args[0]));
        let ctx = HashMap::new();
        assert_eq!(rt.eval("square(7)", &ctx).unwrap(), 49);
    }
}
