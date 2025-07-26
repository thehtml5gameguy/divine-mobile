// ABOUTME: Simple unit test for VideoManager state management without video preloading
// ABOUTME: Tests basic state operations without requiring actual video controller initialization

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:openvine/providers/video_manager_providers.dart';
import '../../builders/test_video_event_builder.dart';
import '../../helpers/simple_test_helpers.dart';

void main() {
  group('VideoManager State Tests', () {
    initializeTestEnvironment();

    test('VideoManager should initialize with empty state', () {
      final container = ProviderContainer();
      
      final state = container.read(videoManagerProvider);
      
      expect(state.controllers.isEmpty, isTrue);
      expect(state.config, isNotNull);
      expect(state.videoEvents.isEmpty, isTrue);
      
      container.dispose();
    });

    test('VideoManager should accept video events', () {
      final container = ProviderContainer();
      final manager = container.read(videoManagerProvider.notifier);
      
      final testVideo = TestVideoEventBuilder.create(
        id: 'test_video_1',
        title: 'Test Video 1',
      );
      
      // Add video event
      manager.addVideoEvent(testVideo);
      
      final state = container.read(videoManagerProvider);
      expect(state.videoEvents.containsKey('test_video_1'), isTrue);
      expect(state.videoEvents['test_video_1']?.title, equals('Test Video 1'));
      
      container.dispose();
    });

    test('VideoManager should track multiple video events', () {
      final container = ProviderContainer();
      final manager = container.read(videoManagerProvider.notifier);
      
      // Add multiple videos
      final videos = TestVideoEventBuilder.createMultiple(count: 3);
      for (final video in videos) {
        manager.addVideoEvent(video);
      }
      
      final state = container.read(videoManagerProvider);
      expect(state.videoEvents.length, equals(3));
      
      container.dispose();
    });

    test('VideoManager should update existing video events', () {
      final container = ProviderContainer();
      final manager = container.read(videoManagerProvider.notifier);
      
      // Add initial video
      final video1 = TestVideoEventBuilder.create(
        id: 'video_1',
        title: 'Original Title',
      );
      manager.addVideoEvent(video1);
      
      // Update with new title
      final video2 = TestVideoEventBuilder.create(
        id: 'video_1',
        title: 'Updated Title',
      );
      manager.addVideoEvent(video2);
      
      final state = container.read(videoManagerProvider);
      expect(state.videoEvents.length, equals(1));
      expect(state.videoEvents['video_1']?.title, equals('Updated Title'));
      
      container.dispose();
    });
  });
}