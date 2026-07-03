use std::collections::HashMap;

/// Decision produced by an LLM (or stub) client.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LlmDecision {
    pub command_name: String,
    pub rationale: String,
}

/// Core trait for LLM-based decision making.
pub trait LlmClient {
    fn decide(&self, prompt: &str) -> Result<LlmDecision, String>;
}

/// Higher-level agent trait that uses an [`LlmClient`] internally.
pub trait LlmAgent {
    fn decide_turn(&self, context: &str) -> Result<LlmDecision, String>;
}

// ──────────────────────────────────────────────
//  DisabledLlmClient — placeholder / stub
// ──────────────────────────────────────────────

/// A disabled LLM client that always returns an error.
///
/// Useful as a default / fallback when no real LLM back-end is configured.
pub struct DisabledLlmClient;

impl LlmClient for DisabledLlmClient {
    fn decide(&self, prompt: &str) -> Result<LlmDecision, String> {
        Err(format!(
            "LLM integration is not enabled. Received prompt of length {}: {:.60}…",
            prompt.len(),
            prompt
        ))
    }
}

// ──────────────────────────────────────────────
//  ConfigurableLlmClient — stub with canned responses
// ──────────────────────────────────────────────

/// An LLM client stub that returns pre-configured decisions.
///
/// This is useful for:
/// - Integration tests that need deterministic AI behaviour.
/// - Development / demo environments where you want to control exactly
///   which action the "AI" takes without calling an external service.
///
/// Decisions can be loaded from a configuration file, environment variables,
/// or set programmatically.
#[derive(Debug, Clone)]
pub struct ConfigurableLlmClient {
    /// Map of prompt sub-string → canned decision.
    /// The first matching key (by longest match) wins.
    responses: HashMap<String, LlmDecision>,

    /// Default decision returned when no rule matches.
    fallback: LlmDecision,
}

impl ConfigurableLlmClient {
    /// Create a client with the given canned responses and fallback.
    pub fn new(responses: HashMap<String, LlmDecision>, fallback: LlmDecision) -> Self {
        Self { responses, fallback }
    }

    /// Create a client with a single fallback decision (no rules).
    pub fn with_fallback(command_name: &str, rationale: &str) -> Self {
        Self {
            responses: HashMap::new(),
            fallback: LlmDecision {
                command_name: command_name.to_string(),
                rationale: rationale.to_string(),
            },
        }
    }

    /// Add or overwrite a response rule.
    pub fn add_rule(&mut self, key: &str, command_name: &str, rationale: &str) {
        self.responses.insert(
            key.to_string(),
            LlmDecision {
                command_name: command_name.to_string(),
                rationale: rationale.to_string(),
            },
        );
    }
}

impl LlmClient for ConfigurableLlmClient {
    fn decide(&self, prompt: &str) -> Result<LlmDecision, String> {
        // Try to find the longest matching key in the prompt
        let mut best_match: Option<(&String, &LlmDecision)> = None;
        let mut best_len = 0usize;

        for (key, decision) in &self.responses {
            if prompt.contains(key.as_str()) && key.len() > best_len {
                best_match = Some((key, decision));
                best_len = key.len();
            }
        }

        match best_match {
            Some((_key, decision)) => Ok(decision.clone()),
            None => Ok(self.fallback.clone()),
        }
    }
}

// ──────────────────────────────────────────────
//  Helper — build responses from JSON
// ──────────────────────────────────────────────

/// Parse a JSON map of prompt-key → decision values into a [`ConfigurableLlmClient`].
///
/// Expected JSON format:
/// ```json
/// {
///   "rules": {
///     "Roll": { "command_name": "Roll", "rationale": "roll the dice" },
///     "BuyProperty": { "command_name": "BuyProperty", "rationale": "buy" }
///   },
///   "fallback": { "command_name": "EndTurn", "rationale": "default" }
/// }
/// ```
pub fn configurable_client_from_json(json_str: &str) -> Result<ConfigurableLlmClient, String> {
    #[derive(serde::Deserialize)]
    struct RulesFile {
        rules: HashMap<String, LlmDecision>,
        fallback: LlmDecision,
    }

    let parsed: RulesFile =
        serde_json::from_str(json_str).map_err(|e| format!("failed to parse config: {e}"))?;

    Ok(ConfigurableLlmClient::new(parsed.rules, parsed.fallback))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_returns_error() {
        let client = DisabledLlmClient;
        let result = client.decide("roll the dice");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not enabled"));
    }

    #[test]
    fn configurable_fallback() {
        let client = ConfigurableLlmClient::with_fallback("EndTurn", "default action");
        let decision = client.decide("some random prompt").unwrap();
        assert_eq!(decision.command_name, "EndTurn");
    }

    #[test]
    fn configurable_rule_match() {
        let mut client = ConfigurableLlmClient::with_fallback("Roll", "default: roll");
        client.add_rule("BuyProperty", "BuyProperty", "buy it");
        client.add_rule("property", "BuyProperty", "buy property");

        // The prompt contains "BuyProperty" — should match the first rule
        let decision = client
            .decide("I should BuyProperty on this tile")
            .unwrap();
        assert_eq!(decision.command_name, "BuyProperty");
        assert_eq!(decision.rationale, "buy it");
    }

    #[test]
    fn configurable_longest_key_wins() {
        let mut client = ConfigurableLlmClient::with_fallback("EndTurn", "fallback");
        client.add_rule("roll", "Roll", "short match");
        client.add_rule("roll the dice", "Roll", "long match");

        let decision = client.decide("please roll the dice now").unwrap();
        assert_eq!(decision.rationale, "long match");
    }

    #[test]
    fn from_json() {
        let json = r#"{
            "rules": {
                "Roll": { "command_name": "Roll", "rationale": "time to roll" }
            },
            "fallback": { "command_name": "EndTurn", "rationale": "no rule matched" }
        }"#;
        let client = configurable_client_from_json(json).unwrap();
        let d1 = client.decide("Roll").unwrap();
        assert_eq!(d1.command_name, "Roll");
        let d2 = client.decide("something else").unwrap();
        assert_eq!(d2.command_name, "EndTurn");
    }
}
