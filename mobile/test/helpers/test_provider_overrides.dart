// ABOUTME: Common provider overrides for tests to inject test implementations
// ABOUTME: Provides consistent test environment setup across all test files

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'test_video_controller.dart';

/// Factory for creating test video controllers
VideoPlayerController testVideoControllerFactory(String url) {
  return TestVideoPlayerController(url);
}

/// Common provider overrides for tests
List<Override> getTestProviderOverrides({
  List<Override>? additionalOverrides,
}) {
  return [
    // Add video controller factory override here when we have the provider
    // videoControllerFactoryProvider.overrideWithValue(testVideoControllerFactory),
    ...?additionalOverrides,
  ];
}