// ABOUTME: Service for subscribing to and managing NIP-71 kind 22 video events
// ABOUTME: Handles real-time feed updates and local caching of video content

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:nostr_sdk/event.dart';
import 'package:nostr_sdk/filter.dart';
import 'package:openvine/constants/app_constants.dart';
import 'package:openvine/models/video_event.dart';
import 'package:openvine/services/connection_status_service.dart';
import 'package:openvine/services/content_blocklist_service.dart';
import 'package:openvine/services/nostr_service_interface.dart';
import 'package:openvine/services/subscription_manager.dart';
import 'package:openvine/utils/unified_logger.dart';

/// Service for handling NIP-71 kind 22 video events
/// REFACTORED: Removed ChangeNotifier - now uses pure state management via Riverpod
class VideoEventService  {
  VideoEventService(
    this._nostrService, {
    required SubscriptionManager subscriptionManager,
  }) : _subscriptionManager = subscriptionManager;
  final INostrService _nostrService;
  final ConnectionStatusService _connectionService = ConnectionStatusService();
  final List<VideoEvent> _videoEvents = [];
  final Map<String, StreamSubscription> _subscriptions =
      {}; // Direct subscriptions fallback
  final List<String> _activeSubscriptionIds = []; // Managed subscription IDs
  bool _isSubscribed = false;
  bool _isLoading = false;
  String? _error;
  Timer? _retryTimer;
  int _retryAttempts = 0;
  List<String>? _activeHashtagFilter;
  String? _activeGroupFilter;

  // Track active subscription parameters to properly detect duplicates
  final Map<String, dynamic> _currentSubscriptionParams = {};

  // Duplicate event aggregation for logging
  int _duplicateVideoEventCount = 0;
  DateTime? _lastDuplicateVideoLogTime;

  static const int _maxRetryAttempts = 3;
  static const Duration _retryDelay = Duration(seconds: 10);

  // Optional services for enhanced functionality
  ContentBlocklistService? _blocklistService;
  final SubscriptionManager _subscriptionManager;

  // Track if current subscription is for following list or general feed
  bool _isFollowingFeed = false;

  // Track if reposts are enabled for current subscription
  bool _includeReposts = false;

  // AUTH retry mechanism
  StreamSubscription<Map<String, bool>>? _authStateSubscription;

  /// Set the blocklist service for content filtering
  void setBlocklistService(ContentBlocklistService blocklistService) {
    _blocklistService = blocklistService;
    Log.debug('Blocklist service attached to VideoEventService',
        name: 'VideoEventService', category: LogCategory.video);
  }

  // Getters
  List<VideoEvent> get videoEvents => List.unmodifiable(_videoEvents);
  bool get isSubscribed => _isSubscribed;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasEvents => _videoEvents.isNotEmpty;
  int get eventCount => _videoEvents.length;
  String get classicVinesPubkey => AppConstants.classicVinesPubkey;

  /// Get videos by a specific author from the existing cache
  List<VideoEvent> getVideosByAuthor(String pubkey) =>
      _videoEvents.where((video) => video.pubkey == pubkey).toList();

  /// Retry subscription with current parameters
  Future<void> _retrySubscriptionWithCurrentParams() async {
    if (_currentSubscriptionParams.isEmpty) {
      Log.warning('No stored subscription parameters for retry',
          name: 'VideoEventService', category: LogCategory.video);
      return;
    }

    try {
      // Extract stored parameters
      final authors = _currentSubscriptionParams['authors'] as List<String>?;
      final hashtags = _currentSubscriptionParams['hashtags'] as List<String>?;
      final group = _currentSubscriptionParams['group'] as String?;
      final since = _currentSubscriptionParams['since'] as int?;
      final until = _currentSubscriptionParams['until'] as int?;
      final limit = _currentSubscriptionParams['limit'] as int? ?? 50;

      Log.info('🔄 Retrying subscription with AUTH-completed relay',
          name: 'VideoEventService', category: LogCategory.video);

      // Cancel existing subscriptions first
      await _cancelExistingSubscriptions();

      // Small delay to ensure cleanup is complete
      await Future.delayed(const Duration(milliseconds: 500));

      // Recreate subscription with same parameters
      await subscribeToVideoFeed(
        authors: authors,
        hashtags: hashtags,
        group: group,
        since: since,
        until: until,
        limit: limit,
        replace: false, // Don't replace since we already canceled
        includeReposts: _includeReposts,
      );

      Log.info('✅ Subscription retry completed successfully',
          name: 'VideoEventService', category: LogCategory.video);
    } catch (e) {
      Log.error('Failed to retry subscription after AUTH: $e',
          name: 'VideoEventService', category: LogCategory.video);
    }
  }

