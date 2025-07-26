// ABOUTME: Unified NostrService using nostr_sdk's RelayPool with full relay management
// ABOUTME: Combines best features of v1 and v2 - SDK reliability with custom relay management

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:nostr_sdk/event.dart';
import 'package:nostr_sdk/filter.dart';
import 'package:nostr_sdk/nostr.dart';
import 'package:nostr_sdk/relay/client_connected.dart';
import 'package:nostr_sdk/relay/event_filter.dart';
import 'package:nostr_sdk/relay/relay.dart';
import 'package:nostr_sdk/relay/relay_base.dart';
import 'package:nostr_sdk/relay/relay_status.dart' as sdk;
import 'package:nostr_sdk/signer/local_nostr_signer.dart';
import 'package:openvine/models/nip94_metadata.dart';
import 'package:openvine/services/background_activity_manager.dart';
import 'package:openvine/services/connection_status_service.dart';
import 'package:openvine/services/nostr_key_manager.dart';
import 'package:openvine/services/nostr_service_interface.dart';
import 'package:openvine/utils/unified_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Relay connection status
enum RelayStatus { connected, connecting, disconnected }

/// Exception for NostrService errors
/// REFACTORED: Removed ChangeNotifier - now uses pure state management via Riverpod
class NostrServiceException implements Exception {
  NostrServiceException(this.message);
  final String message;

  @override
  String toString() => 'NostrServiceException: $message';
}

/// Unified NostrService implementation using nostr_sdk
/// REFACTORED: Removed ChangeNotifier - now uses pure state management via Riverpod
class NostrService  implements INostrService, BackgroundAwareService {
  // Our ID -> SDK subscription ID

  NostrService(this._keyManager);
  static const List<String> defaultRelays = [
    'wss://relay3.openvine.co',  // Primary OpenVine relay
  ];

  // Relay selection constants  
  static const String primaryRelayUrl = 'wss://relay3.openvine.co';

  static const String _relaysPrefsKey = 'custom_relays';
  static const String _authStatePrefsKey = 'auth_states';

  final NostrKeyManager _keyManager;
  final ConnectionStatusService _connectionService = ConnectionStatusService();

  Nostr? _nostrClient;
  bool _isInitialized = false;
  bool _isDisposed = false;
  final List<String> _connectedRelays = [];
  final List<String> _relays = []; // All configured relays
  final Map<String, Relay> _relayInstances =
      {}; // Keep relay instances for management

  // Track active subscriptions for cleanup
  final Map<String, String> _activeSubscriptions = {};
  
  // Background activity management
  bool _isInBackground = false;
  bool _isBackgroundSuspended = false;
  Timer? _reconnectionTimer;
  
  // AUTH state tracking and persistence
  final Map<String, bool> _relayAuthStates = {}; // relay URL -> auth status
  final Map<String, DateTime> _relayAuthTimestamps = {}; // relay URL -> auth time
  static const Duration _authSessionTimeout = Duration(hours: 24); // Auth session validity
  
  // Configurable AUTH timeout
  Duration _authTimeout = const Duration(seconds: 15); // Increased from 10s
  
  // Stream controllers for AUTH state notifications
  final StreamController<Map<String, bool>> _authStateController =
      StreamController<Map<String, bool>>.broadcast();

  // INostrService implementation
  @override
  bool get isInitialized => _isInitialized && !_isDisposed;

  @override
  bool get isDisposed => _isDisposed;

  @override
  List<String> get connectedRelays => List.unmodifiable(_connectedRelays);

  @override
  String? get publicKey => _isDisposed ? null : _keyManager.publicKey;

  @override
  bool get hasKeys => _isDisposed ? false : _keyManager.hasKeys;

  @override
  NostrKeyManager get keyManager => _keyManager;

  @override
  int get relayCount => _connectedRelays.length;

  @override
  int get connectedRelayCount => _connectedRelays.length;

  @override
  List<String> get relays => List.unmodifiable(_relays);
  @override
  Map<String, dynamic> get relayStatuses {
    final statuses = <String, dynamic>{};
    for (final url in _relays) {
      final relay = _relayInstances[url];
      if (relay != null) {
        statuses[url] =
            relay.relayStatus.connected == ClientConneccted.CONNECTED
                ? 'connected'
                : 'disconnected';
      } else {
        statuses[url] = 'disconnected';
      }
    }
    return statuses;
  }

  /// Get AUTH states for all relays
  @override
  Map<String, bool> get relayAuthStates => Map.unmodifiable(_relayAuthStates);

  /// Stream of AUTH state changes
  @override
  Stream<Map<String, bool>> get authStateStream => _authStateController.stream;

  /// Check if a specific relay is authenticated
  @override
  bool isRelayAuthenticated(String relayUrl) {
    final authState = _relayAuthStates[relayUrl];
    final authTime = _relayAuthTimestamps[relayUrl];
    
    if (authState != true || authTime == null) {
      return false;
    }
    
    // Check if auth session is still valid
    final sessionAge = DateTime.now().difference(authTime);
    return sessionAge < _authSessionTimeout;
  }

