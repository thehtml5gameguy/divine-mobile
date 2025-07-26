// ABOUTME: Riverpod stream provider for managing Nostr video event subscriptions
// ABOUTME: Handles real-time video feed updates based on current feed mode

import 'dart:async';

import 'package:nostr_sdk/filter.dart';
import 'package:openvine/constants/app_constants.dart';
import 'package:openvine/models/video_event.dart';
import 'package:openvine/providers/app_providers.dart';
import 'package:openvine/providers/feed_mode_providers.dart';
import 'package:openvine/providers/social_providers.dart';
import 'package:openvine/services/nostr_service_interface.dart';
import 'package:openvine/services/subscription_manager.dart';
import 'package:openvine/services/video_event_service.dart';
import 'package:openvine/state/video_feed_state.dart';
import 'package:openvine/utils/unified_logger.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'video_events_providers.g.dart';

/// Provider for NostrService instance (Video Events specific)
@riverpod
INostrService videoEventsNostrService(Ref ref) {
  throw UnimplementedError(
      'VideoEventsNostrService must be overridden in ProviderScope');
}

/// Provider for SubscriptionManager instance (Video Events specific)
@riverpod
SubscriptionManager videoEventsSubscriptionManager(
    Ref ref) {
  throw UnimplementedError(
      'VideoEventsSubscriptionManager must be overridden in ProviderScope');
}

/// Stream provider for video events from Nostr
@riverpod
class VideoEvents extends _$VideoEvents {
  StreamController<List<VideoEvent>>? _controller;
  Timer? _refreshTimer;

