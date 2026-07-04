use std::collections::HashMap;

use serde::{Deserialize, Serialize};

// ============================================================================
// WebSocket configuration
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebSocketConfig {
    /// Host to bind/connect to (e.g. "127.0.0.1" or "0.0.0.0").
    pub host: String,
    /// Port number (e.g. 9000).
    pub port: u16,
    /// Optional path prefix (e.g. "/ws/".
    pub path: String,
    /// TLS enabled.
    pub tls: bool,
    /// Maximum message size in bytes (default 256 KiB).
    pub max_message_size: usize,
    /// Interval between keep‑alive pings.
    pub ping_interval_secs: u64,
}

impl Default for WebSocketConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_string(),
            port: 9000,
            path: "/ws".to_string(),
            tls: false,
            max_message_size: 256 * 1024,
            ping_interval_secs: 30,
        }
    }
}

// ============================================================================
// Session endpoint
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct SessionEndpoint {
    pub host: String,
    pub port: u16,
}

impl SessionEndpoint {
    pub fn new(host: &str, port: u16) -> Self {
        Self {
            host: host.to_string(),
            port,
        }
    }

    /// Return the string representation used for connecting (e.g. "127.0.0.1:9000").
    pub fn addr(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

// ============================================================================
// Network messages
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum NetworkMessage {
    /// Connection keep‑alive.
    Ping,
    /// Full state synchronisation payload.
    StateSync {
        payload: String,
    },
    /// A game command forwarded over the wire.
    Command {
        payload: String,
    },
    /// Session-level control messages.
    Session {
        kind: SessionMessageKind,
        data: String,
    },
    /// Error notification.
    Error {
        code: u32,
        message: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum SessionMessageKind {
    Join,
    Leave,
    Ready,
    Start,
    End,
}

// ============================================================================
// NetworkTransport trait (enhanced)
// ============================================================================

pub trait NetworkTransport: Send + Sync {
    /// Send a message to a connected endpoint.
    fn send(&self, endpoint: &SessionEndpoint, message: &NetworkMessage) -> Result<(), String>;

    /// Receive a message from an endpoint (non‑blocking).
    fn receive(&self, endpoint: &SessionEndpoint) -> Result<Option<NetworkMessage>, String>;

    /// Broadcast a message to all connected endpoints.
    fn broadcast(&self, message: &NetworkMessage) -> Result<(), String>;

    /// Return the list of currently connected endpoints.
    fn connected_endpoints(&self) -> Vec<SessionEndpoint>;

    /// Check whether the transport is currently active.
    fn is_connected(&self) -> bool;

    /// Gracefully disconnect from the given endpoint.
    fn disconnect(&mut self, endpoint: &SessionEndpoint) -> Result<(), String>;
}

// ============================================================================
// DisabledNetworkTransport – stub with configuration support
// ============================================================================

#[derive(Clone)]
pub struct DisabledNetworkTransport {
    /// Configuration that will be used once a real transport is plugged in.
    pub config: Option<WebSocketConfig>,
    /// Track "connected" endpoints for simulation.
    peers: Vec<SessionEndpoint>,
}

impl DisabledNetworkTransport {
    pub fn new() -> Self {
        Self {
            config: None,
            peers: Vec::new(),
        }
    }

    pub fn with_config(config: WebSocketConfig) -> Self {
        Self {
            config: Some(config),
            peers: Vec::new(),
        }
    }
}

impl Default for DisabledNetworkTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl NetworkTransport for DisabledNetworkTransport {
    fn send(&self, _endpoint: &SessionEndpoint, _message: &NetworkMessage) -> Result<(), String> {
        if let Some(ref config) = self.config {
            Err(format!(
                "network transport configured at {} but not yet active",
                config.host
            ))
        } else {
            Err("network transport is disabled – no WebSocketConfig set".to_string())
        }
    }

    fn receive(&self, _endpoint: &SessionEndpoint) -> Result<Option<NetworkMessage>, String> {
        if self.config.is_none() {
            Err("network transport is disabled".to_string())
        } else {
            Ok(None)
        }
    }

    fn broadcast(&self, _message: &NetworkMessage) -> Result<(), String> {
        if self.config.is_none() {
            Err("network transport is disabled".to_string())
        } else {
            Ok(()) // silently succeed – no real peers
        }
    }

    fn connected_endpoints(&self) -> Vec<SessionEndpoint> {
        self.peers.clone()
    }

    fn is_connected(&self) -> bool {
        !self.peers.is_empty()
    }

    fn disconnect(&mut self, endpoint: &SessionEndpoint) -> Result<(), String> {
        self.peers.retain(|p| p != endpoint);
        Ok(())
    }
}

// ============================================================================
// LocalSessionManager – simplified session management for LAN / local games
// ============================================================================

/// Represents a single game session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    /// Unique session identifier.
    pub id: String,
    /// Human‑readable session name.
    pub name: String,
    /// Host endpoint.
    pub host: SessionEndpoint,
    /// Connected player IDs.
    pub players: Vec<String>,
    /// Maximum number of players.
    pub max_players: usize,
    /// Whether the session has started.
    pub started: bool,
}

/// Manages local (LAN / same‑machine) game sessions.
///
/// In production this would be backed by a discovery protocol (mDNS, etc.);
/// for now it is an in‑memory registry.
pub struct SessionManager {
    /// All known sessions, keyed by ID.
    sessions: HashMap<String, SessionInfo>,
    /// Optional WebSocket config for hosting.
    ws_config: Option<WebSocketConfig>,
}

impl SessionManager {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
            ws_config: None,
        }
    }

    /// Create a new session hosted by this instance.
    pub fn create_session(
        &mut self,
        name: &str,
        host: SessionEndpoint,
        max_players: usize,
    ) -> String {
        let id = format!("session_{}", self.sessions.len() + 1);
        let session = SessionInfo {
            id: id.clone(),
            name: name.to_string(),
            host,
            players: Vec::new(),
            max_players,
            started: false,
        };
        self.sessions.insert(id.clone(), session);
        id
    }

    /// Join an existing session.
    pub fn join_session(&mut self, session_id: &str, player_id: &str) -> Result<(), String> {
        let session = self
            .sessions
            .get_mut(session_id)
            .ok_or_else(|| format!("session '{}' not found", session_id))?;

        if session.started {
            return Err("session already started".to_string());
        }
        if session.players.len() >= session.max_players {
            return Err("session is full".to_string());
        }
        if session.players.contains(&player_id.to_string()) {
            return Err("player already in session".to_string());
        }

        session.players.push(player_id.to_string());
        Ok(())
    }

    /// Leave a session.
    pub fn leave_session(&mut self, session_id: &str, player_id: &str) -> Result<(), String> {
        let session = self
            .sessions
            .get_mut(session_id)
            .ok_or_else(|| format!("session '{}' not found", session_id))?;

        session.players.retain(|p| p != player_id);
        Ok(())
    }

    /// Mark a session as started.
    pub fn start_session(&mut self, session_id: &str) -> Result<(), String> {
        let session = self
            .sessions
            .get_mut(session_id)
            .ok_or_else(|| format!("session '{}' not found", session_id))?;

        if session.players.len() < 2 {
            return Err("need at least 2 players to start".to_string());
        }
        session.started = true;
        Ok(())
    }

    /// List all known sessions.
    pub fn list_sessions(&self) -> Vec<&SessionInfo> {
        self.sessions.values().collect()
    }

    /// Get a specific session.
    pub fn get_session(&self, session_id: &str) -> Option<&SessionInfo> {
        self.sessions.get(session_id)
    }

    /// Remove a session.
    pub fn remove_session(&mut self, session_id: &str) {
        self.sessions.remove(session_id);
    }

    /// Set the WebSocket configuration for hosting.
    pub fn set_ws_config(&mut self, config: WebSocketConfig) {
        self.ws_config = Some(config);
    }

    /// Get the current WebSocket configuration.
    pub fn ws_config(&self) -> Option<&WebSocketConfig> {
        self.ws_config.as_ref()
    }
}

impl Default for SessionManager {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================================
// Helper: create a default disabled transport with WebSocket config
// ============================================================================

/// Create a [`DisabledNetworkTransport`] pre‑configured with default
/// WebSocket settings so it is ready for a future real transport.
pub fn disabled_with_default_config() -> DisabledNetworkTransport {
    DisabledNetworkTransport::with_config(WebSocketConfig::default())
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_websocket_config_defaults() {
        let cfg = WebSocketConfig::default();
        assert_eq!(cfg.host, "127.0.0.1");
        assert_eq!(cfg.port, 9000);
        assert!(!cfg.tls);
    }

    #[test]
    fn test_session_endpoint_addr() {
        let ep = SessionEndpoint::new("192.168.1.1", 9000);
        assert_eq!(ep.addr(), "192.168.1.1:9000");
    }

    #[test]
    fn test_disabled_transport_no_config() {
        let transport = DisabledNetworkTransport::new();
        let ep = SessionEndpoint::new("127.0.0.1", 9000);
        let msg = NetworkMessage::Ping;
        let result = transport.send(&ep, &msg);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("disabled"));
    }