  /// Check if primary relay is authenticated (not needed for strfry but kept for compatibility)
  @override
  bool get isVineRelayAuthenticated => isRelayAuthenticated(primaryRelayUrl);

  /// Set configurable AUTH timeout
  @override
  void setAuthTimeout(Duration timeout) {
    _authTimeout = timeout;
    Log.info('AUTH timeout set to ${timeout.inSeconds}s',
        name: 'NostrService', category: LogCategory.relay);
  }

  @override
  Future<void> initialize({List<String>? customRelays}) async {
    if (_isInitialized) {
      Log.warning('⚠️ NostrService already initialized',
          category: LogCategory.relay);
      return;
    }

    try {
      // Initialize connection service with web-specific error handling
      if (kIsWeb) {
        try {
          await _connectionService.initialize();
        } catch (e) {
          Log.warning('⚠️ Connection service init failed on web (expected): $e',
              category: LogCategory.relay);
          // On web, assume we're online and continue
        }
      } else {
        await _connectionService.initialize();
      }

      // Check connectivity (skip on web where connectivity check might fail)
      if (!kIsWeb && !_connectionService.isOnline) {
        Log.warning('⚠️ Device appears to be offline',
            category: LogCategory.relay);
        throw NostrServiceException('Device is offline');
      }

      // Initialize key manager
      if (!_keyManager.isInitialized) {
        await _keyManager.initialize();
      }

      // Ensure we have keys
      if (!_keyManager.hasKeys) {
        Log.info('🔑 No keys found, generating new identity...',
            category: LogCategory.auth);
        await _keyManager.generateKeys();
      }

      // Get private key for signer
      final keyPair = _keyManager.keyPair;
      if (keyPair == null) {
        throw NostrServiceException('Failed to get key pair');
      }
      final privateKey = keyPair.private;

      // Create signer
      final signer = LocalNostrSigner(privateKey);

      // Get public key
      final pubKey = await signer.getPublicKey();
      if (pubKey == null) {
        throw NostrServiceException('Failed to get public key from signer');
      }

      // Load saved relays from preferences
      final prefs = await SharedPreferences.getInstance();
      final savedRelays = prefs.getStringList(_relaysPrefsKey);

      // Load persisted AUTH states
      await _loadPersistedAuthStates();

      // Use saved relays, custom relays, or default relays (in that order)
      final relaysToConnect = savedRelays ?? customRelays ?? defaultRelays;
      _relays.clear();
      _relays.addAll(relaysToConnect);

      // Notify listeners about relay list


      // Create event filters (we'll handle subscriptions manually)
      final eventFilters = <EventFilter>[];

      // Initialize Nostr client with relay factory
      _nostrClient = Nostr(
        signer,
        pubKey,
        eventFilters,
        (url) => RelayBase(url, sdk.RelayStatus(url)),
        onNotice: (relayUrl, notice) {
          Log.info('📢 Notice from $relayUrl: $notice',
              category: LogCategory.relay);
        },
      );

      // Add relays - configure authentication FIRST, then connect
      for (final relayUrl in relaysToConnect) {
        try {
          final relay = RelayBase(relayUrl, sdk.RelayStatus(relayUrl));

          // relay.damus.io doesn't require special authentication configuration

          final success =
              await _nostrClient!.addRelay(relay, autoSubscribe: true);
          if (success) {
            _connectedRelays.add(relayUrl);
            _relayInstances[relayUrl] = relay;
            Log.info('✅ Connected to relay: $relayUrl',
                category: LogCategory.relay);
          } else {
            Log.error('Failed to connect to relay: $relayUrl',
                name: 'NostrService', category: LogCategory.relay);
          }
        } catch (e) {
          Log.error('Error connecting to relay $relayUrl: $e',
              name: 'NostrService', category: LogCategory.relay);
        }
      }

      if (_connectedRelays.isEmpty) {
        throw NostrServiceException('Failed to connect to any relays');
      }

      // Wait for AUTH completion - now returns success status
      await _waitForAuthCompletion();

      // Log final relay states
      final relays = _nostrClient!.activeRelays();
      for (final relay in relays) {
        _relayInstances[relay.url] = relay;
        Log.debug('Post-AUTH relay status for ${relay.url}:',
            name: 'NostrService', category: LogCategory.relay);
        Log.info(
            '  - Connected: ${relay.relayStatus.connected == ClientConneccted.CONNECTED}',
            name: 'NostrService',
            category: LogCategory.relay);
        Log.debug('  - Authed: ${relay.relayStatus.authed}',
            name: 'NostrService', category: LogCategory.relay);
        Log.debug('  - AlwaysAuth: ${relay.relayStatus.alwaysAuth}',
            name: 'NostrService', category: LogCategory.relay);
        Log.debug(
            '  - Pending authed messages: ${relay.pendingAuthedMessages.length}',
            name: 'NostrService',
            category: LogCategory.relay);
        Log.debug('  - Read access: ${relay.relayStatus.readAccess}',
            name: 'NostrService', category: LogCategory.relay);
        Log.debug('  - Write access: ${relay.relayStatus.writeAccess}',
            name: 'NostrService', category: LogCategory.relay);
      }

      _isInitialized = true;
      
      // Register with background activity manager
      try {
        BackgroundActivityManager().registerService(this);
        Log.debug('📱 Registered NostrService with background activity manager',
            name: 'NostrService', category: LogCategory.relay);
      } catch (e) {
        Log.warning('Could not register with background activity manager: $e',
            name: 'NostrService', category: LogCategory.relay);
      }
      
      Log.info(
          'NostrService initialized with ${_connectedRelays.length} relays',
          name: 'NostrService',
          category: LogCategory.relay);

    } catch (e) {
      Log.error('Failed to initialize NostrService: $e',
          name: 'NostrService', category: LogCategory.relay);
      rethrow;
    }
  }