  /// Subscribe to kind 22 video events from all connected relays
  Future<void> subscribeToVideoFeed({
    List<String>? authors,
    List<String>? hashtags,
    String? group, // Support filtering by group ('h' tag)
    int? since,
    int? until,
    int limit = 50, // Start with smaller limit for fast initial load
    bool replace = true, // Whether to replace existing subscription
    bool includeReposts =
        false, // Whether to include kind 6 reposts (disabled by default)
  }) async {
    Log.info('🔍 DEBUG: subscribeToVideoFeed called with limit=$limit, authors=${authors?.length}, hashtags=${hashtags?.length}',
        name: 'VideoEventService', category: LogCategory.video);
    // Prevent concurrent subscription attempts
    if (_isLoading) {
      Log.debug('Subscription request ignored, another is already in progress.',
          name: 'VideoEventService', category: LogCategory.video);
      return;
    }

    // Check if this is a duplicate subscription by comparing parameters
    if (_isSubscribed &&
        _isDuplicateSubscription(
            authors, hashtags, group, limit, since, until)) {
      Log.debug(
          'Subscription request ignored, already subscribed with same parameters.',
          name: 'VideoEventService',
          category: LogCategory.video);
      return;
    }

    // Set loading state immediately to prevent race conditions
    _isLoading = true;
    _error = null;


    if (!_nostrService.isInitialized) {
      _isLoading = false;

      Log.error('Cannot subscribe - Nostr service not initialized',
          name: 'VideoEventService', category: LogCategory.video);
      throw const VideoEventServiceException('Nostr service not initialized');
    }

    // Check connection status
    if (!_connectionService.isOnline) {
      _isLoading = false;

      Log.warning('Device is offline, will retry when connection is restored',
          name: 'VideoEventService', category: LogCategory.video);
      _scheduleRetryWhenOnline();
      throw const VideoEventServiceException('Device is offline');
    }

    if (_nostrService.connectedRelayCount == 0) {
      Log.warning(
          'WARNING: No relays connected - subscription will likely fail',
          name: 'VideoEventService',
          category: LogCategory.video);
    }

    // Only close existing subscriptions if replace=true
    if (replace) {
      Log.debug('Cancelling existing subscriptions (replace=true)',
          name: 'VideoEventService', category: LogCategory.video);
      await _cancelExistingSubscriptions();
    } else {
      Log.debug('➕ Keeping existing subscriptions (replace=false)',
          name: 'VideoEventService', category: LogCategory.video);
    }

    try {
      Log.debug('Creating filter for kind 22 video events...',
          name: 'VideoEventService', category: LogCategory.video);
      debugPrint('  - Authors: ${authors?.length ?? 'all'}');
      debugPrint('  - Hashtags: ${hashtags?.join(', ') ?? 'none'}');
      debugPrint('  - Group: ${group ?? 'none'}');
      debugPrint(
          '  - Since: ${since != null ? DateTime.fromMillisecondsSinceEpoch(since * 1000) : 'none'}');
      debugPrint(
          '  - Until: ${until != null ? DateTime.fromMillisecondsSinceEpoch(until * 1000) : 'none'}');
      Log.verbose('  - Limit: $limit',
          name: 'VideoEventService', category: LogCategory.video);
      Log.debug('  - Replace existing: $replace',
          name: 'VideoEventService', category: LogCategory.video);

      // Track if this is a following feed (has specific authors)
      _isFollowingFeed = authors != null && authors.isNotEmpty;
      _includeReposts = includeReposts;
      Log.debug('  - Is following feed: $_isFollowingFeed',
          name: 'VideoEventService', category: LogCategory.video);
      Log.debug('  - Include reposts: $_includeReposts',
          name: 'VideoEventService', category: LogCategory.video);

      // Create filter for kind 22 events
      // No artificial date constraints - let relays return their best content
      final effectiveSince = since;
      final effectiveUntil = until;

      if (since == null && until == null && _videoEvents.isEmpty) {
        Log.debug(
            '📱 Initial load: requesting best video content (no date constraints)',
            name: 'VideoEventService',
            category: LogCategory.video);
        // Let relays decide what content to return - they know their data best
      }

      // Create optimized filter for Kind 22 video events
      final videoFilter = Filter(
        kinds: [22], // NIP-71 short video events only
        authors: authors,
        since: effectiveSince,
        until: effectiveUntil,
        limit: limit, // Use full limit for video events
        t: hashtags, // Add hashtag filtering at relay level
      );

      // Debug: Log when subscribing to Classic Vines
      if (authors != null &&
          authors.contains(AppConstants.classicVinesPubkey)) {
        Log.debug(
            '🌟 Subscribing to Classic Vines account (${AppConstants.classicVinesPubkey})',
            name: 'VideoEventService',
            category: LogCategory.video);
      }

      if (hashtags != null && hashtags.isNotEmpty) {
        Log.debug('Adding hashtag filter to relay query: $hashtags',
            name: 'VideoEventService', category: LogCategory.video);
      }

      // Store group for client-side filtering
      _activeGroupFilter = group;

      final filters = <Filter>[videoFilter];

      // Optionally add repost filter if enabled
      if (includeReposts) {
        final repostFilter = Filter(
          kinds: [6], // NIP-18 reposts only
          authors: authors,
          since: effectiveSince,
          until: effectiveUntil,
          limit: (limit * 0.2).round(), // Only 20% for reposts when enabled
        );
        filters.add(repostFilter);
        Log.debug('Using primary video filter + optional repost filter:',
            name: 'VideoEventService', category: LogCategory.video);
        Log.debug('  - Video filter ($limit limit): ${videoFilter.toJson()}',
            name: 'VideoEventService', category: LogCategory.video);
        Log.debug(
            '  - Repost filter (${(limit * 0.2).round()} limit): ${repostFilter.toJson()}',
            name: 'VideoEventService',
            category: LogCategory.video);
      } else {
        Log.debug('Using video-only filter (reposts disabled):',
            name: 'VideoEventService', category: LogCategory.video);
        Log.debug('  - Video filter ($limit limit): ${videoFilter.toJson()}',
            name: 'VideoEventService', category: LogCategory.video);
      }

      // Store hashtag filter for event processing
      _activeHashtagFilter = hashtags;
      
      // Log the exact filters being sent
      Log.info('🔍 FILTERS BEING SENT TO RELAY:',
          name: 'VideoEventService', category: LogCategory.video);
      for (int i = 0; i < filters.length; i++) {
        final filterJson = filters[i].toJson();
        Log.info('  Filter $i JSON: $filterJson',
            name: 'VideoEventService', category: LogCategory.video);
      }
      
      // Verify NostrService is ready
      if (!_nostrService.isInitialized) {
        Log.error('❌ NostrService not initialized - cannot create subscription',
            name: 'VideoEventService', category: LogCategory.video);
        throw Exception('NostrService not initialized');
      }
      
      if (_nostrService.connectedRelayCount == 0) {
        Log.error('❌ No connected relays - cannot create subscription',
            name: 'VideoEventService', category: LogCategory.video);
        throw Exception('No connected relays');
      }
      
      // Using strfry relay - no auth required
      Log.info('✅ Using strfry relay - proceeding with subscription (no auth needed)',
          name: 'VideoEventService', category: LogCategory.video);
      
      // BYPASS SubscriptionManager for main video feed - go directly to NostrService
      try {
        Log.info('🔍 DIRECT: Creating DIRECT subscription for main video feed (bypassing SubscriptionManager)...',
            name: 'VideoEventService', category: LogCategory.video);
        
        // Create simple filter for OpenVine relays (relay1/relay2.openvine.co)
        final simpleKind22Filter = Filter(
          kinds: [22],
          limit: limit, // Use the requested limit instead of hardcoded 10
        );
        
        final simpleFilters = [simpleKind22Filter];
        
        Log.info('🔍 DIRECT: Using ULTRA-SIMPLE filter to match working nak command:',
            name: 'VideoEventService', category: LogCategory.video);
        Log.info('  Simple Filter JSON: ${simpleKind22Filter.toJson()}',
            name: 'VideoEventService', category: LogCategory.video);
        Log.info('  Expected format: {"kinds":[22],"limit":$limit}',
            name: 'VideoEventService', category: LogCategory.video);
        
        // Create direct subscription using NostrService with simple filter
        final eventStream = _nostrService.subscribeToEvents(filters: simpleFilters);
        final subscriptionId = 'main_video_feed_direct_${DateTime.now().millisecondsSinceEpoch}';
        
        final streamSubscription = eventStream.listen(
          (event) {
            Log.info('🎬 DIRECT: Received event via NostrService: kind=${event.kind}, id=${event.id.substring(0, 8)}',
                name: 'VideoEventService', category: LogCategory.video);
            _handleNewVideoEvent(event);
          },
          onError: (error) {
            Log.error('🔍 DIRECT: NostrService stream error: $error',
                name: 'VideoEventService', category: LogCategory.video);
            _handleSubscriptionError(error);
          },
          onDone: () {
            Log.info('🔍 DIRECT: NostrService stream completed',
                name: 'VideoEventService', category: LogCategory.video);
            _handleSubscriptionComplete();
          },
        );
        
        // Store the stream subscription for cleanup
        _subscriptions[subscriptionId] = streamSubscription;
        
        Log.info('🔍 DIRECT: Direct subscription created with ID: $subscriptionId',
            name: 'VideoEventService', category: LogCategory.video);

        _isSubscribed = true;
      } catch (e, stackTrace) {
        Log.error('❌ Failed to create direct subscription: $e',
            name: 'VideoEventService', category: LogCategory.video);
        Log.error('❌ Stack trace: $stackTrace',
            name: 'VideoEventService', category: LogCategory.video);
        rethrow;
      }

      // Store current subscription parameters for duplicate detection
      _currentSubscriptionParams.clear();
      _currentSubscriptionParams['authors'] = authors;
      _currentSubscriptionParams['hashtags'] = hashtags;
      _currentSubscriptionParams['group'] = group;
      _currentSubscriptionParams['since'] = since;
      _currentSubscriptionParams['until'] = until;
      _currentSubscriptionParams['limit'] = limit;

      Log.info('Video event subscription established successfully!',
          name: 'VideoEventService', category: LogCategory.video);

      // Add default video if feed is empty to ensure new users have content
      _ensureDefaultContent();

      // Progressive loading removed - let UI trigger loadMore as needed
      final totalSubs = _subscriptions.length + _activeSubscriptionIds.length;
      Log.debug(
          'Subscription status: active=$totalSubs subscriptions (${_activeSubscriptionIds.length} managed, ${_subscriptions.length} direct)',
          name: 'VideoEventService',
          category: LogCategory.video);
    } catch (e) {
      _error = e.toString();
      Log.error('Failed to subscribe to video events: $e',
          name: 'VideoEventService', category: LogCategory.video);

      // Check if it's a connection-related error
      if (_isConnectionError(e)) {
        Log.error('📱 Connection error detected, will retry when online',
            name: 'VideoEventService', category: LogCategory.video);
        _scheduleRetryWhenOnline();
      }
    } finally {
      _isLoading = false;

    }
  }

