//! # LLM Backends — decision-making via external LLM APIs or A2CM
//!
//! Provides two backends:
//! - [`DirectLlmBackend`] — calls an OpenAI-compatible HTTP API
//! - [`A2cmLlmBackend`] — sends game context to A2CM companion

use serde::{Deserialize, Serialize};

pub const A2CM_PROTOCOL_VERSION: u32 = 1;

/// Decision returned by an LLM backend, matching saMonopoly's `LlmDecision`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmDecision {
    pub command: String,
    #[serde(default = "empty_payload")]
    pub payload: serde_json::Value,
    #[serde(default)]
    pub rationale: String,
    #[serde(default)]
    pub commentary: String,
}

fn empty_payload() -> serde_json::Value {
    serde_json::json!({})
}

/// Versioned request sent to the A2CM companion service.
#[derive(Debug, Clone, Serialize)]
pub struct A2cmDecisionRequest<'a> {
    pub protocol_version: u32,
    pub request_id: String,
    pub game: &'static str,
    pub action: &'static str,
    pub player_id: String,
    pub context: &'a serde_json::Value,
    pub prompt: &'a str,
}

/// Configuration for an LLM backend call.
#[derive(Debug, Clone)]
pub struct LlmBackendConfig {
    /// Backend type: "direct" or "a2cm"
    pub backend: String,
    /// API endpoint URL for direct backend (OpenAI-compatible)
    pub endpoint: String,
    /// A2CM server URL (separate from direct endpoint)
    pub a2cm_endpoint: String,
    /// API key (for direct backend or A2CM auth)
    pub api_key: String,
    /// Model name (for direct backend)
    pub model: String,
    /// Temperature
    pub temperature: f64,
    /// Max tokens for response
    pub max_tokens: u32,
    /// Custom HTTP headers as JSON string
    pub custom_headers: String,
}

/// Call the configured LLM backend with the given prompt and return a decision.
pub fn call_llm_backend(
    prompt: &str,
    context: &serde_json::Value,
    player_id: &str,
    request_id: &str,
    config: &LlmBackendConfig,
) -> Result<LlmDecision, String> {
    let decision = match config.backend.as_str() {
        "a2cm" => call_a2cm_backend(prompt, context, player_id, request_id, config),
        _ => call_direct_backend(prompt, config),
    }?;
    validate_decision(decision)
}

fn resolve_api_key(value: &str) -> Result<String, String> {
    // Supports `keyring:<id>` (OS keychain), `env:<VAR>`, or a literal secret.
    crate::secret_store::resolve_secret(value)
}

fn custom_headers(value: &str) -> Result<Vec<(String, String)>, String> {
    if value.trim().is_empty() {
        return Ok(Vec::new());
    }
    let headers: serde_json::Map<String, serde_json::Value> = serde_json::from_str(value)
        .map_err(|e| format!("Invalid custom headers JSON: {e}"))?;
    headers
        .into_iter()
        .map(|(name, value)| {
            value
                .as_str()
                .map(|value| (name.clone(), value.to_string()))
                .ok_or_else(|| format!("Custom header '{name}' must have a string value"))
        })
        .collect()
}

