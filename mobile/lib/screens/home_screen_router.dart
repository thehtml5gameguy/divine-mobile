// ABOUTME: Router-driven HomeScreen implementation (clean room)
// ABOUTME: Pure presentation with no lifecycle mutations - URL is source of truth

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:openvine/providers/home_screen_controllers.dart';
import 'package:openvine/providers/route_feed_providers.dart';
import 'package:openvine/providers/user_profile_providers.dart';
import 'package:openvine/router/page_context_provider.dart';
import 'package:openvine/router/route_utils.dart';
import 'package:openvine/widgets/video_feed_item.dart';
import 'package:openvine/utils/unified_logger.dart';

/// Router-driven HomeScreen - PageView syncs with URL bidirectionally
class HomeScreenRouter extends ConsumerStatefulWidget {
  const HomeScreenRouter({super.key});

  @override
  ConsumerState<HomeScreenRouter> createState() => _HomeScreenRouterState();
}

class _HomeScreenRouterState extends ConsumerState<HomeScreenRouter> {
  PageController? _controller;
  int? _lastUrlIndex;
  int? _lastPrefetchIndex;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Read derived context from router
    final pageContext = ref.watch(pageContextProvider);

    return pageContext.when(
      data: (ctx) {
        // Only handle home routes
        if (ctx.type != RouteType.home) {
          return const Center(child: Text('Not a home route'));
        }

        final urlIndex = ctx.videoIndex ?? 0;

        // Get video data from home feed
        final videosAsync = ref.watch(videosForHomeRouteProvider);

        return videosAsync.when(
          data: (state) {
            final videos = state.videos;

            if (videos.isEmpty) {
              return const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.video_library_outlined, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text(
                      'No videos available',
                      style: TextStyle(fontSize: 18, color: Colors.grey),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Follow some creators to see their videos here',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }

            final itemCount = videos.length;

            // Initialize controller once with URL index
            if (_controller == null) {
              final safeIndex = urlIndex.clamp(0, itemCount - 1);
              _controller = PageController(initialPage: safeIndex);
              _lastUrlIndex = safeIndex;
            }

            // Sync controller when URL changes externally (back/forward/deeplink)
            // Use post-frame to avoid calling jumpToPage during build
            if (urlIndex != _lastUrlIndex && _controller!.hasClients) {
              _lastUrlIndex = urlIndex;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || !_controller!.hasClients) return;
                final safeIndex = urlIndex.clamp(0, itemCount - 1);
                final currentPage = _controller!.page?.round() ?? 0;
                if (currentPage != safeIndex) {
                  _controller!.jumpToPage(safeIndex);
                }
              });
            }

            // Prefetch profiles for adjacent videos (±1 index) only when URL index changes
            if (urlIndex != _lastPrefetchIndex) {
              _lastPrefetchIndex = urlIndex;
              final safeIndex = urlIndex.clamp(0, itemCount - 1);
              final pubkeysToPrefetech = <String>[];

              // Prefetch previous video's profile
              if (safeIndex > 0) {
                pubkeysToPrefetech.add(videos[safeIndex - 1].pubkey);
              }

              // Prefetch next video's profile
              if (safeIndex < itemCount - 1) {
                pubkeysToPrefetech.add(videos[safeIndex + 1].pubkey);
              }

              // Schedule prefetch for next frame to avoid doing work during build
              if (pubkeysToPrefetech.isNotEmpty) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  ref.read(userProfileProvider.notifier)
                      .prefetchProfilesImmediately(pubkeysToPrefetech);
                });
              }
            }

            return RefreshIndicator(
              onRefresh: () => ref.read(homeRefreshControllerProvider).refresh(),
              child: PageView.builder(
                key: const Key('home-video-page-view'),
                itemCount: videos.length,
                controller: _controller,
                scrollDirection: Axis.vertical,
                onPageChanged: (newIndex) {
                  // Guard: only navigate if URL doesn't match
                  if (newIndex != urlIndex) {
                    context.go(buildRoute(
                      RouteContext(type: RouteType.home, videoIndex: newIndex),
                    ));
                  }

                  // Trigger pagination near end
                  if (newIndex >= itemCount - 2) {
                    ref.read(homePaginationControllerProvider).maybeLoadMore();
                  }

                  Log.debug('📄 Page changed to index $newIndex (${videos[newIndex].id}...)',
                      name: 'HomeScreenRouter', category: LogCategory.video);
                },
                itemBuilder: (context, index) {
                  return VideoFeedItem(
                    key: ValueKey('video-${videos[index].id}'),
                    video: videos[index],
                    index: index,
                    hasBottomNavigation: true,
                    contextTitle: '', // Home feed has no context title
                  );
                },
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(
            child: Text('Error: $error'),
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(child: Text('Error: $error')),
    );
  }
}