  /// Handle new video event from subscription
  void _handleNewVideoEvent(dynamic eventData) {
    try {
      // The event should already be an Event object from NostrService
      if (eventData is! Event) {
        Log.warning('Expected Event object but got ${eventData.runtimeType}',
            name: 'VideoEventService', category: LogCategory.video);
        return;
      }

      final event = eventData;
      Log.info(
          '🎬 SUCCESS: VideoEventService._handleNewVideoEvent called! kind=${event.kind}, id=${event.id.substring(0, 8)}..., created=${DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000)}',
          name: 'VideoEventService',
          category: LogCategory.video);

      if (event.kind != 22 && event.kind != 6) {
        Log.warning('⏩ Skipping non-video/repost event (kind ${event.kind})',
            name: 'VideoEventService', category: LogCategory.video);
        return;
      }

      // Skip repost events if reposts are disabled
      if (event.kind == 6 && !_includeReposts) {
        Log.warning(
            '⏩ Skipping repost event ${event.id.substring(0, 8)}... (reposts disabled)',
            name: 'VideoEventService',
            category: LogCategory.video);
        return;
      }

      Log.info('🎬 DEBUG: Event passed repost check, checking for duplicates...',
          name: 'VideoEventService', category: LogCategory.video);

      // Check if we already have this event
      if (_videoEvents.any((e) => e.id == event.id)) {
        _duplicateVideoEventCount++;
        _logDuplicateVideoEventsAggregated();
        Log.info('🎬 DEBUG: Event ${event.id.substring(0, 8)} is duplicate, skipping',
            name: 'VideoEventService', category: LogCategory.video);
        return;
      }

      Log.info('🎬 DEBUG: Event is not duplicate, checking blocklist...',
          name: 'VideoEventService', category: LogCategory.video);

      // Check if content is blocked
      if (_blocklistService?.shouldFilterFromFeeds(event.pubkey) == true) {
        Log.verbose(
            'Filtering blocked content from ${event.pubkey.substring(0, 8)}...',
            name: 'VideoEventService',
            category: LogCategory.video);
        return;
      }

      Log.info('🎬 DEBUG: Event passed blocklist check, processing kind ${event.kind}...',
          name: 'VideoEventService', category: LogCategory.video);

      // TEMPORARILY DISABLED: Check if user has already seen this video
      // TODO: Re-enable after testing the video feed
      // if (_seenVideosService?.hasSeenVideo(event.id) == true) {
      //   Log.warning('📱️ Skipping seen video ${event.id.substring(0, 8)}...', name: 'VideoEventService', category: LogCategory.video);
      //   return;
      // }

      // TEMPORARILY DISABLED: CLIENT-SIDE FILTERING to debug feed issue
      // TODO: Re-enable after fixing the feed stopping issue
      // final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));
      // final eventTime = DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000);
      //
      // if (eventTime.isBefore(sevenDaysAgo)) {
      //   Log.debug('⏰ FILTERING OUT OLD EVENT: ${event.id.substring(0, 8)} from $eventTime (older than 7 days)', name: 'VideoEventService', category: LogCategory.video);
      //   return; // Return early without notifying listeners to prevent rebuild loops
      // }

      // Handle different event kinds
      if (event.kind == 22) {
        // Direct video event
        Log.verbose('Processing new video event ${event.id.substring(0, 8)}...',
            name: 'VideoEventService', category: LogCategory.video);
        Log.verbose('Direct event tags: ${event.tags}',
            name: 'VideoEventService', category: LogCategory.video);
        try {
          final videoEvent = VideoEvent.fromNostrEvent(event);
          Log.verbose(
              'Parsed direct video: hasVideo=${videoEvent.hasVideo}, videoUrl=${videoEvent.videoUrl}',
              name: 'VideoEventService',
              category: LogCategory.video);
          Log.verbose('Thumbnail URL: ${videoEvent.thumbnailUrl}',
              name: 'VideoEventService', category: LogCategory.video);
          Log.verbose(
              'Has thumbnail: ${videoEvent.thumbnailUrl != null && videoEvent.thumbnailUrl!.isNotEmpty}',
              name: 'VideoEventService',
              category: LogCategory.video);
          Log.verbose('Video author pubkey: ${videoEvent.pubkey}',
              name: 'VideoEventService', category: LogCategory.video);
          Log.verbose('Video title: ${videoEvent.title}',
              name: 'VideoEventService', category: LogCategory.video);
          Log.verbose('Video hashtags: ${videoEvent.hashtags}',
              name: 'VideoEventService', category: LogCategory.video);

          // Debug: Special logging for Classic Vines content
          if (videoEvent.pubkey == AppConstants.classicVinesPubkey) {
            Log.info(
                '🌟 Received Classic Vines video: ${videoEvent.title ?? videoEvent.id.substring(0, 8)}',
                name: 'VideoEventService',
                category: LogCategory.video);
          }

          // Check hashtag filter if active
          if (_activeHashtagFilter != null &&
              _activeHashtagFilter!.isNotEmpty) {
            // Check if video has any of the required hashtags
            final hasRequiredHashtag = _activeHashtagFilter!.any(
              videoEvent.hashtags.contains,
            );

            if (!hasRequiredHashtag) {
              Log.warning(
                  '⏩ Skipping video without required hashtags: $_activeHashtagFilter',
                  name: 'VideoEventService',
                  category: LogCategory.video);
              return;
            }
          }

          // Check group filter if active
          if (_activeGroupFilter != null &&
              videoEvent.group != _activeGroupFilter) {
            Log.warning(
                '⏩ Skipping video from different group: ${videoEvent.group} (want: $_activeGroupFilter)',
                name: 'VideoEventService',
                category: LogCategory.video);
            return;
          }

          Log.info('🎬 DEBUG: VideoEvent parsed, hasVideo=${videoEvent.hasVideo}, videoUrl=${videoEvent.videoUrl}',
              name: 'VideoEventService', category: LogCategory.video);
          Log.info('🎬 DEBUG: Event tags: ${event.tags}',
              name: 'VideoEventService', category: LogCategory.video);

          // Only add events with video URLs
          if (videoEvent.hasVideo) {
            Log.info('🎬 SUCCESS: Video has URL, adding to list! Current count: ${_videoEvents.length}',
                name: 'VideoEventService', category: LogCategory.video);
            _addVideoWithPriority(videoEvent);
            Log.info('🎬 SUCCESS: After adding video, new count: ${_videoEvents.length}',
                name: 'VideoEventService', category: LogCategory.video);

            // Keep only the most recent events to prevent memory issues
            if (_videoEvents.length > 500) {
              _videoEvents.removeRange(500, _videoEvents.length);
            }

            Log.info(
                '🎬 DEBUG: Successfully added video event! Total: ${_videoEvents.length} events',
                name: 'VideoEventService',
                category: LogCategory.video);

          } else {
            Log.warning('🎬 FILTER: ⏩ Skipping video event without video URL (hasVideo=false)',
                name: 'VideoEventService', category: LogCategory.video);
            Log.warning('🎬 FILTER: Event details - title: ${videoEvent.title}, content: ${event.content}, tags: ${event.tags}',
                name: 'VideoEventService', category: LogCategory.video);
          }
        } catch (e, stackTrace) {
          Log.error('Failed to parse video event: $e',
              name: 'VideoEventService', category: LogCategory.video);
          Log.verbose('📱 Stack trace: $stackTrace',
              name: 'VideoEventService', category: LogCategory.video);
          Log.verbose('Event details:',
              name: 'VideoEventService', category: LogCategory.video);
          Log.verbose('  - ID: ${event.id}',
              name: 'VideoEventService', category: LogCategory.video);
          Log.verbose('  - Kind: ${event.kind}',
              name: 'VideoEventService', category: LogCategory.video);
          Log.verbose('  - Pubkey: ${event.pubkey}',
              name: 'VideoEventService', category: LogCategory.video);
          Log.verbose('  - Content: ${event.content}',
              name: 'VideoEventService', category: LogCategory.video);
          Log.verbose('  - Created at: ${event.createdAt}',
              name: 'VideoEventService', category: LogCategory.video);
          Log.verbose('  - Tags: ${event.tags}',
              name: 'VideoEventService', category: LogCategory.video);
        }
      } else if (event.kind == 6) {
        // Repost event - only process if it likely references video content
        Log.verbose('Processing repost event ${event.id.substring(0, 8)}...',
            name: 'VideoEventService', category: LogCategory.video);

        String? originalEventId;
        for (final tag in event.tags) {
          if (tag.isNotEmpty && tag[0] == 'e' && tag.length > 1) {
            originalEventId = tag[1];
            break;
          }
        }

        // Smart filtering: Only process reposts that are likely video-related
        if (!_isLikelyVideoRepost(event)) {
          Log.warning(
              '⏩ Skipping non-video repost ${event.id.substring(0, 8)}... (no video indicators)',
              name: 'VideoEventService',
              category: LogCategory.video);
          return;
        }

        if (originalEventId != null) {
          Log.verbose(
              'Repost references event: ${originalEventId.substring(0, 8)}...',
              name: 'VideoEventService',
              category: LogCategory.video);

          // Check if we already have the original video in our cache
          final existingOriginal = _videoEvents.firstWhere(
            (v) => v.id == originalEventId,
            orElse: () => VideoEvent(
              id: '',
              pubkey: '',
              createdAt: 0,
              content: '',
              timestamp: DateTime.now(),
            ),
          );

          if (existingOriginal.id.isNotEmpty) {
            // Create repost version of existing video
            Log.info('Found cached original video, creating repost',
                name: 'VideoEventService', category: LogCategory.video);
            final repostEvent = VideoEvent.createRepostEvent(
              originalEvent: existingOriginal,
              repostEventId: event.id,
              reposterPubkey: event.pubkey,
              repostedAt:
                  DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
            );

            // Check hashtag filter for reposts too
            if (_activeHashtagFilter != null &&
                _activeHashtagFilter!.isNotEmpty) {
              final hasRequiredHashtag = _activeHashtagFilter!.any(
                repostEvent.hashtags.contains,
              );

              if (!hasRequiredHashtag) {
                Log.warning(
                    '⏩ Skipping repost without required hashtags: $_activeHashtagFilter',
                    name: 'VideoEventService',
                    category: LogCategory.video);
                return;
              }
            }

            _addVideoWithPriority(repostEvent);
            Log.verbose(
                'Added repost event! Total: ${_videoEvents.length} events',
                name: 'VideoEventService',
                category: LogCategory.video);

          } else {
            // Fetch original event from relays
            Log.verbose('Fetching original video event from relays...',
                name: 'VideoEventService', category: LogCategory.video);
            _fetchOriginalEventForRepost(originalEventId, event);
          }
        }
      }
    } catch (e) {
      Log.error('Error processing video event: $e',
          name: 'VideoEventService', category: LogCategory.video);
    }
  }