    #[test]
    fn test_disabled_transport_with_config_still_errors() {
        let transport = DisabledNetworkTransport::with_config(WebSocketConfig::default());
        let ep = SessionEndpoint::new("127.0.0.1", 9000);
        let msg = NetworkMessage::Ping;
        let result = transport.send(&ep, &msg);
        assert!(result.is_err());
        // With config the error message changes
        assert!(result.unwrap_err().contains("configured"));
    }

    #[test]
    fn test_session_manager_create_and_list() {
        let mut mgr = SessionManager::new();
        let ep = SessionEndpoint::new("127.0.0.1", 9000);
        let id = mgr.create_session("Test Game", ep, 4);
        assert_eq!(mgr.list_sessions().len(), 1);
        let session = mgr.get_session(&id).unwrap();
        assert_eq!(session.name, "Test Game");
        assert_eq!(session.max_players, 4);
        assert!(!session.started);
    }

    #[test]
    fn test_session_manager_join_and_start() {
        let mut mgr = SessionManager::new();
        let ep = SessionEndpoint::new("127.0.0.1", 9000);
        let id = mgr.create_session("Test", ep, 4);

        mgr.join_session(&id, "player_1").unwrap();
        mgr.join_session(&id, "player_2").unwrap();

        let session = mgr.get_session(&id).unwrap();
        assert_eq!(session.players.len(), 2);

        mgr.start_session(&id).unwrap();
        assert!(mgr.get_session(&id).unwrap().started);
    }

