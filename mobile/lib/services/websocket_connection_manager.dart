// ABOUTME: Event-driven WebSocket connection manager with state machine and exponential backoff
// ABOUTME: Replaces timing-based reconnection with proper async patterns

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:openvine/services/websocket_adapter.dart';
import 'package:openvine/utils/unified_logger.dart';

/// Connection states for the WebSocket
enum ConnectionState {
  disconnected,
  connecting,
  authenticating,
  connected,
}

/// Interface for WebSocket to allow testing
abstract class WebSocketInterface {
  Stream<void> get onOpen;
  Stream<void> get onClose;
  Stream<String> get onError;
  Stream<Map<String, dynamic>> get onMessage;
  bool get isOpen;
  Future<void> connect();
  void send(Map<String, dynamic> data);
  void close();
}

/// Factory for creating WebSocket instances
abstract class WebSocketFactory {
  WebSocketInterface create(String url);
}

/// Manages WebSocket connection with proper state machine and reconnection
/// REFACTORED: Removed ChangeNotifier - now uses pure state management via Riverpod
class WebSocketConnectionManager  {
  WebSocketConnectionManager({
    required this.url,
    required this.socketFactory,
  });
  final String url;
  final WebSocketFactory socketFactory;

  WebSocketInterface? _socket;
  ConnectionState _state = ConnectionState.disconnected;
  Timer? _reconnectTimer;
  Timer? _healthCheckTimer;
  int _reconnectAttempts = 0;
  bool _autoReconnectEnabled = false;
  Duration _healthCheckInterval = const Duration(seconds: 30);
  Duration _healthCheckTimeout = const Duration(seconds: 5);

  // Exponential backoff configuration
  static const Duration _initialReconnectDelay = Duration(seconds: 1);
  static const Duration _maxReconnectDelay = Duration(seconds: 30);
  static const double _backoffMultiplier = 2;

  // Stream controllers
  final _stateController = StreamController<ConnectionState>.broadcast();
  final _reconnectDelayController = StreamController<Duration>.broadcast();
  final _healthCheckController = StreamController<void>.broadcast();
  final _connectedController = StreamController<void>.broadcast();

  // Pending operations
  final Map<String, Completer<Map<String, dynamic>>> _pendingOperations = {};
  Completer<void>? _readyCompleter;

  // Getters
  ConnectionState get state => _state;
  bool get isConnected => _state == ConnectionState.connected;
  Stream<ConnectionState> get stateStream => _stateController.stream;
  Stream<Duration> get reconnectDelayStream => _reconnectDelayController.stream;
  Stream<void> get healthCheckStream => _healthCheckController.stream;
  Stream<void> get onConnected => _connectedController.stream;

  /// Connect to the WebSocket
  Future<void> connect() async {
    if (_state != ConnectionState.disconnected) {
      Log.warning(
        'Already connecting or connected to $url',
        name: 'WebSocketConnectionManager',
        category: LogCategory.system,
      );
      return;
    }

    _setState(ConnectionState.connecting);

    try {
      _socket = socketFactory.create(url);
      _setupSocketListeners();
      // Start the connection
      await _socket!.connect();
    } catch (e) {
      Log.error(
        'Failed to create WebSocket for $url: $e',
        name: 'WebSocketConnectionManager',
        category: LogCategory.system,
      );
      _handleConnectionFailure();
    }
  }

  /// Setup listeners for WebSocket events
  void _setupSocketListeners() {
    _socket?.onOpen.listen((_) {
      Log.info(
        'WebSocket connected to $url',
        name: 'WebSocketConnectionManager',
        category: LogCategory.system,
      );
      _handleConnectionSuccess();
    });

    _socket?.onError.listen((error) {
      Log.error(
        'WebSocket error on $url: $error',
        name: 'WebSocketConnectionManager',
        category: LogCategory.system,
      );
      _handleConnectionFailure();
    });

    _socket?.onClose.listen((_) {
      Log.info(
        'WebSocket closed for $url',
        name: 'WebSocketConnectionManager',
        category: LogCategory.system,
      );
      _handleConnectionClosed();
    });

    _socket?.onMessage.listen(_handleMessage);
  }