/// Direct HTTP backend: OpenAI-compatible API.
fn call_direct_backend(prompt: &str, config: &LlmBackendConfig) -> Result<LlmDecision, String> {
    if config.endpoint.is_empty() {
        return Err("LLM API endpoint not configured".to_string());
    }

    let request_body = serde_json::json!({
        "model": config.model,
        "messages": [
            {"role": "system", "content": "You are playing Monopoly. Respond with a JSON object only, no other text."},
            {"role": "user", "content": prompt}
        ],
        "temperature": config.temperature,
        "max_tokens": config.max_tokens,
    });

    let body_str = serde_json::to_string(&request_body)
        .map_err(|e| format!("Failed to serialize request: {e}"))?;

    let api_key = resolve_api_key(&config.api_key)?;
    let mut req = ureq::post(&config.endpoint)
        .set("Content-Type", "application/json");
    if !api_key.is_empty() {
        req = req.set("Authorization", &format!("Bearer {api_key}"));
    }
    let headers = custom_headers(&config.custom_headers)?;
    for (name, value) in &headers {
        req = req.set(name, value);
    }

    let response = req
        .send_string(&body_str)
        .map_err(|e| format!("HTTP request failed: {e}"))?;

    let status = response.status();
    let body: serde_json::Value = response
        .into_string()
        .map_err(|e| format!("Failed to read response: {e}"))
        .and_then(|s| serde_json::from_str(&s).map_err(|e| format!("Failed to parse response: {e}")))?;

    if status != 200 {
        return Err(format!("API returned {status}: {body}"));
    }

    let choices = body["choices"]
        .as_array()
        .ok_or_else(|| "API returned no choices".to_string())?;
    let content = choices
        .first()
        .and_then(|c| c["message"]["content"].as_str())
        .ok_or_else(|| "No content in response".to_string())?;

    parse_llm_json(content)
}

/// A2CM backend: sends context to A2CM companion service.
fn call_a2cm_backend(
    prompt: &str,
    context: &serde_json::Value,
    player_id: &str,
    request_id: &str,
    config: &LlmBackendConfig,
) -> Result<LlmDecision, String> {
    let endpoint = if config.a2cm_endpoint.is_empty() {
        "http://localhost:8000".to_string()
    } else {
        config.a2cm_endpoint.clone()
    };

    let url = format!("{}/monopoly/decide", endpoint.trim_end_matches('/'));

    if !context.is_object() {
        return Err("A2CM context must be a JSON object".to_string());
    }
    let request_body = A2cmDecisionRequest {
        protocol_version: A2CM_PROTOCOL_VERSION,
        request_id: request_id.to_string(),
        game: "monopoly",
        action: "decide_turn",
        player_id: player_id.to_string(),
        context,
        prompt,
    };

    let body_str = serde_json::to_string(&request_body)
        .map_err(|e| format!("Failed to serialize request: {e}"))?;

    let api_key = resolve_api_key(&config.api_key)?;
    let mut request = ureq::post(&url).set("Content-Type", "application/json");
    if !api_key.is_empty() {
        request = request.set("Authorization", &format!("Bearer {api_key}"));
    }

    // ureq returns Err for both transport failures (can't connect) and HTTP
    // error statuses (4xx/5xx). Distinguish them so the UI can tell the user
    // whether the address/port is wrong versus auth/protocol problems.
    let response = match request.send_string(&body_str) {
        Ok(resp) => resp,
        Err(ureq::Error::Status(code, resp)) => {
            let detail = resp
                .into_string()
                .unwrap_or_else(|_| "<unreadable body>".to_string());
            let hint = match code {
                401 | 403 => " (A2CM 拒绝鉴权：请检查 saMonopoly 中的 API 密钥与 A2CM 的 api_keys 是否一致)",
                404 => " (未找到 /monopoly/decide：请确认 A2CM 已加载 Monopoly 集成路由)",
                _ => "",
            };
            return Err(format!(
                "A2CM 在 {url} 返回 HTTP {code}{hint}: {detail}"
            ));
        }
        Err(ureq::Error::Transport(t)) => {
            return Err(format!(
                "无法连接 A2CM ({url}): {t} \
                 （请确认 A2CM 已启动，且 saMonopoly 中的地址端口与其一致；\
                 start-backend.sh 默认监听 8000）"
            ));
        }
    };

    let status = response.status();
    let body: serde_json::Value = response
        .into_string()
        .map_err(|e| format!("Failed to read A2CM response: {e}"))
        .and_then(|s| serde_json::from_str(&s).map_err(|e| format!("Failed to parse A2CM response: {e}")))?;

    if status != 200 {
        return Err(format!("A2CM 在 {url} 返回状态 {status}: {body}"));
    }

    serde_json::from_value(body).map_err(|e| format!("Failed to parse A2CM decision: {e}"))
}