  /// Wait for AUTH completion (simplified for strfry - no auth needed)
  Future<bool> _waitForAuthCompletion() async {
    final checkInterval = Duration(milliseconds: 200);
    final startTime = DateTime.now();

    Log.info('🔐 Waiting for AUTH completion on relays (timeout: ${_authTimeout.inSeconds}s)...',
        name: 'NostrService', category: LogCategory.relay);

    while (DateTime.now().difference(startTime) < _authTimeout) {
      final relays = _nostrClient!.activeRelays();
      bool anyAuthPending = false;
      bool authStateChanged = false;

      for (final relay in relays) {
        final status = relay.relayStatus;
        final url = relay.url;

        // strfry doesn't require auth, so skip auth checks for primaryRelayUrl
        final requiresAuth = !url.contains(primaryRelayUrl) && status.alwaysAuth;
        
        if (requiresAuth) {
          final wasAuthed = _relayAuthStates[url] ?? false;
          final isNowAuthed = status.authed;
          
          if (!isNowAuthed) {
            anyAuthPending = true;
            Log.debug('⏳ Still waiting for AUTH on $url (authed: ${status.authed})',
                name: 'NostrService', category: LogCategory.relay);
          } else {
            if (!wasAuthed) {
              Log.info('✅ AUTH completed on $url',
                  name: 'NostrService', category: LogCategory.relay);
              _relayAuthStates[url] = true;
              _relayAuthTimestamps[url] = DateTime.now();
              authStateChanged = true;
              
              // Persist the auth state
              await _persistAuthState(url, true);
            }
          }
        } else {
          // Non-auth relay, consider it "ready"
          Log.debug('📡 Non-auth relay ready: $url',
              name: 'NostrService', category: LogCategory.relay);
          if (_relayAuthStates[url] != true) {
            _relayAuthStates[url] = true;
            _relayAuthTimestamps[url] = DateTime.now();
            authStateChanged = true;
          }
        }
      }

      // Notify listeners if auth state changed
      if (authStateChanged) {
        _authStateController.add(Map.from(_relayAuthStates));

      }

      // If no auth is pending, we're done
      if (!anyAuthPending) {
        Log.info('🔓 All required AUTH operations completed',
            name: 'NostrService', category: LogCategory.relay);
        return true;
      }

      // Wait a bit before checking again
      await Future.delayed(checkInterval);
    }

    // Since we're using strfry (no auth), just return true
    Log.info('✅ Using strfry relay - no auth required',
        name: 'NostrService', category: LogCategory.relay);
    return true;
  }