  /// Handle subscription error
  void _handleSubscriptionError(dynamic error) {
    _error = error.toString();
    Log.error('Video subscription error: $error',
        name: 'VideoEventService', category: LogCategory.video);
    final totalSubs = _subscriptions.length + _activeSubscriptionIds.length;
    Log.verbose(
        'Current state: events=${_videoEvents.length}, subscriptions=$totalSubs',
        name: 'VideoEventService',
        category: LogCategory.video);

    // Check if it's a connection error and schedule retry
    if (_isConnectionError(error)) {
      Log.error('📱 Subscription connection error, scheduling retry...',
          name: 'VideoEventService', category: LogCategory.video);
      _scheduleRetryWhenOnline();
    }


  }

  /// Handle subscription completion
  void _handleSubscriptionComplete() {
    Log.info('📱 Video subscription completed',
        name: 'VideoEventService', category: LogCategory.video);
    final totalSubs = _subscriptions.length + _activeSubscriptionIds.length;
    Log.verbose(
        'Final state: events=${_videoEvents.length}, subscriptions=$totalSubs',
        name: 'VideoEventService',
        category: LogCategory.video);
  }

  /// Subscribe to specific user's video events
  Future<void> subscribeToUserVideos(String pubkey, {int limit = 50}) async =>
      subscribeToVideoFeed(
        authors: [pubkey],
        limit: limit,
      );

  /// Subscribe to videos with specific hashtags
  Future<void> subscribeToHashtagVideos(List<String> hashtags,
          {int limit = 100}) async =>
      subscribeToVideoFeed(
        hashtags: hashtags,
        limit: limit,
      );