  /// Handle successful connection
  void _handleConnectionSuccess() {
    _reconnectAttempts = 0; // Reset backoff
    _setState(ConnectionState.connected);
    _connectedController.add(null);

    // Complete ready completer if waiting
    _readyCompleter?.complete();
    _readyCompleter = null;

    // Start health checking if enabled
    if (_healthCheckInterval.inSeconds > 0) {
      _startHealthChecking();
    }
  }

  /// Handle connection failure
  void _handleConnectionFailure() {
    _setState(ConnectionState.disconnected);
    _socket = null;

    if (_autoReconnectEnabled) {
      _scheduleReconnect();
    }
  }

  /// Handle connection closed
  void _handleConnectionClosed() {
    _setState(ConnectionState.disconnected);
    _socket = null;
    _stopHealthChecking();

    // Fail any pending operations
    for (final completer in _pendingOperations.values) {
      if (!completer.isCompleted) {
        completer.completeError('Connection closed');
      }
    }
    _pendingOperations.clear();

    if (_autoReconnectEnabled) {
      _scheduleReconnect();
    }
  }

  /// Handle incoming messages
  void _handleMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;

    switch (type) {
      case 'AUTH':
        _setState(ConnectionState.authenticating);

      case 'OK':
      case 'ACK':
        final id = message['id'] as String?;
        if (id != null && _pendingOperations.containsKey(id)) {
          _pendingOperations[id]?.complete(message);
          _pendingOperations.remove(id);
        }

      case 'PONG':
        // Health check response
        _healthCheckController.add(null);
    }
  }

  /// Complete authentication
  void completeAuthentication(String response) {
    if (_state == ConnectionState.authenticating) {
      _socket?.send({
        'type': 'AUTH_RESPONSE',
        'response': response,
      });
      _setState(ConnectionState.connected);
      _connectedController.add(null);
    }
  }

  /// Enable auto-reconnect
  void enableAutoReconnect() {
    _autoReconnectEnabled = true;
  }

  /// Schedule reconnection with exponential backoff
  void _scheduleReconnect() {
    // Calculate delay with exponential backoff
    final delay = _calculateReconnectDelay();
    _reconnectDelayController.add(delay);

    Log.info(
      'Scheduling reconnect to $url in ${delay.inSeconds}s (attempt ${_reconnectAttempts + 1})',
      name: 'WebSocketConnectionManager',
      category: LogCategory.system,
    );

    // Use Timer instead of Future.delayed
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnectAttempts++;
      connect();
    });
  }

  /// Calculate reconnect delay with exponential backoff
  Duration _calculateReconnectDelay() {
    if (_reconnectAttempts == 0) {
      return _initialReconnectDelay;
    }

    final exponentialDelay = _initialReconnectDelay.inMilliseconds *
        math.pow(_backoffMultiplier, _reconnectAttempts - 1);

    final delayMs = math
        .min(
          exponentialDelay,
          _maxReconnectDelay.inMilliseconds.toDouble(),
        )
        .round();

    return Duration(milliseconds: delayMs);
  }

  /// Send data with acknowledgment
  Future<Map<String, dynamic>> sendWithAck(Map<String, dynamic> data) {
    if (!isConnected) {
      return Future.error('Not connected');
    }

    final id = data['id'] as String? ??
        DateTime.now().millisecondsSinceEpoch.toString();
    data['id'] = id;

    final completer = Completer<Map<String, dynamic>>();
    _pendingOperations[id] = completer;

    _socket?.send(data);

    // Timeout after 30 seconds
    Timer(const Duration(seconds: 30), () {
      if (_pendingOperations.containsKey(id)) {
        _pendingOperations[id]?.completeError('Operation timeout');
        _pendingOperations.remove(id);
      }
    });

    return completer.future;
  }

  /// Wait until connection is ready
  Future<void> waitUntilReady() {
    if (isConnected) {
      return Future.value();
    }

    _readyCompleter ??= Completer<void>();
    return _readyCompleter!.future;
  }

  /// Enable health checking
  void enableHealthChecking({
    Duration interval = const Duration(seconds: 30),
    Duration timeout = const Duration(seconds: 5),
  }) {
    _healthCheckInterval = interval;
    _healthCheckTimeout = timeout;

    if (isConnected) {
      _startHealthChecking();
    }
  }

  /// Start health check timer
  void _startHealthChecking() {
    _stopHealthChecking();

    _healthCheckTimer = Timer.periodic(_healthCheckInterval, (_) {
      triggerHealthCheck();
    });
  }

  /// Stop health check timer
  void _stopHealthChecking() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
  }

  /// Trigger a health check
  void triggerHealthCheck() {
    if (!isConnected) return;

    _socket?.send({'type': 'PING'});

    // Set timeout for response
    Timer(_healthCheckTimeout, () {
      if (isConnected) {
        Log.error(
          'Health check timeout for $url',
          name: 'WebSocketConnectionManager',
          category: LogCategory.system,
        );
        simulateHealthCheckTimeout();
      }
    });
  }

  /// Simulate health check timeout (for testing)
  @visibleForTesting
  void simulateHealthCheckTimeout() {
    _handleConnectionFailure();
  }

  /// Update state and notify listeners
  void _setState(ConnectionState newState) {
    if (_state != newState) {
      _state = newState;
      // Use scheduleMicrotask to ensure stream events are processed
      scheduleMicrotask(() {
        if (!_stateController.isClosed) {
          _stateController.add(newState);
        }
      });

    }
  }

  /// Dispose of resources
  void dispose() {
    _reconnectTimer?.cancel();
    _healthCheckTimer?.cancel();
    _socket?.close();
    _stateController.close();
    _reconnectDelayController.close();
    _healthCheckController.close();
    _connectedController.close();

    // Complete any pending operations with error
    for (final completer in _pendingOperations.values) {
      if (!completer.isCompleted) {
        completer.completeError('Manager disposed');
      }
    }
    _pendingOperations.clear();

    
  }
}