  @override
  Stream<Event> subscribeToEvents({
    required List<Filter> filters,
    bool bypassLimits = false, // Not needed in v2 - SDK handles limits
  }) {
    if (!_isInitialized) {
      throw NostrServiceException('Nostr service not initialized');
    }

    // Convert our Filter objects to SDK filter format
    final sdkFilters = filters.map((filter) => filter.toJson()).toList();

    // Create stream controller for this subscription
    final controller = StreamController<Event>.broadcast();

    // Generate unique subscription ID with more entropy to prevent collisions
    final subscriptionId =
        '${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}_${Object().hashCode}';

    Log.info('🔍 NostrService: Creating subscription $subscriptionId with filters:',
        name: 'NostrService', category: LogCategory.relay);
    for (int i = 0; i < sdkFilters.length; i++) {
      final filter = sdkFilters[i];
      Log.info('  - Filter $i JSON: $filter',
          name: 'NostrService', category: LogCategory.relay);
    }
    
    // Log what the WebSocket message will look like
    final webSocketMessage = jsonEncode(['REQ', subscriptionId, ...sdkFilters]);
    Log.info('🔍 NostrService: WebSocket REQ message that will be sent:',
        name: 'NostrService', category: LogCategory.relay);
    Log.info('  - WebSocket JSON: $webSocketMessage',
        name: 'NostrService', category: LogCategory.relay);
    
    // Compare to working nak format for debugging
    if (sdkFilters.length == 1 && sdkFilters[0]['kinds']?.contains(22) == true) {
      Log.info('🔍 NostrService: This is a Kind 22 subscription - comparing to working nak:',
          name: 'NostrService', category: LogCategory.relay);
      Log.info('  - Working nak: ["REQ","test_kind22",{"kinds":[22],"limit":5}]',
          name: 'NostrService', category: LogCategory.relay);
      Log.info('  - Our message: $webSocketMessage',
          name: 'NostrService', category: LogCategory.relay);
    }

    // Create subscription using SDK
    final sdkSubId = _nostrClient!.subscribe(
      sdkFilters,
      (event) {
        Log.verbose(
            '📱 Received event in NostrServiceV2 callback: kind=${event.kind}, id=${event.id.substring(0, 8)}...',
            name: 'NostrService',
            category: LogCategory.relay);
        // Forward events to our stream
        controller.add(event);
      },
      id: subscriptionId,
    );

    // Also listen to the raw relay pool to see if events are coming in
    Log.debug('Checking relay pool state...',
        name: 'NostrService', category: LogCategory.relay);
    final relays = _nostrClient!.activeRelays();
    for (final relay in relays) {
      Log.info(
          '  - Relay ${relay.url}: connected=${relay.relayStatus.connected == ClientConneccted.CONNECTED}, authed=${relay.relayStatus.authed}',
          name: 'NostrService',
          category: LogCategory.relay);
    }

    // Track subscription for cleanup
    _activeSubscriptions[subscriptionId] = sdkSubId;

    Log.info(
        'Created subscription $subscriptionId (SDK ID: $sdkSubId) with ${filters.length} filters',
        name: 'NostrService',
        category: LogCategory.relay);

    // Handle stream cancellation
    controller.onCancel = () {
      final sdkId = _activeSubscriptions.remove(subscriptionId);
      if (sdkId != null) {
        _nostrClient?.unsubscribe(sdkId);
      }
    };

    return controller.stream;
  }