  @override
  Stream<List<VideoEvent>> build() {
    // Use existing VideoEventService instead of duplicating subscription logic
    final videoEventService = ref.watch(videoEventServiceProvider);

    Log.info(
      'VideoEvents: Using VideoEventService as source (${videoEventService.videoEvents.length} events)',
      name: 'VideoEventsProvider', 
      category: LogCategory.video,
    );

    // Subscribe based on current feed mode
    _subscribeBasedOnFeedMode(videoEventService);
    
    // Watch for feed mode changes
    ref.listen(feedModeNotifierProvider, (previous, next) {
      if (previous != next) {
        Log.info(
          'VideoEvents: Feed mode changed from $previous to $next',
          name: 'VideoEventsProvider',
          category: LogCategory.video,
        );
        _subscribeBasedOnFeedMode(videoEventService);
      }
    });
    
    // Watch for feed context changes (for hashtag/profile modes)
    ref.listen(feedContextProvider, (previous, next) {
      final feedMode = ref.read(feedModeNotifierProvider);
      if ((feedMode == FeedMode.hashtag || feedMode == FeedMode.profile) && previous != next) {
        Log.info(
          'VideoEvents: Feed context changed from $previous to $next',
          name: 'VideoEventsProvider',
          category: LogCategory.video,
        );
        _subscribeBasedOnFeedMode(videoEventService);
      }
    });

    // Create a new stream controller
    _controller = StreamController<List<VideoEvent>>.broadcast();
    
    // Emit current events immediately
    final currentEvents = List<VideoEvent>.from(videoEventService.videoEvents);
    _controller!.add(currentEvents);

    // Since VideoEventService no longer extends ChangeNotifier,
    // we need to periodically check for updates
    // This is a more efficient approach that only rebuilds when data actually changes
    int lastEventCount = currentEvents.length;
    String? lastEventId = currentEvents.isNotEmpty ? currentEvents.first.id : null;
    
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final newEvents = videoEventService.videoEvents;
      final newEventCount = newEvents.length;
      final newLastEventId = newEvents.isNotEmpty ? newEvents.first.id : null;
      
      // Only emit if there's an actual change
      if (newEventCount != lastEventCount || newLastEventId != lastEventId) {
        Log.debug(
          'VideoEvents: Detected change - count: $lastEventCount → $newEventCount, latest: ${lastEventId?.substring(0, 8)} → ${newLastEventId?.substring(0, 8)}',
          name: 'VideoEventsProvider',
          category: LogCategory.video,
        );
        lastEventCount = newEventCount;
        lastEventId = newLastEventId;
        _controller!.add(List<VideoEvent>.from(newEvents));
      }
    });

    // Clean up on dispose
    ref.onDispose(() {
      _refreshTimer?.cancel();
      _controller?.close();
    });

    return _controller!.stream;
  }

  /// Create filter based on current feed mode
  Filter? _createFilter() {
    final feedMode = ref.read(feedModeNotifierProvider);
    final feedContext = ref.read(feedContextProvider);
    final socialData = ref.read(socialNotifierProvider);

    // Base filter for video events
    final filter = Filter(
      kinds: [22],
      limit: 500,
      // Removed h: ['vine'] restriction to get all video events, not just vine-tagged ones
    );

    switch (feedMode) {
      case FeedMode.following:
        // Use following list or classic vines fallback
        final followingList = socialData.followingPubkeys;
        filter.authors = followingList.isNotEmpty
            ? followingList
            : [AppConstants.classicVinesPubkey];

        Log.info(
          'VideoEvents: Following mode with ${filter.authors!.length} authors',
          name: 'VideoEventsProvider',
          category: LogCategory.video,
        );

      case FeedMode.curated:
        // Only classic vines curator
        filter.authors = [AppConstants.classicVinesPubkey];
        Log.info(
          'VideoEvents: Curated mode',
          name: 'VideoEventsProvider',
          category: LogCategory.video,
        );

      case FeedMode.discovery:
        // General feed - no author filter
        Log.info(
          'VideoEvents: Discovery mode',
          name: 'VideoEventsProvider',
          category: LogCategory.video,
        );

      case FeedMode.hashtag:
        // Filter by hashtag
        if (feedContext != null) {
          filter.t = [feedContext];
          Log.info(
            'VideoEvents: Hashtag mode for #$feedContext',
            name: 'VideoEventsProvider',
            category: LogCategory.video,
          );
        } else {
          Log.warning(
            'VideoEvents: Hashtag mode but no context',
            name: 'VideoEventsProvider',
            category: LogCategory.video,
          );
          return null;
        }

      case FeedMode.profile:
        // Filter by specific author
        if (feedContext != null) {
          filter.authors = [feedContext];
          Log.info(
            'VideoEvents: Profile mode for $feedContext',
            name: 'VideoEventsProvider',
            category: LogCategory.video,
          );
        } else {
          Log.warning(
            'VideoEvents: Profile mode but no context',
            name: 'VideoEventsProvider',
            category: LogCategory.video,
          );
          return null;
        }
    }

    return filter;
  }
  
  /// Subscribe to video feed based on current feed mode
  void _subscribeBasedOnFeedMode(VideoEventService videoEventService) {
    final filter = _createFilter();
    if (filter == null) {
      Log.warning(
        'VideoEvents: Cannot create filter for current feed mode',
        name: 'VideoEventsProvider',
        category: LogCategory.video,
      );
      return;
    }
    
    Log.info(
      'VideoEvents: Subscribing with filter: ${filter.toJson()}',
      name: 'VideoEventsProvider',
      category: LogCategory.video,
    );
    
    // Subscribe with the appropriate parameters
    videoEventService.subscribeToVideoFeed(
      authors: filter.authors,
      hashtags: filter.t,
      limit: filter.limit ?? 100,
      includeReposts: true,
      replace: true, // Replace existing subscription when mode changes
    );
  }

  /// Load more historical events
  Future<void> loadMoreEvents() async {
    final videoEventService = ref.read(videoEventServiceProvider);
    
    // Delegate to VideoEventService which already has this functionality
    await videoEventService.loadMoreEvents(limit: 50);
    
    // The periodic timer will automatically pick up the new events
    // and emit them through the stream
  }

  /// Clear all events and refresh
  Future<void> refresh() async {
    final videoEventService = ref.read(videoEventServiceProvider);
    await videoEventService.refreshVideoFeed();
    // The stream will automatically emit the refreshed events
  }
}

/// Provider to check if video events are loading
@riverpod
bool videoEventsLoading(Ref ref) =>
    ref.watch(videoEventsProvider).isLoading;

/// Provider to get video event count
@riverpod
int videoEventCount(Ref ref) =>
    ref.watch(videoEventsProvider).valueOrNull?.length ?? 0;
