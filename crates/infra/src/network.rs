use std::collections::HashMap;
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, Mutex};
use tokio::sync::mpsc::error::TryRecvError;
use tokio_tungstenite::accept_async;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use sa_monopoly_application::bridge::{BridgeRequest, EngineBridge};
use sa_monopoly_application::event_bus::EventBus;

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
    /// Host broadcasts current plugin list and enable states
    PluginSync {
        plugins: String, // JSON serialized Vec<PluginSyncEntry>
    },
    /// Client replies with plugin check result
    PluginAck {
        client_id: String,
        ready: bool,
        missing_plugins: Vec<String>,
    },
    /// Client requests plugin list from host (on joining)
    PluginListRequest,
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
// WebSocketServer – real WebSocket server using tokio-tungstenite
// ============================================================================

/// A WebSocket server that accepts connections, deserializes JSON messages,
/// processes them through the session manager, and optionally replies.
pub struct WebSocketServer {
    /// WebSocket configuration (host, port, etc.).
    ws_config: WebSocketConfig,
    /// Shared session manager for handling join/leave/start/end.
    session_manager: Arc<Mutex<SessionManager>>,
    /// Map of connected peers to their outbound message channels.
    connected_peers: Arc<Mutex<HashMap<SessionEndpoint, mpsc::UnboundedSender<String>>>>,
    /// Event bus for executing commands.
    event_bus: Arc<Mutex<EventBus>>,
    /// Plugin manager for plugin sync (host only)
    plugin_manager: Arc<Mutex<crate::plugin_manager::PluginManager>>,
    /// Pending plugin acks from clients (host only)
    pending_acks: Arc<Mutex<HashMap<String, (bool, Vec<String>)>>>,
}