/// Validate the external decision before Flutter turns it into a core command.
/// The Rust command handlers remain authoritative, but rejecting malformed or
/// unknown commands here prevents arbitrary command names from crossing the
/// LLM/A2CM trust boundary.
fn validate_decision(decision: LlmDecision) -> Result<LlmDecision, String> {
    let payload = decision.payload.as_object().ok_or_else(|| {
        format!("Decision '{}' payload must be a JSON object", decision.command)
    })?;
    let required_string = |name: &str| {
        payload
            .get(name)
            .and_then(|v| v.as_str())
            .filter(|v| !v.is_empty())
            .ok_or_else(|| format!("Decision '{}' requires non-empty payload.{name}", decision.command))
    };

    match decision.command.as_str() {
        "end_turn" | "pay_bail" => {}
        "buy_property" | "upgrade_property" => {
            required_string("tile_id")?;
        }
        "buy_card" => {
            let card_id = required_string("card_id")?;
            let price = payload.get("price").and_then(|v| v.as_i64())
                .ok_or_else(|| "Decision 'buy_card' requires integer payload.price".to_string())?;
            let expected_price = match card_id {
                "bonus_200" => 100,
                "get_out_of_jail" => 150,
                "double_rent" => 200,
                other => return Err(format!("Decision 'buy_card' uses unknown card_id '{other}'")),
            };
            if price != expected_price {
                return Err(format!(
                    "Decision 'buy_card' price for '{card_id}' must be {expected_price}"
                ));
            }
        }
        "buy_lottery_ticket" => {
            let number = payload.get("number").and_then(|v| v.as_u64())
                .ok_or_else(|| "Decision 'buy_lottery_ticket' requires integer payload.number".to_string())?;
            if !(1..=100).contains(&number) {
                return Err("Decision 'buy_lottery_ticket' payload.number must be 1..=100".to_string());
            }
        }
        "use_card" => {
            required_string("card_id")?;
        }
        other => {
            return Err(format!("Unsupported LLM decision command '{other}'"));
        }
    }
    Ok(decision)
}

/// Check A2CM availability without asking it to make a game decision.
pub fn test_a2cm_connection(config: &LlmBackendConfig) -> Result<serde_json::Value, String> {
    let endpoint = if config.a2cm_endpoint.is_empty() {
        "http://localhost:8000"
    } else {
        config.a2cm_endpoint.as_str()
    };
    let url = format!("{}/monopoly/health", endpoint.trim_end_matches('/'));
    let api_key = resolve_api_key(&config.api_key)?;
    let mut request = ureq::get(&url);
    if !api_key.is_empty() {
        request = request.set("Authorization", &format!("Bearer {api_key}"));
    }
    let response = match request.call() {
        Ok(resp) => resp,
        Err(ureq::Error::Status(code, resp)) => {
            let detail = resp
                .into_string()
                .unwrap_or_else(|_| "<unreadable body>".to_string());
            let hint = match code {
                401 | 403 => " (鉴权失败：请检查 API 密钥)",
                404 => " (未找到 /monopoly/health：请确认 A2CM 已加载 Monopoly 集成路由)",
                _ => "",
            };
            return Err(format!("A2CM 在 {url} 返回 HTTP {code}{hint}: {detail}"));
        }
        Err(ureq::Error::Transport(t)) => {
            return Err(format!(
                "无法连接 A2CM ({url}): {t} \
                 （请确认 A2CM 已启动，且地址端口与其一致；start-backend.sh 默认监听 8000）"
            ));
        }
    };
    let body: serde_json::Value = response
        .into_string()
        .map_err(|e| format!("Failed to read A2CM capability response: {e}"))
        .and_then(|text| {
            serde_json::from_str(&text)
                .map_err(|e| format!("Invalid A2CM capability JSON: {e}"))
        })?;
    if body["service"].as_str() != Some("a2cm")
        || body["game"].as_str() != Some("monopoly")
        || body["protocol_version"].as_u64() != Some(A2CM_PROTOCOL_VERSION as u64)
        || body["status"].as_str() != Some("ok")
    {
        return Err(format!(
            "A2CM capability mismatch: expected monopoly protocol {}, got {body}",
            A2CM_PROTOCOL_VERSION
        ));
    }
    Ok(body)
}