  /// Subscribe to videos from a specific group (using 'h' tag)
  Future<void> subscribeToGroupVideos(
    String group, {
    List<String>? authors,
    int? since,
    int? until,
    int limit = 50,
  }) async {
    if (!_nostrService.isInitialized) {
      throw const VideoEventServiceException('Nostr service not initialized');
    }

    Log.verbose('Subscribing to videos from group: $group',
        name: 'VideoEventService', category: LogCategory.video);

    // Note: Nostr SDK Filter doesn't support custom tags directly,
    // so we'll rely on client-side filtering for group 'h' tags
    Log.verbose('Subscribing to group: $group (will filter client-side)',
        name: 'VideoEventService', category: LogCategory.video);

    // Use existing subscription infrastructure with group parameter
    return subscribeToVideoFeed(
      authors: authors,
      group: group,
      since: since,
      until: until,
      limit: limit,
    );
  }

  /// Get video events by group from cache
  List<VideoEvent> getVideoEventsByGroup(String group) =>
      _videoEvents.where((event) => event.group == group).toList();

  /// Refresh video feed by fetching recent events with expanded timeframe
  Future<void> refreshVideoFeed() async {
    Log.verbose(
        'Refresh requested - restarting subscription with expanded timeframe',
        name: 'VideoEventService',
        category: LogCategory.video);

    // Close existing subscriptions and create new ones with expanded timeframe
    await unsubscribeFromVideoFeed();

    Log.verbose('Creating new subscription with expanded timeframe...',
        name: 'VideoEventService', category: LogCategory.video);
    // Preserve the current reposts setting when refreshing
    return subscribeToVideoFeed(includeReposts: _includeReposts);
  }

  /// Progressive loading: load more videos after initial fast load
  Future<void> loadMoreVideos({int limit = 100}) async {
    Log.verbose('📱 Loading more videos progressively...',
        name: 'VideoEventService', category: LogCategory.video);

    // Use larger limit for progressive loading
    return subscribeToVideoFeed(
      limit: limit,
      replace: false, // Don't replace existing subscription
    );
  }