impl WebSocketServer {
    /// Create a new `WebSocketServer`.
    pub fn new(
        config: WebSocketConfig,
        session_manager: Arc<Mutex<SessionManager>>,
        plugin_manager: Arc<Mutex<crate::plugin_manager::PluginManager>>,
    ) -> Self {
        Self {
            ws_config: config,
            session_manager,
            connected_peers: Arc::new(Mutex::new(HashMap::new())),
            event_bus: Arc::new(Mutex::new(EventBus::new())),
            plugin_manager,
            pending_acks: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Broadcast the current plugin list to all connected peers.
    pub async fn broadcast_plugin_list(&self) {
        let pm = self.plugin_manager.lock().await;
        let entries = pm.build_sync_entries();
        let json = serde_json::to_string(&entries).unwrap_or_default();
        let msg = NetworkMessage::PluginSync { plugins: json };
        self.broadcast(&msg).await;
    }

    /// Start the server: bind to the configured address and begin accepting connections.
    ///
    /// Each incoming connection is upgraded to a WebSocket and handled concurrently.
    pub async fn start(self: Arc<Self>) -> Result<(), String> {
        let addr = format!("{}:{}", self.ws_config.host, self.ws_config.port);
        let listener = TcpListener::bind(&addr)
            .await
            .map_err(|e| format!("failed to bind to {}: {}", addr, e))?;

        println!("WebSocket server listening on {}", addr);

        while let Ok((stream, peer_addr)) = listener.accept().await {
            let this = self.clone();
            tokio::spawn(async move {
                if let Err(e) = this.handle_connection(stream, peer_addr).await {
                    eprintln!("connection error from {}: {}", peer_addr, e);
                }
            });
        }

        Ok(())
    }

    /// Accept a single WebSocket connection and process its messages until disconnect.
    async fn handle_connection(
        &self,
        stream: tokio::net::TcpStream,
        peer_addr: std::net::SocketAddr,
    ) -> Result<(), String> {
        let ws_stream = accept_async(stream)
            .await
            .map_err(|e| format!("WebSocket handshake failed: {}", e))?;

        let (mut ws_sender, mut ws_receiver) = ws_stream.split();

        let (tx, mut rx) = mpsc::unbounded_channel::<String>();

        let endpoint = SessionEndpoint::new(&peer_addr.ip().to_string(), peer_addr.port());
        {
            let mut peers = self.connected_peers.lock().await;
            peers.insert(endpoint.clone(), tx);
        }

        // Spawn a task to forward messages from the channel to the WebSocket.
        let forward_handle = tokio::spawn(async move {
            while let Some(msg) = rx.recv().await {
                if ws_sender.send(Message::Text(msg)).await.is_err() {
                    break;
                }
            }
        });

        // Read messages from the WebSocket.
        while let Some(msg_result) = ws_receiver.next().await {
            match msg_result {
                Ok(msg) => {
                    if let Err(e) = self.process_message(&endpoint, &msg).await {
                        eprintln!(
                            "error processing message from {}: {}",
                            endpoint.addr(),
                            e
                        );
                    }
                }
                Err(e) => {
                    eprintln!("WebSocket error from {}: {}", endpoint.addr(), e);
                    break;
                }
            }
        }

        // Clean up: remove the peer and abort the forwarding task.
        {
            let mut peers = self.connected_peers.lock().await;
            peers.remove(&endpoint);
        }
        forward_handle.abort();

        Ok(())
    }

    /// Deserialize a raw WebSocket message and route it to the appropriate handler.
    async fn process_message(
        &self,
        endpoint: &SessionEndpoint,
        msg: &Message,
    ) -> Result<(), String> {
        let text = msg
            .to_text()
            .map_err(|e| format!("failed to read message as text: {}", e))?;

        let network_msg: NetworkMessage = serde_json::from_str(text)
            .map_err(|e| format!("failed to deserialize message: {}", e))?;

        match &network_msg {
            NetworkMessage::Ping => {
                // Reply with a Ping as acknowledgement.
                self.send_to(endpoint, &NetworkMessage::Ping).await;
            }
            NetworkMessage::Session { kind, data } => {
                self.handle_session_message(endpoint, kind, data).await;
            }
            NetworkMessage::Command { payload } => {
                // Deserialize the command payload into a BridgeRequest.
                let request: BridgeRequest = serde_json::from_str(payload)
                    .map_err(|e| format!("failed to deserialize command payload: {}", e))?;

                // Execute the engine command. State broadcasting is handled below via StateSync.
                let mut bus = self.event_bus.lock().await;
                let response = EngineBridge::execute(request, &mut *bus);

                // Serialise the resulting state into JSON and broadcast it.
                let state_json = serde_json::to_string(&response.state)
                    .map_err(|e| format!("failed to serialise state: {}", e))?;

                let state_sync = NetworkMessage::StateSync { payload: state_json };
                self.broadcast(&state_sync).await;
            }
            NetworkMessage::StateSync { .. } => {
                // Forward state sync messages to all connected peers.
                self.broadcast(&network_msg).await;
            }
            NetworkMessage::Error { .. } => {
                eprintln!(
                    "received error from {}: code={:?}",
                    endpoint.addr(),
                    network_msg
                );
            }
            NetworkMessage::PluginSync { .. } => {
                // Client received host's plugin list
                eprintln!("[PluginSync] Received plugin list from host");
                // The client would validate locally — for now just log
            }
            NetworkMessage::PluginAck { client_id, ready, missing_plugins } => {
                eprintln!(
                    "[PluginSync] Client {} ready: {}, missing: {:?}",
                    client_id, ready, missing_plugins
                );
                let mut pending = self.pending_acks.lock().await;
                pending.insert(client_id.clone(), (*ready, missing_plugins.clone()));
            }
            NetworkMessage::PluginListRequest => {
                eprintln!("[PluginSync] Client requested plugin list");
                self.broadcast_plugin_list().await;
            }
        }

        Ok(())
    }

    /// Handle session-level control messages (Join, Leave, Ready, Start, End).
    async fn handle_session_message(
        &self,
        endpoint: &SessionEndpoint,
        kind: &SessionMessageKind,
        data: &str,
    ) {
        match kind {
            SessionMessageKind::Join => {
                // data is expected to be JSON: {"session_id": "...", "player_id": "..."}
                #[derive(Deserialize)]
                struct JoinData {
                    session_id: String,
                    player_id: String,
                }
                match serde_json::from_str::<JoinData>(data) {
                    Ok(join) => {
                        let mut mgr = self.session_manager.lock().await;
                        match mgr.join_session(&join.session_id, &join.player_id) {
                            Ok(()) => {
                                let reply = NetworkMessage::Session {
                                    kind: SessionMessageKind::Join,
                                    data: serde_json::json!({"status": "ok"}).to_string(),
                                };
                                self.send_to(endpoint, &reply).await;
                            }
                            Err(e) => {
                                let reply = NetworkMessage::Error {
                                    code: 1001,
                                    message: e,
                                };
                                self.send_to(endpoint, &reply).await;
                            }
                        }
                    }
                    Err(e) => {
                        let reply = NetworkMessage::Error {
                            code: 1002,
                            message: format!("invalid join data: {}", e),
                        };
                        self.send_to(endpoint, &reply).await;
                    }
                }
            }
            SessionMessageKind::Leave => {
                // data is expected to be JSON: {"session_id": "...", "player_id": "..."}
                #[derive(Deserialize)]
                struct LeaveData {
                    session_id: String,
                    player_id: String,
                }
                match serde_json::from_str::<LeaveData>(data) {
                    Ok(leave) => {
                        let mut mgr = self.session_manager.lock().await;
                        match mgr.leave_session(&leave.session_id, &leave.player_id) {
                            Ok(()) => {
                                let reply = NetworkMessage::Session {
                                    kind: SessionMessageKind::Leave,
                                    data: serde_json::json!({"status": "ok"}).to_string(),
                                };
                                self.send_to(endpoint, &reply).await;
                            }
                            Err(e) => {
                                let reply = NetworkMessage::Error {
                                    code: 1003,
                                    message: e,
                                };
                                self.send_to(endpoint, &reply).await;
                            }
                        }
                    }
                    Err(e) => {
                        let reply = NetworkMessage::Error {
                            code: 1004,
                            message: format!("invalid leave data: {}", e),
                        };
                        self.send_to(endpoint, &reply).await;
                    }
                }
            }
            SessionMessageKind::Ready => {
                // Acknowledge readiness — no session-manager action required.
                let reply = NetworkMessage::Session {
                    kind: SessionMessageKind::Ready,
                    data: serde_json::json!({"status": "ok"}).to_string(),
                };
                self.send_to(endpoint, &reply).await;
            }
            SessionMessageKind::Start => {
                // data is expected to be JSON: {"session_id": "..."}
                #[derive(Deserialize)]
                struct StartData {
                    session_id: String,
                }
                match serde_json::from_str::<StartData>(data) {
                    Ok(start) => {
                        let mut mgr = self.session_manager.lock().await;
                        match mgr.start_session(&start.session_id) {
                            Ok(()) => {
                                let reply = NetworkMessage::Session {
                                    kind: SessionMessageKind::Start,
                                    data: serde_json::json!({"status": "ok"}).to_string(),
                                };
                                self.broadcast(&reply).await;
                            }
                            Err(e) => {
                                let reply = NetworkMessage::Error {
                                    code: 1005,
                                    message: e,
                                };
                                self.send_to(endpoint, &reply).await;
                            }
                        }
                    }
                    Err(e) => {
                        let reply = NetworkMessage::Error {
                            code: 1006,
                            message: format!("invalid start data: {}", e),
                        };
                        self.send_to(endpoint, &reply).await;
                    }
                }
            }
            SessionMessageKind::End => {
                // Broadcast session-end to all peers.
                let reply = NetworkMessage::Session {
                    kind: SessionMessageKind::End,
                    data: serde_json::json!({"status": "ok"}).to_string(),
                };
                self.broadcast(&reply).await;
            }
        }
    }

    /// Send a message to a specific connected peer.
    async fn send_to(&self, endpoint: &SessionEndpoint, message: &NetworkMessage) {
        let json = serde_json::to_string(message).unwrap_or_default();
        let peers = self.connected_peers.lock().await;
        if let Some(tx) = peers.get(endpoint) {
            let _ = tx.send(json);
        }
    }

    /// Broadcast a message to all currently connected peers.
    pub async fn broadcast(&self, message: &NetworkMessage) {
        let json = serde_json::to_string(message).unwrap_or_default();
        let peers = self.connected_peers.lock().await;
        for tx in peers.values() {
            let _ = tx.send(json.clone());
        }
    }
}

// ============================================================================
// WebSocketClient – real WebSocket client using tokio-tungstenite
// ============================================================================

/// A WebSocket client that connects to a server, sends and receives
/// [`NetworkMessage`] values as JSON text frames.
pub struct WebSocketClient {
    /// Server address in `"host:port"` format.
    server_addr: String,
    /// Channel sender for writing messages to the WebSocket write loop.
    write_tx: Option<mpsc::UnboundedSender<String>>,
    /// Channel receiver for reading messages from the WebSocket read loop.
    read_rx: Option<mpsc::UnboundedReceiver<NetworkMessage>>,
}

impl WebSocketClient {
    /// Create a new `WebSocketClient` targeting the given host and port.
    pub fn new(host: &str, port: u16) -> Self {
        Self {
            server_addr: format!("{}:{}", host, port),
            write_tx: None,
            read_rx: None,
        }
    }

    /// Connect to the WebSocket server and spawn background read/write tasks.
    ///
    /// # Write loop
    /// Reads [`String`] messages from the internal write channel and sends
    /// them as [`Message::Text`] through the WebSocket sink.
    ///
    /// # Read loop
    /// Reads [`Message::Text`] frames from the WebSocket stream, deserialises
    /// them into [`NetworkMessage`], and forwards them into the internal read
    /// channel so they can be consumed by [`receive`](Self::receive).
    pub async fn connect(&mut self) -> Result<(), String> {
        // Build the ws:// URL from the stored address.
        let url = format!("ws://{}", self.server_addr);

        let (ws_stream, _) = connect_async(&url)
            .await
            .map_err(|e| format!("WebSocket connection to '{}' failed: {}", url, e))?;

        let (mut ws_sender, mut ws_receiver) = ws_stream.split();

        // ── Write channel ──
        let (write_tx, mut write_rx) = mpsc::unbounded_channel::<String>();
        self.write_tx = Some(write_tx);

        // ── Read channel ──
        let (read_tx, read_rx) = mpsc::unbounded_channel::<NetworkMessage>();
        self.read_rx = Some(read_rx);

        // Spawn the write task: forward strings from the channel to the
        // WebSocket sink as text frames.
        tokio::spawn(async move {
            while let Some(text) = write_rx.recv().await {
                if ws_sender.send(Message::Text(text)).await.is_err() {
                    break;
                }
            }
        });

        // Spawn the read task: deserialise incoming text frames into
        // NetworkMessage and forward them into the read channel.
        tokio::spawn(async move {
            while let Some(msg_result) = ws_receiver.next().await {
                match msg_result {
                    Ok(msg) => {
                        if let Ok(text) = msg.to_text() {
                            if let Ok(network_msg) = serde_json::from_str::<NetworkMessage>(text) {
                                let _ = read_tx.send(network_msg);
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("WebSocket client read error: {}", e);
                        break;
                    }
                }
            }
        });

        Ok(())
    }

    /// Send a [`NetworkMessage`] to the server as a JSON text frame.
    ///
    /// Returns an error if the client is not connected or the write channel
    /// has been closed.
    pub async fn send(&self, message: &NetworkMessage) -> Result<(), String> {
        let tx = self
            .write_tx
            .as_ref()
            .ok_or_else(|| "WebSocketClient is not connected".to_string())?;

        let json = serde_json::to_string(message)
            .map_err(|e| format!("failed to serialise message: {}", e))?;

        tx.send(json)
            .map_err(|_| "WebSocket write channel closed".to_string())
    }

    /// Attempt to receive a [`NetworkMessage`] (non-blocking).
    ///
    /// Returns `Ok(None)` when no message is available yet, and `Err` if the
    /// client is not connected or the read channel has been closed.
    pub async fn receive(&mut self) -> Result<Option<NetworkMessage>, String> {
        let rx = self
            .read_rx
            .as_mut()
            .ok_or_else(|| "WebSocketClient is not connected".to_string())?;

        match rx.try_recv() {
            Ok(msg) => Ok(Some(msg)),
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => {
                Err("WebSocket read channel closed".to_string())
            }
        }
    }
}

// ============================================================================
// LobbyHost – high-level lobby lifecycle manager
// ============================================================================

/// High-level API that integrates [`WebSocketServer`] and [`SessionManager`]
/// to manage a game lobby lifecycle.
///
/// Call [`new`](Self::new) to create a lobby, [`start`](Self::start) to begin
/// accepting connections, and [`stop`](Self::stop) to shut down.
pub struct LobbyHost {
    /// The WebSocket server instance.
    server: Arc<WebSocketServer>,
    /// Shared session manager for creating and managing sessions.
    session_manager: Arc<Mutex<SessionManager>>,
    /// The session ID created by this host (set after [`create_session`](Self::create_session)).
    session_id: Option<String>,
    /// WebSocket configuration (cached for building session endpoints).
    config: WebSocketConfig,
}

impl LobbyHost {
    /// Create a new `LobbyHost` with the given WebSocket configuration.
    ///
    /// A [`SessionManager`] and [`WebSocketServer`] are created internally
    /// and wired together.
    pub fn new(config: WebSocketConfig) -> Self {
        let session_manager = Arc::new(Mutex::new(SessionManager::new()));
        let plugin_manager = Arc::new(Mutex::new(crate::plugin_manager::PluginManager::new(
            std::path::PathBuf::from("plugins"),
        )));
        let server = Arc::new(WebSocketServer::new(
            config.clone(),
            session_manager.clone(),
            plugin_manager,
        ));
        Self {
            server,
            session_manager,
            session_id: None,
            config,
        }
    }

    /// Start the WebSocket server in the background.
    ///
    /// The server accepts connections until [`stop`](Self::stop) is called
    /// or the `LobbyHost` is dropped.
    pub async fn start(&mut self) -> Result<(), String> {
        let server = self.server.clone();
        tokio::spawn(async move {
            let _ = server.start().await;
        });
        Ok(())
    }

    /// Stop the lobby service and reset its state.
    ///
    /// Clears the current session ID and replaces the session manager
    /// with a fresh instance, effectively resetting the lobby.
    pub async fn stop(&mut self) {
        self.session_id = None;
        self.session_manager = Arc::new(Mutex::new(SessionManager::new()));
    }

    /// Create a new game session with the given name and player limit.
    ///
    /// The session is registered in the [`SessionManager`] and its ID is
    /// stored internally for later queries.  Only one session can be
    /// created per `LobbyHost`; subsequent calls return an error.
    pub fn create_session(&mut self, name: &str, max_players: usize) -> Result<String, String> {
        if self.session_id.is_some() {
            return Err("a session has already been created for this lobby".to_string());
        }

        let host = SessionEndpoint::new(&self.config.host, self.config.port);
        let mut mgr = self.session_manager.blocking_lock();
        let id = mgr.create_session(name, host, max_players);
        self.session_id = Some(id.clone());
        Ok(id)
    }

    /// Return information about the currently managed session, if any.
    pub fn session_info(&self) -> Option<SessionInfo> {
        let id = self.session_id.as_ref()?;
        let mgr = self.session_manager.blocking_lock();
        mgr.get_session(id).cloned()
    }

    /// Return the number of connected (joined) players in the current session.
    pub fn connected_count(&self) -> usize {
        self.session_info()
            .map(|info| info.players.len())
            .unwrap_or(0)
    }
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
