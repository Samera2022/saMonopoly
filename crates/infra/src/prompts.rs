use std::collections::HashMap;

/// Default prompt templates embedded in the binary.
pub const DEFAULT_PROMPTS: &str = r#"{
  "decide_turn": {
    "system": "You are playing Monopoly. Choose the best action.",
    "user": "Current state: {state_json}\nChoose a command from: {available_commands}"
  },
  "evaluate_trade": {
    "system": "You are playing Monopoly. Evaluate whether to accept a trade offer.",
    "user": "You are {player_name}.\nTrade offer: {trade_json}\nYour state: {state_json}\nAccept or reject?"
  },
  "auction_bid": {
    "system": "You are playing Monopoly. Decide how much to bid in an auction.",
    "user": "Property up for auction: {property_json}\nYour cash: {cash}\nCurrent highest bid: {current_bid}\nPlace a bid or pass."
  }
}"#;

/// A single prompt template consisting of a system prompt and a user prompt template.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PromptTemplate {
    /// System-level instruction sent before the user message.
    pub system: String,
    /// User prompt template with `{placeholder}` variables.
    pub user: String,
}

impl PromptTemplate {
    /// Render the user prompt by substituting `{key}` placeholders with values.
    pub fn render_user(&self, vars: &HashMap<&str, &str>) -> String {
        let mut result = self.user.clone();
        for (key, value) in vars {
            let placeholder = format!("{{{}}}", key);
            result = result.replace(&placeholder, value);
        }
        result
    }
}

/// A store of named [`PromptTemplate`]s, typically loaded from JSON.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PromptTemplateStore {
    templates: HashMap<String, PromptTemplate>,
}

impl PromptTemplateStore {
    /// Create an empty store.
    pub fn empty() -> Self {
        Self {
            templates: HashMap::new(),
        }
    }

    /// Create a store from a pre-built map.
    pub fn new(templates: HashMap<String, PromptTemplate>) -> Self {
        Self { templates }
    }

    /// Load templates from a JSON string.
    ///
    /// Expected format:
    /// ```json
    /// {
    ///   "decide_turn": {
    ///     "system": "...",
    ///     "user": "..."
    ///   }
    /// }
    /// ```
    pub fn from_json(json: &str) -> Result<Self, String> {
        let templates: HashMap<String, PromptTemplate> =
            serde_json::from_str(json).map_err(|e| format!("failed to parse prompts JSON: {e}"))?;
        Ok(Self { templates })
    }

    /// Load templates from the embedded [`DEFAULT_PROMPTS`].
    pub fn from_default() -> Self {
        Self::from_json(DEFAULT_PROMPTS).expect("DEFAULT_PROMPTS must be valid JSON")
    }

    /// Get a template by name.
    pub fn get(&self, name: &str) -> Option<&PromptTemplate> {
        self.templates.get(name)
    }

    /// Insert or replace a template.
    pub fn insert(&mut self, name: &str, template: PromptTemplate) {
        self.templates.insert(name.to_string(), template);
    }

    /// Returns the number of stored templates.
    pub fn len(&self) -> usize {
        self.templates.len()
    }

    /// Returns `true` if the store contains no templates.
    pub fn is_empty(&self) -> bool {
        self.templates.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_prompts_parse() {
        let store = PromptTemplateStore::from_default();
        assert!(!store.is_empty());
        assert!(store.get("decide_turn").is_some());
        assert!(store.get("evaluate_trade").is_some());
        assert!(store.get("auction_bid").is_some());
    }

    #[test]
    fn test_render_user() {
        let template = PromptTemplate {
            system: "system msg".to_string(),
            user: "Hello {name}, your cash is {cash}".to_string(),
        };
        let mut vars = HashMap::new();
        vars.insert("name", "Alice");
        vars.insert("cash", "1500");
        let rendered = template.render_user(&vars);
        assert_eq!(rendered, "Hello Alice, your cash is 1500");
    }

    #[test]
    fn test_from_json() {
        let json = r#"{
            "greeting": {
                "system": "Be polite",
                "user": "Say {thing}"
            }
        }"#;
        let store = PromptTemplateStore::from_json(json).unwrap();
        let t = store.get("greeting").unwrap();
        assert_eq!(t.system, "Be polite");
        let mut vars = HashMap::new();
        vars.insert("thing", "hello");
        assert_eq!(t.render_user(&vars), "Say hello");
    }

    #[test]
    fn test_empty_store() {
        let store = PromptTemplateStore::empty();
        assert!(store.is_empty());
        assert!(store.get("anything").is_none());
    }
}