  @override
  Future<NostrBroadcastResult> broadcastEvent(Event event) async {
    if (!_isInitialized || !hasKeys) {
      throw NostrServiceException(
          'NostrService not initialized or no keys available');
    }

    Log.info('📤 Broadcasting event:',
        name: 'NostrService', category: LogCategory.relay);
    Log.info('  - Event ID: ${event.id}',
        name: 'NostrService', category: LogCategory.relay);
    Log.info('  - Kind: ${event.kind}',
        name: 'NostrService', category: LogCategory.relay);
    Log.info('  - Pubkey: ${event.pubkey.substring(0, 8)}...',
        name: 'NostrService', category: LogCategory.relay);
    Log.info(
        '  - Content: ${event.content.substring(0, math.min(100, event.content.length))}...',
        name: 'NostrService',
        category: LogCategory.relay);
    Log.info('  - Created at: ${event.createdAt}',
        name: 'NostrService', category: LogCategory.relay);
    Log.info('  - Tags: ${event.tags}',
        name: 'NostrService', category: LogCategory.relay);

    // CRITICAL DEBUG: Log the exact JSON that will be sent to the relay
    final eventJson = event.toJson();
    Log.info('🔍 WEBSOCKET EVENT JSON being sent to relay:',
        name: 'NostrService', category: LogCategory.relay);
    Log.info('   Raw JSON: $eventJson',
        name: 'NostrService', category: LogCategory.relay);

    // DEBUG: Verify event JSON structure
    Log.debug('🔍 DEBUG: Event toJson() type: ${eventJson.runtimeType}',
        name: 'NostrService', category: LogCategory.relay);

    // Verify event data types
    try {
      assert(eventJson['id'] is String,
          'id must be String, got ${eventJson['id'].runtimeType}');
      assert(eventJson['pubkey'] is String,
          'pubkey must be String, got ${eventJson['pubkey'].runtimeType}');
      assert(eventJson['created_at'] is int,
          'created_at must be int, got ${eventJson['created_at'].runtimeType}');
      assert(eventJson['kind'] is int,
          'kind must be int, got ${eventJson['kind'].runtimeType}');
      assert(eventJson['tags'] is List,
          'tags must be List, got ${eventJson['tags'].runtimeType}');
      assert(eventJson['content'] is String,
          'content must be String, got ${eventJson['content'].runtimeType}');
      assert(eventJson['sig'] is String,
          'sig must be String, got ${eventJson['sig'].runtimeType}');

      // Check tags structure
      for (var i = 0; i < eventJson['tags'].length; i++) {
        final tag = eventJson['tags'][i];
        assert(tag is List, 'Tag $i must be List, got ${tag.runtimeType}');
        for (var j = 0; j < tag.length; j++) {
          final item = tag[j];
          assert(item is String,
              'Tag $i item $j must be String, got ${item.runtimeType}: $item');
        }
      }

      Log.debug('✅ Event data types are correct',
          name: 'NostrService', category: LogCategory.relay);
    } catch (e) {
      Log.warning('❌ ERROR: Event data type validation failed: $e',
          name: 'NostrService', category: LogCategory.relay);
    }

    try {
      final testJson = jsonEncode(eventJson);
      Log.debug(
          '🔍 DEBUG: Event JSON-encodes successfully to: ${testJson.substring(0, math.min(200, testJson.length))}...',
          name: 'NostrService', category: LogCategory.relay);
    } catch (e) {
      Log.error('❌ ERROR: Event cannot be JSON-encoded: $e',
          name: 'NostrService', category: LogCategory.relay);
    }

    // Also log as EVENT message format that goes over WebSocket
    final eventMessage = ['EVENT', eventJson];
    Log.info('🔍 WEBSOCKET MESSAGE FORMAT being sent:',
        name: 'NostrService', category: LogCategory.relay);
    Log.info('   WebSocket Message: $eventMessage',
        name: 'NostrService', category: LogCategory.relay);

    // CRITICAL: Check if signature is getting corrupted
    Log.debug('🔍 SIGNATURE CORRUPTION CHECK:',
        name: 'NostrService', category: LogCategory.relay);
    Log.debug('   Original event.sig: ${event.sig}',
        name: 'NostrService', category: LogCategory.relay);
    Log.debug('   EventJson["sig"]: ${eventJson["sig"]}',
        name: 'NostrService', category: LogCategory.relay);
    final eventMessageData = eventMessage[1] as Map<String, dynamic>;
    Log.debug('   In eventMessage[1]["sig"]: ${eventMessageData["sig"]}',
        name: 'NostrService', category: LogCategory.relay);
    if (event.sig != eventJson['sig']) {
      Log.error('❌ SIGNATURE MISMATCH: event.sig != eventJson["sig"]',
          name: 'NostrService', category: LogCategory.relay);
    } else {
      Log.debug('✅ Signatures match between event and eventJson',
          name: 'NostrService', category: LogCategory.relay);
    }

    // Verify complete message can be JSON encoded
    try {
      jsonEncode(eventMessage);
    } catch (e) {
      Log.error('❌ ERROR: Complete message cannot be JSON-encoded: $e',
          name: 'NostrService', category: LogCategory.relay);
    }

    try {
      // Sign and send event using SDK
      Log.info(
          '🔏 Signing and sending event to ${_connectedRelays.length} relays...',
          name: 'NostrService',
          category: LogCategory.relay);

      // DEBUG: Check which relay type is being used
      final relays = _nostrClient!.activeRelays();
      for (final relay in relays) {
        Log.debug('🔍 DEBUG: Relay type: ${relay.runtimeType}',
            name: 'NostrService', category: LogCategory.relay);
        Log.debug('🔍 DEBUG: Relay URL: ${relay.url}',
            name: 'NostrService', category: LogCategory.relay);
      }

      final sentEvent = await _nostrClient!.sendEvent(event);

      if (sentEvent != null) {
        Log.info('✅ Event broadcast successful:',
            name: 'NostrService', category: LogCategory.relay);
        Log.info('  - Sent event ID: ${sentEvent.id}',
            name: 'NostrService', category: LogCategory.relay);
        Log.info('  - Sent to relays: $_connectedRelays',
            name: 'NostrService', category: LogCategory.relay);

        // SDK doesn't provide per-relay results, so we'll assume success
        final results = <String, bool>{};
        final errors = <String, String>{};

        for (final relay in _connectedRelays) {
          results[relay] = true;
        }

        return NostrBroadcastResult(
          event: sentEvent,
          successCount: _connectedRelays.length,
          totalRelays: _connectedRelays.length,
          results: results,
          errors: errors,
        );
      } else {
        Log.error('❌ sendEvent returned null',
            name: 'NostrService', category: LogCategory.relay);
        throw NostrServiceException('Failed to broadcast event');
      }
    } catch (e) {
      Log.error('❌ Error broadcasting event: $e',
          name: 'NostrService', category: LogCategory.relay);
      rethrow;
    }
  }

  @override
  Future<NostrBroadcastResult> publishFileMetadata({
    required NIP94Metadata metadata,
    required String content,
    List<String> hashtags = const [],
  }) async {
    if (!_isInitialized || !hasKeys) {
      throw NostrServiceException(
          'NostrService not initialized or no keys available');
    }

    // Build tags for NIP-94 file metadata
    final tags = <List<String>>[];

    // Required tags
    tags.add(['url', metadata.url]);
    tags.add(['m', metadata.mimeType]);
    tags.add(['x', metadata.sha256Hash]);
    tags.add(['size', metadata.sizeBytes.toString()]);

    // Optional tags
    tags.add(['dim', metadata.dimensions]);
    if (metadata.blurhash != null) {
      tags.add(['blurhash', metadata.blurhash!]);
    }
    if (metadata.thumbnailUrl != null) {
      tags.add(['thumb', metadata.thumbnailUrl!]);
    }
    if (metadata.torrentHash != null) {
      tags.add(['i', metadata.torrentHash!]);
    }

    // Add hashtags
    for (final tag in hashtags) {
      if (tag.isNotEmpty) {
        tags.add(['t', tag.toLowerCase()]);
      }
    }

    // Create event
    final event = Event(
      publicKey!,
      1063, // NIP-94 file metadata
      tags,
      content,
    );

    return broadcastEvent(event);
  }