  /// Load more historical events using one-shot query (not persistent subscription)
  Future<void> loadMoreEvents({int limit = 200}) async {
    _isLoading = true;
    // Defer notifyListeners to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {

    });

    try {
      Log.debug('📱 Loading more historical events...',
          name: 'VideoEventService', category: LogCategory.video);

      int? until;

      // If we have events, get older ones by finding the oldest timestamp
      if (_videoEvents.isNotEmpty) {
        // Sort events by timestamp to find the actual oldest
        final sortedEvents = List<VideoEvent>.from(_videoEvents)
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

        final oldestEvent = sortedEvents.first;
        until = oldestEvent.createdAt - 1; // One second before oldest event
        Log.debug(
            '📱 Requesting events older than ${DateTime.fromMillisecondsSinceEpoch(until * 1000)}',
            name: 'VideoEventService',
            category: LogCategory.video);
        Log.info(
            '📱 Current oldest event: ${oldestEvent.title ?? oldestEvent.id.substring(0, 8)} at ${DateTime.fromMillisecondsSinceEpoch(oldestEvent.createdAt * 1000)}',
            name: 'VideoEventService',
            category: LogCategory.video);
      } else {
        // If no events yet, load without date constraints
        Log.debug(
            '📱 No existing events, loading fresh content without date constraints',
            name: 'VideoEventService',
            category: LogCategory.video);
      }

      // Use one-shot historical query - this will complete when EOSE is received
      await _queryHistoricalEvents(until: until, limit: limit);

      Log.info('Historical events loaded. Total events: ${_videoEvents.length}',
          name: 'VideoEventService', category: LogCategory.video);
    } catch (e) {
      _error = e.toString();
      Log.error('Failed to load more events: $e',
          name: 'VideoEventService', category: LogCategory.video);

      if (_isConnectionError(e)) {
        Log.error('📱 Load more failed due to connection error',
            name: 'VideoEventService', category: LogCategory.video);
      }
    } finally {
      _isLoading = false;

    }
  }

  /// One-shot query for historical events (completes when EOSE received)
  Future<void> _queryHistoricalEvents({int? until, int limit = 200}) async {
    if (!_nostrService.isInitialized) {
      throw const VideoEventServiceException('Nostr service not initialized');
    }

    final completer = Completer<void>();

    // Create filter without restrictive date constraints
    final filter = Filter(
      kinds: [22], // Focus on video events primarily
      until: until, // Only use 'until' if we have existing events
      limit: limit,
      // No 'since' filter to allow loading of all historical content
    );

    debugPrint(
        '🔍 One-shot historical query: until=${until != null ? DateTime.fromMillisecondsSinceEpoch(until * 1000) : 'none'}, limit=$limit');
    Log.debug('Filter: ${filter.toJson()}',
        name: 'VideoEventService', category: LogCategory.video);

    // Always use managed subscription
    final subscriptionId = await _subscriptionManager.createSubscription(
      name: 'historical_query',
      filters: [filter],
      onEvent: _handleNewVideoEvent,
      onError: (error) {
        Log.error('Historical query error: $error',
            name: 'VideoEventService', category: LogCategory.video);
        if (!completer.isCompleted) completer.completeError(error);
      },
      onComplete: () {
        Log.info('Historical query completed (EOSE received)',
            name: 'VideoEventService', category: LogCategory.video);
        if (!completer.isCompleted) completer.complete();
      },
      timeout: const Duration(seconds: 30),
      priority: 5, // Medium priority for historical queries
    );

    // Clean up subscription when done
    completer.future.whenComplete(() {
      _subscriptionManager.cancelSubscription(subscriptionId);
    });

    return completer.future;
  }

  /// Load more content without date restrictions - for when users reach end of feed
  Future<void> loadMoreContentUnlimited({int limit = 300}) async {
    _isLoading = true;


    try {
      Log.debug('📱 Loading unlimited content for end-of-feed...',
          name: 'VideoEventService', category: LogCategory.video);

      // Create a broader query without date restrictions
      final filter = Filter(
        kinds: [22], // Video events
        limit: limit,
        // No date filters - let relays return their best content
      );

      Log.debug('Unlimited content query: limit=$limit',
          name: 'VideoEventService', category: LogCategory.video);
      Log.debug('Filter: ${filter.toJson()}',
          name: 'VideoEventService', category: LogCategory.video);

      final eventStream = _nostrService.subscribeToEvents(filters: [filter]);
      late StreamSubscription subscription;
      final completer = Completer<void>();

      subscription = eventStream.listen(
        _handleNewVideoEvent,
        onError: (error) {
          Log.error('Unlimited content query error: $error',
              name: 'VideoEventService', category: LogCategory.video);
          if (!completer.isCompleted) completer.completeError(error);
        },
        onDone: () {
          Log.info('Unlimited content query completed (EOSE received)',
              name: 'VideoEventService', category: LogCategory.video);
          subscription.cancel();
          if (!completer.isCompleted) completer.complete();
        },
      );

      // Set timeout for the query
      Timer(const Duration(seconds: 45), () {
        if (!completer.isCompleted) {
          Log.debug('⏰ Unlimited content query timed out after 45 seconds',
              name: 'VideoEventService', category: LogCategory.video);
          subscription.cancel();
          completer.complete();
        }
      });

      await completer.future;
    } catch (e) {
      _error = e.toString();
      Log.error('Failed to load unlimited content: $e',
          name: 'VideoEventService', category: LogCategory.video);

      if (_isConnectionError(e)) {
        Log.error('📱 Unlimited content load failed due to connection error',
            name: 'VideoEventService', category: LogCategory.video);
      }
    } finally {
      _isLoading = false;

    }
  }

  /// Get video event by ID
  VideoEvent? getVideoEventById(String eventId) {
    try {
      return _videoEvents.firstWhere((event) => event.id == eventId);
    } catch (e) {
      return null;
    }
  }

  /// Get video event by vine ID (using 'd' tag)
  VideoEvent? getVideoEventByVineId(String vineId) {
    try {
      return _videoEvents.firstWhere((event) => event.vineId == vineId);
    } catch (e) {
      return null;
    }
  }

  /// Query video events by vine ID from relays
  Future<VideoEvent?> queryVideoByVineId(String vineId) async {
    if (!_nostrService.isInitialized) {
      throw const VideoEventServiceException('Nostr service not initialized');
    }

    Log.debug('Querying for video with vine ID: $vineId',
        name: 'VideoEventService', category: LogCategory.video);

    final completer = Completer<VideoEvent?>();
    VideoEvent? foundEvent;

    // Note: Since Filter doesn't support custom tags, we'll fetch recent videos
    // and filter client-side for the specific vine ID
    final filter = Filter(
      kinds: [22],
      limit: 100, // Fetch more to increase chance of finding the video
    );

    Log.debug('Querying for videos, will filter for vine ID: $vineId',
        name: 'VideoEventService', category: LogCategory.video);

    final eventStream = _nostrService.subscribeToEvents(filters: [filter]);
    late StreamSubscription subscription;

    subscription = eventStream.listen(
      (event) {
        try {
          final videoEvent = VideoEvent.fromNostrEvent(event);
          // Check if this video has the vine ID we're looking for
          if (videoEvent.vineId == vineId) {
            Log.info(
                'Found video event for vine ID $vineId: ${event.id.substring(0, 8)}...',
                name: 'VideoEventService',
                category: LogCategory.video);
            foundEvent = videoEvent;
            if (!completer.isCompleted) {
              completer.complete(foundEvent);
            }
            subscription.cancel();
          }
        } catch (e) {
          Log.error('Error parsing video event: $e',
              name: 'VideoEventService', category: LogCategory.video);
        }
      },
      onError: (error) {
        Log.error('Error querying video by vine ID: $error',
            name: 'VideoEventService', category: LogCategory.video);
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
        subscription.cancel();
      },
      onDone: () {
        Log.info('📱 Vine ID query completed',
            name: 'VideoEventService', category: LogCategory.video);
        if (!completer.isCompleted) {
          completer.complete(foundEvent);
        }
      },
    );

    // Set timeout
    Timer(const Duration(seconds: 10), () {
      if (!completer.isCompleted) {
        Log.debug('⏰ Vine ID query timed out',
            name: 'VideoEventService', category: LogCategory.video);
        subscription.cancel();
        completer.complete(null);
      }
    });

    return completer.future;
  }

  /// Get video events by author
  List<VideoEvent> getVideoEventsByAuthor(String pubkey) =>
      _videoEvents.where((event) => event.pubkey == pubkey).toList();

  /// Get video events with specific hashtags
  List<VideoEvent> getVideoEventsByHashtags(List<String> hashtags) =>
      _videoEvents
          .where((event) => hashtags.any((tag) => event.hashtags.contains(tag)))
          .toList();

  /// Clear all video events
  void clearVideoEvents() {
    _videoEvents.clear();

  }

  /// Cancel all existing subscriptions
  Future<void> _cancelExistingSubscriptions() async {
    // Cancel managed subscriptions
    if (_activeSubscriptionIds.isNotEmpty) {
      Log.debug(
          'Cancelling ${_activeSubscriptionIds.length} managed subscriptions...',
          name: 'VideoEventService',
          category: LogCategory.video);
      for (final subscriptionId in _activeSubscriptionIds) {
        await _subscriptionManager.cancelSubscription(subscriptionId);
      }
      _activeSubscriptionIds.clear();
    }

    // Cancel direct subscriptions
    if (_subscriptions.isNotEmpty) {
      Log.debug('Cancelling ${_subscriptions.length} direct subscriptions...',
          name: 'VideoEventService', category: LogCategory.video);
      for (final entry in _subscriptions.entries) {
        await entry.value.cancel();
      }
      _subscriptions.clear();
    }
  }

  /// Unsubscribe from all video event subscriptions
  Future<void> unsubscribeFromVideoFeed() async {
    try {
      await _cancelExistingSubscriptions();
      _isSubscribed = false;
      _currentSubscriptionParams.clear();

      Log.info('Successfully unsubscribed from all video events',
          name: 'VideoEventService', category: LogCategory.video);
    } catch (e) {
      Log.error('Error unsubscribing from video events: $e',
          name: 'VideoEventService', category: LogCategory.video);
    }


  }

  /// Get video events sorted by engagement (placeholder - would need reaction events)
  List<VideoEvent> getVideoEventsByEngagement() {
    // For now, just return chronologically sorted
    // In a full implementation, would sort by likes, comments, shares, etc.
    return List.from(_videoEvents)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Get video events from last N hours
  List<VideoEvent> getRecentVideoEvents({int hours = 24}) {
    final cutoff = DateTime.now().subtract(Duration(hours: hours));
    return _videoEvents
        .where((event) => event.timestamp.isAfter(cutoff))
        .toList();
  }

  /// Get unique authors from video events
  Set<String> getUniqueAuthors() =>
      _videoEvents.map((event) => event.pubkey).toSet();

  /// Get all hashtags from video events
  Set<String> getAllHashtags() {
    final allTags = <String>{};
    for (final event in _videoEvents) {
      allTags.addAll(event.hashtags);
    }
    return allTags;
  }

  /// Get video events count by author
  Map<String, int> getVideoCountByAuthor() {
    final counts = <String, int>{};
    for (final event in _videoEvents) {
      counts[event.pubkey] = (counts[event.pubkey] ?? 0) + 1;
    }
    return counts;
  }

  /// Fetch original event for a repost from relays
  Future<void> _fetchOriginalEventForRepost(
      String originalEventId, Event repostEvent) async {
    try {
      Log.debug(
          'Fetching original event $originalEventId for repost ${repostEvent.id.substring(0, 8)}...',
          name: 'VideoEventService',
          category: LogCategory.video);

      // Create a one-shot subscription to fetch the specific event
      final eventStream = _nostrService.subscribeToEvents(
        filters: [
          Filter(
            ids: [originalEventId],
          ),
        ],
      );

      // Listen for the original event
      late StreamSubscription subscription;
      subscription = eventStream.listen(
        (originalEvent) {
          Log.debug(
              'Retrieved original event ${originalEvent.id.substring(0, 8)}...',
              name: 'VideoEventService',
              category: LogCategory.video);
          Log.debug('Event tags: ${originalEvent.tags}',
              name: 'VideoEventService', category: LogCategory.video);

          // Check if it's a valid video event
          if (originalEvent.kind == 22) {
            try {
              final originalVideoEvent =
                  VideoEvent.fromNostrEvent(originalEvent);
              Log.debug(
                  'Parsed video event: hasVideo=${originalVideoEvent.hasVideo}, videoUrl=${originalVideoEvent.videoUrl}',
                  name: 'VideoEventService',
                  category: LogCategory.video);

              // Only process if it has video content
              if (originalVideoEvent.hasVideo) {
                // Create the repost version
                final repostVideoEvent = VideoEvent.createRepostEvent(
                  originalEvent: originalVideoEvent,
                  repostEventId: repostEvent.id,
                  reposterPubkey: repostEvent.pubkey,
                  repostedAt: DateTime.fromMillisecondsSinceEpoch(
                      repostEvent.createdAt * 1000),
                );

                // Check hashtag filter for fetched reposts too
                if (_activeHashtagFilter != null &&
                    _activeHashtagFilter!.isNotEmpty) {
                  final hasRequiredHashtag = _activeHashtagFilter!.any(
                    repostVideoEvent.hashtags.contains,
                  );

                  if (!hasRequiredHashtag) {
                    Log.warning(
                        '⏩ Skipping fetched repost without required hashtags: $_activeHashtagFilter',
                        name: 'VideoEventService',
                        category: LogCategory.video);
                    return;
                  }
                }

                // Add to video events
                _addVideoWithPriority(repostVideoEvent);

                // Keep list size manageable
                if (_videoEvents.length > 500) {
                  _videoEvents.removeRange(500, _videoEvents.length);
                }

                Log.debug(
                    'Added fetched repost event! Total: ${_videoEvents.length} events',
                    name: 'VideoEventService',
                    category: LogCategory.video);

              } else {
                Log.warning('⏩ Skipping repost of video without URL',
                    name: 'VideoEventService', category: LogCategory.video);
              }
            } catch (e) {
              Log.error('Failed to parse original video event for repost: $e',
                  name: 'VideoEventService', category: LogCategory.video);
            }
          }

          // Clean up subscription
          subscription.cancel();
        },
        onError: (error) {
          Log.error('Error fetching original event for repost: $error',
              name: 'VideoEventService', category: LogCategory.video);
          subscription.cancel();
        },
        onDone: () {
          Log.debug('📱 Finished fetching original event for repost',
              name: 'VideoEventService', category: LogCategory.video);
          subscription.cancel();
        },
      );

      // Set timeout to avoid hanging
      Timer(const Duration(seconds: 5), () {
        Log.debug('⏰ Timeout fetching original event for repost',
            name: 'VideoEventService', category: LogCategory.video);
        subscription.cancel();
      });
    } catch (e) {
      Log.error('Error in _fetchOriginalEventForRepost: $e',
          name: 'VideoEventService', category: LogCategory.video);
    }
  }

  /// Check if an error is connection-related
  bool _isConnectionError(dynamic error) {
    final errorString = error.toString().toLowerCase();
    return errorString.contains('connection') ||
        errorString.contains('network') ||
        errorString.contains('socket') ||
        errorString.contains('timeout') ||
        errorString.contains('offline') ||
        errorString.contains('unreachable');
  }

  /// Schedule retry when device comes back online
  void _scheduleRetryWhenOnline() {
    _retryTimer?.cancel();

    _retryTimer = Timer.periodic(_retryDelay, (timer) {
      if (_connectionService.isOnline && _retryAttempts < _maxRetryAttempts) {
        _retryAttempts++;
        Log.warning(
            'Attempting to resubscribe to video feed (attempt $_retryAttempts/$_maxRetryAttempts)',
            name: 'VideoEventService',
            category: LogCategory.video);

        subscribeToVideoFeed().then((_) {
          // Success - cancel retry timer
          timer.cancel();
          _retryAttempts = 0;
          Log.info('Successfully resubscribed to video feed',
              name: 'VideoEventService', category: LogCategory.video);
        }).catchError((e) {
          Log.error('Retry attempt $_retryAttempts failed: $e',
              name: 'VideoEventService', category: LogCategory.video);

          if (_retryAttempts >= _maxRetryAttempts) {
            timer.cancel();
            Log.warning(
                'Max retry attempts reached for video feed subscription',
                name: 'VideoEventService',
                category: LogCategory.video);
          }
        });
      } else if (!_connectionService.isOnline) {
        Log.debug('⏳ Still offline, waiting for connection...',
            name: 'VideoEventService', category: LogCategory.video);
      } else {
        // Max retries reached
        timer.cancel();
      }
    });
  }

  /// Get connection status for debugging
  Map<String, dynamic> getConnectionStatus() => {
        'isSubscribed': _isSubscribed,
        'isLoading': _isLoading,
        'eventCount': _videoEvents.length,
        'retryAttempts': _retryAttempts,
        'hasError': _error != null,
        'lastError': _error,
        'connectionInfo': _connectionService.getConnectionInfo(),
      };

  /// Force retry subscription
  Future<void> retrySubscription() async {
    Log.warning('Forcing retry of video feed subscription...',
        name: 'VideoEventService', category: LogCategory.video);
    _retryAttempts = 0;
    _error = null;

    try {
      await subscribeToVideoFeed();
    } catch (e) {
      Log.error('Manual retry failed: $e',
          name: 'VideoEventService', category: LogCategory.video);
      rethrow;
    }
  }

  /// Check if a repost event is likely to reference video content
  bool _isLikelyVideoRepost(Event repostEvent) {
    // Check content for video-related keywords
    final content = repostEvent.content.toLowerCase();
    final videoKeywords = [
      'video',
      'gif',
      'mp4',
      'webm',
      'mov',
      'vine',
      'clip',
      'watch'
    ];

    // Check for video file extensions or video-related terms
    if (videoKeywords.any(content.contains)) {
      return true;
    }

    // Check tags for video-related hashtags
    for (final tag in repostEvent.tags) {
      if (tag.isNotEmpty && tag[0] == 't' && tag.length > 1) {
        final hashtag = tag[1].toLowerCase();
        if (videoKeywords.any(hashtag.contains)) {
          return true;
        }
      }
    }

    // Check for presence of 'k' tag indicating original event kind
    for (final tag in repostEvent.tags) {
      if (tag.isNotEmpty && tag[0] == 'k' && tag.length > 1) {
        // If the repost explicitly indicates it's reposting a kind 22 event
        if (tag[1] == '22') {
          return true;
        }
      }
    }

    // For now, default to processing all reposts to avoid missing content
    // This can be made more strict as we gather data on repost patterns
    return true;
  }

  /// Ensure default content is available for new users
  void _ensureDefaultContent() {
    // DISABLED: Default video system disabled due to loading issues
    // The default video was not loading properly and causing user experience issues
    Log.warning(
        'Default video system is disabled - users will see real content only',
        name: 'VideoEventService',
        category: LogCategory.video);
    return;
  }


  /// Add video maintaining priority order (follows first, then classic vines, then everything else)
  void _addVideoWithPriority(VideoEvent videoEvent) {
    // Check for duplicates - CRITICAL to prevent the same event being added multiple times
    final existingIndex =
        _videoEvents.indexWhere((existing) => existing.id == videoEvent.id);
    if (existingIndex != -1) {
      _duplicateVideoEventCount++;
      _logDuplicateVideoEventsAggregated();
      return; // Don't add duplicate events
    }

    // CRITICAL: Validate that video has an accessible URL before adding to feed
    if (!_hasValidVideoUrl(videoEvent)) {
      Log.warning(
        'Rejecting video ${videoEvent.id.substring(0, 8)} - no valid video URL (url: ${videoEvent.videoUrl})',
        name: 'VideoEventService',
        category: LogCategory.video
      );
      return; // Don't add videos without valid URLs
    }

    // Check if this is from someone the user follows
    // TODO: Get following list from SocialService
    final isFollowed = false; // Placeholder - will be implemented
    final isClassicVine = videoEvent.pubkey == AppConstants.classicVinesPubkey;

    // Priority order: 1) Follows, 2) Classic Vines, 3) Everything else by timestamp
    if (isFollowed) {
      // Content from followed users - highest priority, sorted by timestamp (newest first)
      var insertIndex = 0;
      
      // Find insertion point among followed content
      for (var i = 0; i < _videoEvents.length; i++) {
        // TODO: Check if _videoEvents[i] is from followed user
        // For now, assume follows are at the top
        if (_videoEvents[i].timestamp.isBefore(videoEvent.timestamp)) {
          break;
        }
        insertIndex = i + 1;
      }
      
      _videoEvents.insert(insertIndex, videoEvent);
      Log.verbose(
          'Added FOLLOWED USER video at position $insertIndex: ${videoEvent.title ?? videoEvent.id.substring(0, 8)}',
          name: 'VideoEventService',
          category: LogCategory.video);
    } else if (isClassicVine) {
      // Classic vine - secondary priority after follows
      var insertIndex = 0;
      // Skip past followed content first
      // TODO: Implement proper following detection
      
      // For now, just add classic vines after any existing priority content
      _videoEvents.insert(insertIndex, videoEvent);
      Log.verbose(
          'Added CLASSIC VINE at position $insertIndex: ${videoEvent.title ?? videoEvent.id.substring(0, 8)}',
          name: 'VideoEventService',
          category: LogCategory.video);
    } else {
      // Regular video - lowest priority, sorted by timestamp (newest first)
      _videoEvents.add(videoEvent);
      Log.verbose(
          'Added regular video: ${videoEvent.title ?? videoEvent.id.substring(0, 8)}',
          name: 'VideoEventService',
          category: LogCategory.video);
    }
  }

  /// Log duplicate video events in an aggregated manner to reduce noise
  void _logDuplicateVideoEventsAggregated() {
    final now = DateTime.now();

    // Log aggregated duplicates every 30 seconds or every 25 duplicates
    if (_lastDuplicateVideoLogTime == null ||
        now.difference(_lastDuplicateVideoLogTime!).inSeconds >= 30 ||
        _duplicateVideoEventCount % 25 == 0) {
      if (_duplicateVideoEventCount > 0) {
        Log.verbose(
            '⏩ Skipped $_duplicateVideoEventCount duplicate video events in last ${_lastDuplicateVideoLogTime != null ? now.difference(_lastDuplicateVideoLogTime!).inSeconds : 0}s',
            name: 'VideoEventService',
            category: LogCategory.video);
      }

      _lastDuplicateVideoLogTime = now;
      _duplicateVideoEventCount = 0;
    }
  }

  /// Check if the given subscription parameters match the current active subscription
  bool _isDuplicateSubscription(
    List<String>? authors,
    List<String>? hashtags,
    String? group,
    int limit,
    int? since,
    int? until,
  ) {
    // If no active subscriptions, it's not a duplicate
    if (_subscriptions.isEmpty && _activeSubscriptionIds.isEmpty) {
      return false;
    }

    // Compare with stored subscription parameters
    final currentAuthors =
        _currentSubscriptionParams['authors'] as List<String>?;
    final currentHashtags =
        _currentSubscriptionParams['hashtags'] as List<String>?;
    final currentGroup = _currentSubscriptionParams['group'] as String?;
    final currentSince = _currentSubscriptionParams['since'] as int?;
    final currentUntil = _currentSubscriptionParams['until'] as int?;
    final currentLimit = _currentSubscriptionParams['limit'] as int?;

    // Check if parameters match
    return _listEquals(authors, currentAuthors) &&
        _listEquals(hashtags, currentHashtags) &&
        group == currentGroup &&
        since == currentSince &&
        until == currentUntil &&
        limit == currentLimit;
  }

  /// Helper to compare two lists for equality
  bool _listEquals<T>(List<T>? a, List<T>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void dispose() {
    _retryTimer?.cancel();
    _authStateSubscription?.cancel();
    unsubscribeFromVideoFeed();
    
  }

  /// Shuffle regular videos for users not following anyone (preserves classic vines at top)
  void shuffleForDiscovery() {
    if (!_isFollowingFeed && _videoEvents.isNotEmpty) {
      Log.debug('📱 Shuffling videos for discovery mode...',
          name: 'VideoEventService', category: LogCategory.video);

      // Find where classic vines end (they should stay at top)
      var classicVineCount = 0;
      for (var i = 0; i < _videoEvents.length; i++) {
        if (_videoEvents[i].pubkey == AppConstants.classicVinesPubkey) {
          classicVineCount = i + 1;
        } else {
          break;
        }
      }

      // Extract regular videos (everything after classic vines)
      if (classicVineCount < _videoEvents.length) {
        final regularVideos = _videoEvents.sublist(classicVineCount);

        // Shuffle them
        regularVideos.shuffle();

        // Remove old regular videos
        _videoEvents.removeRange(classicVineCount, _videoEvents.length);

        // Add shuffled videos back
        _videoEvents.addAll(regularVideos);

        Log.info('Shuffled ${regularVideos.length} videos for discovery',
            name: 'VideoEventService', category: LogCategory.video);

      }
    }
  }

  /// Add a video event to the cache (for external services like CurationService)
  void addVideoEvent(VideoEvent videoEvent) {
    _addVideoWithPriority(videoEvent);

  }

  /// Validate that a video event has a valid, accessible URL
  bool _hasValidVideoUrl(VideoEvent videoEvent) {
    final videoUrl = videoEvent.videoUrl;
    
    // Must have a video URL
    if (videoUrl == null || videoUrl.isEmpty) {
      return false;
    }
    
    // Must be a valid HTTP/HTTPS URL
    try {
      final uri = Uri.parse(videoUrl);
      if (!['http', 'https'].contains(uri.scheme.toLowerCase())) {
        return false;
      }
      
      // Must have a valid host
      if (uri.host.isEmpty) {
        return false;
      }
      
      // Reject known broken domains
      if (videoUrl.contains('apt.openvine.co')) {
        Log.debug('Rejecting broken apt.openvine.co URL: $videoUrl', 
            name: 'VideoEventService', category: LogCategory.video);
        return false;
      }
      
      return true;
    } catch (e) {
      Log.debug('Invalid video URL format: $videoUrl - $e', 
          name: 'VideoEventService', category: LogCategory.video);
      return false;
    }
  }
}

/// Exception thrown by video event service operations
/// REFACTORED: Removed ChangeNotifier - now uses pure state management via Riverpod
class VideoEventServiceException implements Exception {
  const VideoEventServiceException(this.message);
  final String message;

  @override
  String toString() => 'VideoEventServiceException: $message';
}
