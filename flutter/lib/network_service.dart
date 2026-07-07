import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Service for LAN multiplayer via WebSocket.
///
/// Provides both host (server) and client (connect) roles for the Game Lobby.
/// Messages are JSON-encoded with a `type` field for message routing:
///
/// ```json
/// {"type": "join", "player_name": "...", "player_id": "..."}
/// {"type": "leave", "player_id": "..."}
/// {"type": "ready", "player_id": "..."}
/// {"type": "start_game", "session_id": "..."}
/// {"type": "state_sync", "state": {...}, "revision": 1}
/// {"type": "command", "command": {...}, "state": {...}}
/// {"type": "ping"}
/// {"type": "system", "message": "..."}
/// ```
class NetworkService {
  // ── Server (host) ──────────────────────────────────────────────────────────
  HttpServer? _httpServer;
  StreamSubscription<HttpRequest>? _serverSubscription;

  // ── Client socket ──────────────────────────────────────────────────────────
  WebSocket? _socket;

  // ── State ──────────────────────────────────────────────────────────────────
  String? _sessionId;
  bool _isHost = false;

  /// All connected client sockets (host only: one per remote peer).
  final List<WebSocket> _clients = [];

  /// Subscriptions per client socket for cancellation.
  final Map<WebSocket, StreamSubscription<dynamic>> _clientSubscriptions = {};

  /// Maps connected client sockets to their player IDs (host only).
  /// Populated when a "join" message is received; used to notify the lobby
  /// when a client disconnects unexpectedly.
  final Map<WebSocket, String> _clientPlayerMap = {};

  /// Stream controller for incoming messages (broadcast so multiple listeners
  /// can coexist).
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  // ── Public accessors ───────────────────────────────────────────────────────

  /// Whether this instance is the host (server).
  bool get isHost => _isHost;

  /// Whether this instance is connected (either as host or client).
  bool get isConnected => _isHost || _socket != null;

  /// The current session ID, assigned when a game starts.
  String? get sessionId => _sessionId;

  /// The stream of parsed JSON messages from connected peers.
  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  /// Number of currently connected clients (host only).
  int get connectedClientCount => _clients.length;

  // ── Host: start a WebSocket server ─────────────────────────────────────────

  /// Start a WebSocket server on [host]:[port].
  ///
  /// Creates an [HttpServer] bound to the given address, then upgrades incoming
  /// HTTP requests to WebSocket connections using
  /// [WebSocketTransformer.upgrade]. All received messages are parsed as JSON
  /// and forwarded to the [_messageController] stream.
  Future<void> startHost(String host, int port) async {
    if (_isHost) {
      throw StateError('Already hosting');
    }

    _httpServer = await HttpServer.bind(host, port);
    _isHost = true;

    _serverSubscription = _httpServer!.listen(
      (HttpRequest request) async {
        if (request.uri.path == '/') {
          try {
            final socket = await WebSocketTransformer.upgrade(request);
            _clients.add(socket);

            // Forward messages from this client to the stream
            final sub = socket.listen(
              (dynamic data) {
                try {
                  final decoded =
                      jsonDecode(data as String) as Map<String, dynamic>;
                  // Track player ID for this socket when a "join" message arrives
                  if (decoded['type'] == 'join' && decoded.containsKey('player_id')) {
                    _clientPlayerMap[socket] = decoded['player_id'] as String;
                  }
                  _messageController.add(decoded);
                } catch (_) {
                  // Ignore malformed messages
                }
              },
              onError: (Object error) {
                _removeClient(socket);
              },
              onDone: () {
                _removeClient(socket);
              },
              cancelOnError: false,
            );
            _clientSubscriptions[socket] = sub;
          } catch (_) {
            // Upgrade failed; return 400
            try {
              request.response.statusCode = HttpStatus.badRequest;
              await request.response.close();
            } catch (_) {
              // Ignore response errors
            }
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      },
      onError: (Object error) {
        _messageController.addError(error);
      },
      cancelOnError: false,
    );
  }

  /// Remove a client socket and its subscription from internal tracking.
  /// If the client had previously sent a "join" message, notifies the lobby
  /// by pushing a [_client_disconnected] event.
  void _removeClient(WebSocket socket) {
    // Notify lobby about the unexpected disconnection before cleanup
    final playerId = _clientPlayerMap.remove(socket);
    if (playerId != null) {
      _messageController.add({
        'type': '_client_disconnected',
        'player_id': playerId,
      });
    }

    _clients.remove(socket);
    final sub = _clientSubscriptions.remove(socket);
    sub?.cancel();
  }

  // ── Client: connect to a host ──────────────────────────────────────────────

  /// Connect to a remote host at [host]:[port] via WebSocket.
  ///
  /// The returned future completes when the connection is established. All
  /// received messages are parsed as JSON and forwarded to the
  /// [_messageController] stream.
  Future<void> connectToHost(String host, int port) async {
    if (_socket != null) {
      throw StateError('Already connected');
    }

    final uri = Uri.parse('ws://$host:$port');
    _socket = await WebSocket.connect(uri.toString());
    _isHost = false;

    _socket!.listen(
      (dynamic data) {
        try {
          final decoded = jsonDecode(data as String) as Map<String, dynamic>;
          _messageController.add(decoded);
        } catch (_) {
          // Ignore malformed messages
        }
      },
      onError: (Object error) {
        _messageController.addError(error);
      },
      onDone: () {
        // Connection closed remotely
      },
      cancelOnError: false,
    );
  }

  // ── Send message ───────────────────────────────────────────────────────────

  /// Serialize [message] to JSON and send it over the WebSocket connection.
  ///
  /// - **Host**: broadcasts to all connected clients (does not echo back to
  ///   the host itself).
  /// - **Client**: sends the message to the host.
  Future<void> sendMessage(Map<String, dynamic> message) async {
    final encoded = jsonEncode(message);

    if (_isHost) {
      // Broadcast to all connected clients
      final deadSockets = <WebSocket>[];
      for (final client in _clients) {
        try {
          client.add(encoded);
        } catch (_) {
          deadSockets.add(client);
        }
      }
      // Clean up any dead sockets
      for (final dead in deadSockets) {
        _removeClient(dead);
      }
    } else if (_socket != null) {
      _socket!.add(encoded);
    }
  }

  // ── Session management ─────────────────────────────────────────────────────

  /// Assign a session ID (called when a game starts).
  void setSessionId(String id) {
    _sessionId = id;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Close all connections and release resources.
  void dispose() {
    // Cancel server HTTP request subscription
    _serverSubscription?.cancel();
    _serverSubscription = null;

    // Cancel all client subscriptions
    for (final sub in _clientSubscriptions.values) {
      sub.cancel();
    }
    _clientSubscriptions.clear();

    // Clear the client-player mapping
    _clientPlayerMap.clear();

    // Close all client sockets
    for (final client in _clients) {
      try {
        client.close();
      } catch (_) {
        // Ignore errors during cleanup
      }
    }
    _clients.clear();

    // Close the primary socket (client mode)
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;

    // Close the HTTP server (host mode)
    try {
      _httpServer?.close();
    } catch (_) {}
    _httpServer = null;

    // Close the stream controller
    if (!_messageController.isClosed) {
      _messageController.close();
    }

    _isHost = false;
    _sessionId = null;
  }
}