  @override
  Future<NostrBroadcastResult> publishVideoEvent({
    required String videoUrl,
    required String content,
    String? title,
    String? thumbnailUrl,
    int? duration,
    String? dimensions,
    String? mimeType,
    String? sha256,
    int? fileSize,
    List<String> hashtags = const [],
  }) async {
    if (!_isInitialized || !hasKeys) {
      throw NostrServiceException(
          'NostrService not initialized or no keys available');
    }

    // Build tags for NIP-71 video event
    final tags = <List<String>>[];

    // Required: video URL
    tags.add(['url', videoUrl]);

    // Optional metadata
    if (title != null && title.isNotEmpty) tags.add(['title', title]);
    if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
      tags.add(['thumb', thumbnailUrl]);
    }
    if (duration != null) tags.add(['duration', duration.toString()]);
    if (dimensions != null && dimensions.isNotEmpty) {
      tags.add(['dim', dimensions]);
    }
    if (mimeType != null && mimeType.isNotEmpty) tags.add(['m', mimeType]);
    if (sha256 != null && sha256.isNotEmpty) tags.add(['x', sha256]);
    if (fileSize != null) tags.add(['size', fileSize.toString()]);

    // Add hashtags
    for (final tag in hashtags) {
      if (tag.isNotEmpty) {
        tags.add(['t', tag.toLowerCase()]);
      }
    }

    // Add client tag
    tags.add(['client', 'openvine']);

    // Create event
    final event = Event(
      publicKey!,
      22, // Kind 22 for short video (NIP-71)
      tags,
      content,
    );