/// Pool for managing multiple WebSocket connections
/// REFACTORED: Removed ChangeNotifier - now uses pure state management via Riverpod
class WebSocketConnectionPool {
  final Map<String, WebSocketConnectionManager> _connections = {};

  /// Get total number of connections
  int get connectionCount => _connections.length;

  /// Get number of connected connections
  int get connectedCount =>
      _connections.values.where((c) => c.isConnected).length;

  /// Check if all connections are connected
  bool get allConnected =>
      _connections.isNotEmpty &&
      _connections.values.every((c) => c.isConnected);

  /// Create a new connection
  WebSocketConnectionManager createConnection(String url) {
    if (_connections.containsKey(url)) {
      return _connections[url]!;
    }

    final manager = WebSocketConnectionManager(
      url: url,
      socketFactory: PlatformWebSocketFactory(),
    );

    _connections[url] = manager;
    return manager;
  }

  /// Remove a connection
  void removeConnection(String url) {
    final connection = _connections.remove(url);
    connection?.dispose();
  }

  /// Dispose all connections
  void dispose() {
    for (final connection in _connections.values) {
      connection.dispose();
    }
    _connections.clear();
  }
}

/// Default WebSocket factory using platform adapter
/// REFACTORED: Removed ChangeNotifier - now uses pure state management via Riverpod
class DefaultWebSocketFactory implements WebSocketFactory {
  @override
  WebSocketInterface create(String url) {
    // Import is handled in websocket_adapter.dart
    throw UnimplementedError(
        'Use PlatformWebSocketFactory from websocket_adapter.dart');
  }
}