    #[test]
    fn test_session_manager_start_fails_with_too_few_players() {
        let mut mgr = SessionManager::new();
        let ep = SessionEndpoint::new("127.0.0.1", 9000);
        let id = mgr.create_session("Test", ep, 4);
        mgr.join_session(&id, "player_1").unwrap();

        let result = mgr.start_session(&id);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("at least 2 players"));
    }

    #[test]
    fn test_session_manager_join_full_session() {
        let mut mgr = SessionManager::new();
        let ep = SessionEndpoint::new("127.0.0.1", 9000);
        let id = mgr.create_session("Test", ep, 1);
        mgr.join_session(&id, "player_1").unwrap();

        let result = mgr.join_session(&id, "player_2");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("full"));
    }

    #[test]
    fn test_session_manager_leave() {
        let mut mgr = SessionManager::new();
        let ep = SessionEndpoint::new("127.0.0.1", 9000);
        let id = mgr.create_session("Test", ep, 4);
        mgr.join_session(&id, "player_1").unwrap();
        mgr.join_session(&id, "player_2").unwrap();
        mgr.leave_session(&id, "player_1").unwrap();

        let session = mgr.get_session(&id).unwrap();
        assert_eq!(session.players.len(), 1);
        assert_eq!(session.players[0], "player_2");
    }

    #[test]
    fn test_disabled_with_default_config() {
        let transport = disabled_with_default_config();
        assert!(transport.config.is_some());
        assert_eq!(transport.config.unwrap().port, 9000);
    }

    #[test]
    fn test_disconnect_removes_endpoint() {
        let mut transport = DisabledNetworkTransport::new();
        let ep = SessionEndpoint::new("127.0.0.1", 9000);
        transport.peers.push(ep.clone());
        assert_eq!(transport.connected_endpoints().len(), 1);
        transport.disconnect(&ep).unwrap();
        assert_eq!(transport.connected_endpoints().len(), 0);
    }

    #[test]
    fn test_broadcast_disabled_no_config() {
        let transport = DisabledNetworkTransport::new();
        let msg = NetworkMessage::Ping;
        assert!(transport.broadcast(&msg).is_err());
    }

    #[test]
    fn test_broadcast_disabled_with_config() {
        let transport = DisabledNetworkTransport::with_config(WebSocketConfig::default());
        let msg = NetworkMessage::Ping;
        // With config, broadcast "succeeds" (no-op) since there are no real peers
        assert!(transport.broadcast(&msg).is_ok());
    }
}