    return broadcastEvent(event);
  }

  /// Add a new relay
  @override
  Future<bool> addRelay(String relayUrl) async {
    if (_relays.contains(relayUrl)) {
      return true; // Already in list
    }

    try {
      Log.debug('📱 Adding new relay: $relayUrl',
          name: 'NostrService', category: LogCategory.relay);

      // Add to relay list and save
      _relays.add(relayUrl);
      await _saveRelays();

      // Let SDK handle the connection
      final relay = RelayBase(relayUrl, sdk.RelayStatus(relayUrl));
      final success = await _nostrClient!.addRelay(relay, autoSubscribe: true);

      if (success) {
        _relayInstances[relayUrl] = relay;
        _connectedRelays.add(relayUrl);

        return true;
      } else {
        // Remove from lists if connection failed
        _relays.remove(relayUrl);
        await _saveRelays();
        return false;
      }
    } catch (e) {
      Log.error('Failed to add relay $relayUrl: $e',
          name: 'NostrService', category: LogCategory.relay);
      // Clean up on error
      _relays.remove(relayUrl);
      _relayInstances.remove(relayUrl);
      await _saveRelays();
      return false;
    }
  }

  /// Remove a relay
  @override
  Future<void> removeRelay(String relayUrl) async {
    try {
      // Remove from SDK
      if (_nostrClient != null) {
        _nostrClient!.removeRelay(relayUrl);
      }

      // Remove from our tracking
      _connectedRelays.remove(relayUrl);
      _relays.remove(relayUrl);
      _relayInstances.remove(relayUrl);

      // Save updated relay list
      await _saveRelays();

      if (!_isDisposed) {

      }
      Log.info('📱 Disconnected from relay: $relayUrl',
          name: 'NostrService', category: LogCategory.relay);
    } catch (e) {
      Log.error('Error removing relay $relayUrl: $e',
          name: 'NostrService', category: LogCategory.relay);
    }
  }

  /// Get connection status for all relays
  @override
  Map<String, bool> getRelayStatus() {
    final status = <String, bool>{};
    for (final relayUrl in _relays) {
      status[relayUrl] = _connectedRelays.contains(relayUrl);
    }
    return status;
  }

  /// Reconnect to all configured relays
  @override
  Future<void> reconnectAll() async {
    Log.debug('Reconnecting to all relays...',
        name: 'NostrService', category: LogCategory.relay);

    // Remove all existing relays
    for (final relayUrl in List<String>.from(_connectedRelays)) {
      await removeRelay(relayUrl);
    }

    // Re-add all configured relays
    for (final relayUrl in List<String>.from(_relays)) {
      await addRelay(relayUrl);
    }
  }

  /// Get connection status for debugging
  Map<String, dynamic> getConnectionStatus() => {
        'isInitialized': _isInitialized,
        'connectedRelays': _connectedRelays.length,
        'totalRelays': _relays.length,
        'connectionInfo': _connectionService.getConnectionInfo(),
      };

  /// Get detailed relay status for debugging
  Map<String, dynamic> getDetailedRelayStatus() {
    final relayStatus = <String, Map<String, dynamic>>{};

    for (final relayUrl in _relays) {
      final isConnected = _connectedRelays.contains(relayUrl);
      final relay = _relayInstances[relayUrl];

      relayStatus[relayUrl] = {
        'connected': isConnected,
        'status': isConnected ? 'connected' : 'disconnected',
        'sdkConnected':
            relay?.relayStatus.connected == ClientConneccted.CONNECTED,
        'authed': relay?.relayStatus.authed ?? false,
        'readAccess': relay?.relayStatus.readAccess ?? false,
        'writeAccess': relay?.relayStatus.writeAccess ?? false,
      };
    }

    return {
      'relays': relayStatus,
      'summary': {
        'connected': _connectedRelays.length,
        'total': _relays.length,
      },
    };
  }

  /// Update relay statuses from SDK
  // ignore: unused_element
  void _updateRelayStatuses() {
    // Get active relays from SDK
    final activeRelays = _nostrClient!.activeRelays();

    // Update relay instances
    for (final relay in activeRelays) {
      if (_relays.contains(relay.url)) {
        _relayInstances[relay.url] = relay;
      }
    }


  }

  /// Save relay list to preferences
  Future<void> _saveRelays() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_relaysPrefsKey, _relays);
      Log.debug('📱 Saved ${_relays.length} relays to preferences',
          name: 'NostrService', category: LogCategory.relay);
    } catch (e) {
      Log.error('Failed to save relays: $e',
          name: 'NostrService', category: LogCategory.relay);
    }
  }

  @override
  Future<void> closeAllSubscriptions() async {
    Log.info(
        '🧹 Closing all active subscriptions (${_activeSubscriptions.length} total)',
        name: 'NostrService',
        category: LogCategory.relay);

    // Create a copy of the subscriptions to avoid concurrent modification
    final subscriptionsToClose = Map<String, String>.from(_activeSubscriptions);

    // Close all subscriptions
    for (final entry in subscriptionsToClose.entries) {
      try {
        _nostrClient?.unsubscribe(entry.value);
        Log.debug('  - Closed subscription ${entry.key}',
            name: 'NostrService', category: LogCategory.relay);
      } catch (e) {
        Log.error('Failed to close subscription ${entry.key}: $e',
            name: 'NostrService', category: LogCategory.relay);
      }
    }

    _activeSubscriptions.clear();
    Log.info('✅ All subscriptions closed',
        name: 'NostrService', category: LogCategory.relay);
  }

  /// Load persisted AUTH states from SharedPreferences
  Future<void> _loadPersistedAuthStates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final authData = prefs.getString(_authStatePrefsKey);
      
      if (authData != null) {
        final Map<String, dynamic> decoded = jsonDecode(authData);
        
        for (final entry in decoded.entries) {
          final relayUrl = entry.key;
          final data = entry.value as Map<String, dynamic>;
          
          final isAuthed = data['authed'] as bool? ?? false;
          final timestampMs = data['timestamp'] as int?;
          
          if (timestampMs != null) {
            final authTime = DateTime.fromMillisecondsSinceEpoch(timestampMs);
            final sessionAge = DateTime.now().difference(authTime);
            
            // Only restore if session is still valid
            if (sessionAge < _authSessionTimeout) {
              _relayAuthStates[relayUrl] = isAuthed;
              _relayAuthTimestamps[relayUrl] = authTime;
              
              if (isAuthed) {
                Log.info('🔄 Restored AUTH session for $relayUrl (${sessionAge.inMinutes}m old)',
                    name: 'NostrService', category: LogCategory.relay);
              }
            } else {
              Log.debug('⏰ AUTH session expired for $relayUrl (${sessionAge.inHours}h old)',
                  name: 'NostrService', category: LogCategory.relay);
            }
          }
        }
      }
    } catch (e) {
      Log.error('Failed to load persisted AUTH states: $e',
          name: 'NostrService', category: LogCategory.relay);
    }
  }

  /// Persist AUTH state for a specific relay
  Future<void> _persistAuthState(String relayUrl, bool isAuthed) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Load existing data
      final existingData = prefs.getString(_authStatePrefsKey);
      Map<String, dynamic> authData = {};
      
      if (existingData != null) {
        authData = Map<String, dynamic>.from(jsonDecode(existingData));
      }
      
      // Update data for this relay
      authData[relayUrl] = {
        'authed': isAuthed,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      
      // Save back to preferences
      await prefs.setString(_authStatePrefsKey, jsonEncode(authData));
      
      Log.debug('💾 Persisted AUTH state for $relayUrl: $isAuthed',
          name: 'NostrService', category: LogCategory.relay);
    } catch (e) {
      Log.error('Failed to persist AUTH state for $relayUrl: $e',
          name: 'NostrService', category: LogCategory.relay);
    }
  }

  /// Clear all persisted AUTH states
  Future<void> clearPersistedAuthStates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_authStatePrefsKey);
      _relayAuthStates.clear();
      _relayAuthTimestamps.clear();
      
      Log.info('🗑️ Cleared all persisted AUTH states',
          name: 'NostrService', category: LogCategory.relay);
    } catch (e) {
      Log.error('Failed to clear persisted AUTH states: $e',
          name: 'NostrService', category: LogCategory.relay);
    }
  }

  // Primary relay getter
  @override
  String get primaryRelay => primaryRelayUrl;

  // BackgroundAwareService implementation
  @override
  String get serviceName => 'NostrService';

  @override
  void onAppBackgrounded() {
    if (_isDisposed) return;
    
    _isInBackground = true;
    Log.info('📱 NostrService: App backgrounded - reducing activity',
        name: 'NostrService', category: LogCategory.relay);
        
    // Keep connections alive but reduce activity
    // Cancel any reconnection timers to save battery
    _reconnectionTimer?.cancel();
  }

  @override
  void onExtendedBackground() {
    if (_isDisposed || _isBackgroundSuspended) return;
    
    _isBackgroundSuspended = true;
    Log.info('📱 NostrService: Extended background - suspending relay connections',
        name: 'NostrService', category: LogCategory.relay);

    // Close all active subscriptions to save bandwidth
    try {
      final subscriptionsToClose = Map<String, String>.from(_activeSubscriptions);
      for (final entry in subscriptionsToClose.entries) {
        _nostrClient?.unsubscribe(entry.value);
      }
      _activeSubscriptions.clear();
      
      Log.info('🔌 Suspended ${subscriptionsToClose.length} subscriptions for background',
          name: 'NostrService', category: LogCategory.relay);
    } catch (e) {
      Log.error('Error suspending subscriptions: $e',
          name: 'NostrService', category: LogCategory.relay);
    }
  }

  @override
  void onAppResumed() {
    if (_isDisposed) return;
    
    final wasBackgroundSuspended = _isBackgroundSuspended;
    _isInBackground = false;
    _isBackgroundSuspended = false;
    
    Log.info('📱 NostrService: App resumed from background',
        name: 'NostrService', category: LogCategory.relay);

    if (wasBackgroundSuspended) {
      Log.info('🔌 Checking relay connections after background suspension',
          name: 'NostrService', category: LogCategory.relay);
      
      // Check relay connectivity and reconnect if needed
      // Note: Active subscriptions will be recreated by the services that need them
      _scheduleConnectivityCheck();
    }
  }

  @override
  void onPeriodicCleanup() {
    if (_isDisposed || _isInBackground) return;
    
    Log.debug('🧹 NostrService: Performing periodic cleanup',
        name: 'NostrService', category: LogCategory.relay);
    
    // Clean up old auth states
    _cleanupExpiredAuthStates();
  }

  /// Schedule a connectivity check for when app resumes
  void _scheduleConnectivityCheck() {
    _reconnectionTimer?.cancel();
    _reconnectionTimer = Timer(const Duration(seconds: 5), () async {
      if (!_isInBackground && !_isDisposed) {
        try {
          // Check if relays are still connected
          final relays = _nostrClient?.activeRelays() ?? [];
          int connectedCount = 0;
          
          for (final relay in relays) {
            if (relay.relayStatus.connected == ClientConneccted.CONNECTED) {
              connectedCount++;
            }
          }
          
          Log.info('🔍 Connectivity check: $connectedCount/${relays.length} relays connected',
              name: 'NostrService', category: LogCategory.relay);
          
          // If we have no connected relays, attempt to reconnect
          if (connectedCount == 0 && relays.isNotEmpty) {
            Log.warning('⚠️ No relay connections after background - attempting reconnect',
                name: 'NostrService', category: LogCategory.relay);
            // The app will naturally reconnect when services request new subscriptions
          }
        } catch (e) {
          Log.error('Error in connectivity check: $e',
              name: 'NostrService', category: LogCategory.relay);
        }
      }
    });
  }

  /// Clean up expired auth states
  void _cleanupExpiredAuthStates() {
    final now = DateTime.now();
    final expiredRelays = <String>[];
    
    for (final entry in _relayAuthTimestamps.entries) {
      final authAge = now.difference(entry.value);
      if (authAge > _authSessionTimeout) {
        expiredRelays.add(entry.key);
      }
    }
    
    for (final relayUrl in expiredRelays) {
      _relayAuthStates.remove(relayUrl);
      _relayAuthTimestamps.remove(relayUrl);
      Log.debug('🗑️ Cleaned up expired auth state for $relayUrl',
          name: 'NostrService', category: LogCategory.relay);
    }
  }

  @override
  void dispose() {
    if (_isDisposed) return;

    Log.debug('📱️ Disposing NostrService v2',
        name: 'NostrService', category: LogCategory.relay);
    _isDisposed = true;

    // Cancel background timers
    _reconnectionTimer?.cancel();

    // Cancel all active subscriptions
    for (final entry in _activeSubscriptions.entries) {
      _nostrClient?.unsubscribe(entry.value);
    }
    _activeSubscriptions.clear();

    // Close auth state stream
    _authStateController.close();

    // Clean up client (SDK handles relay disconnection)
    _nostrClient = null;
    _connectedRelays.clear();
    _relayInstances.clear();
    _relayAuthStates.clear();
    _relayAuthTimestamps.clear();

    
  }
}