/// Parse JSON from LLM response text (handles markdown fences).
fn parse_llm_json(text: &str) -> Result<LlmDecision, String> {
    let cleaned = text.trim();

    // Strip markdown code fences
    let json_str = if let Some(start) = cleaned.find("```json") {
        let after_fence = &cleaned[start + 7..];
        if let Some(end) = after_fence.find("```") {
            &after_fence[..end]
        } else {
            after_fence
        }
    } else if let Some(start) = cleaned.find("```") {
        let after_fence = &cleaned[start + 3..];
        if let Some(end) = after_fence.find("```") {
            &after_fence[..end]
        } else {
            after_fence
        }
    } else {
        cleaned
    };

    let value: serde_json::Value =
        serde_json::from_str(json_str).map_err(|e| format!("JSON parse error: {e}\nRaw: {text}"))?;

    serde_json::from_value(value).map_err(|e| format!("Decision parse error: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_llm_json_plain() {
        let json = r#"{"command":"buy_property","payload":{},"rationale":"good deal"}"#;
        let decision = parse_llm_json(json).unwrap();
        assert_eq!(decision.command, "buy_property");
        assert_eq!(decision.rationale, "good deal");
    }

    #[test]
    fn test_parse_llm_json_with_fences() {
        let json = r#"
```json
{"command":"end_turn","rationale":"Nothing to do"}
```
        "#;
        let decision = parse_llm_json(json).unwrap();
        assert_eq!(decision.command, "end_turn");
        assert_eq!(decision.payload, serde_json::json!({}));
    }

    #[test]
    fn test_parse_llm_json_with_commentary() {
        let json = r#"{"command":"buy_property","payload":{"tile_id":"prop_9"},"rationale":"good","commentary":"Mine!"}"#;
        let decision = parse_llm_json(json).unwrap();
        assert_eq!(decision.command, "buy_property");
        assert_eq!(decision.commentary, "Mine!");
    }

    #[test]
    fn custom_headers_require_string_values() {
        assert!(custom_headers(r#"{"X-Test":12}"#).is_err());
        assert_eq!(custom_headers(r#"{"X-Test":"yes"}"#).unwrap()[0].1, "yes");
    }

    #[test]
    fn a2cm_request_contains_structured_context_and_version() {
        let context = serde_json::json!({
            "you": {"id": "p1", "cash": 1500},
            "available_actions": ["end_turn"]
        });
        let request = A2cmDecisionRequest {
            protocol_version: A2CM_PROTOCOL_VERSION,
            request_id: "turn-7-p1-1".to_string(),
            game: "monopoly",
            action: "decide_turn",
            player_id: "p1".to_string(),
            context: &context,
            prompt: "decide",
        };
        let json = serde_json::to_value(request).unwrap();
        assert_eq!(json["protocol_version"], 1);
        assert_eq!(json["player_id"], "p1");
        assert_eq!(json["context"]["you"]["cash"], 1500);
    }

    #[test]
    fn decision_validation_rejects_unknown_or_malformed_commands() {
        let unknown = LlmDecision {
            command: "delete_save".to_string(),
            payload: serde_json::json!({}),
            rationale: String::new(),
            commentary: String::new(),
        };
        assert!(validate_decision(unknown).is_err());

        let missing_tile = LlmDecision {
            command: "buy_property".to_string(),
            payload: serde_json::json!({}),
            rationale: String::new(),
            commentary: String::new(),
        };
        assert!(validate_decision(missing_tile).is_err());

        let valid = LlmDecision {
            command: "end_turn".to_string(),
            payload: serde_json::json!({}),
            rationale: String::new(),
            commentary: String::new(),
        };
        assert!(validate_decision(valid).is_ok());

        let free_card = LlmDecision {
            command: "buy_card".to_string(),
            payload: serde_json::json!({"card_id": "bonus_200", "price": 0}),
            rationale: String::new(),
            commentary: String::new(),
        };
        assert!(validate_decision(free_card).is_err());
    }
}
