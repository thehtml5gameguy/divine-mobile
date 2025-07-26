// ABOUTME: Abstract camera provider interface for platform-specific implementations
// ABOUTME: Enables different camera strategies per platform without coupling to specific plugins

import 'dart:typed_data';
import 'package:flutter/widgets.dart';

/// Abstract interface for camera functionality across platforms
abstract class CameraProvider {
  /// Initialize the camera system
  Future<void> initialize();

  /// Check if camera is ready for use
  bool get isInitialized;

  /// Build a preview widget for the camera feed
  Widget buildPreview();

  /// Start recording with optional real-time frame callback
  Future<void> startRecording({
    Function(Uint8List frameData)? onFrame,
  });

  /// Stop recording and return the result
  Future<CameraRecordingResult> stopRecording();

  /// Switch between front/back cameras if available
  Future<void> switchCamera();

  /// Clean up resources
  Future<void> dispose();
}

/// Extended interface for camera providers that support zoom functionality
abstract class CameraZoomCapable {
  /// Get current zoom level
  double get currentZoomLevel;
  
  /// Get maximum zoom level supported by device
  double get maxZoomLevel;
  
  /// Get minimum zoom level (typically 1.0)
  double get minZoomLevel;
  
  /// Check if zoom is supported on current device
  bool get isZoomSupported;
  
  /// Enable/disable smooth zoom transitions
  bool enableSmoothZoom = false;
  
  /// Set zoom level
  Future<bool> setZoomLevel(double level);
  
  /// Convert pinch gesture scale to zoom level
  double convertScaleToZoom(double scale);
}

/// Result from camera recording, platform-agnostic
class CameraRecordingResult {
  CameraRecordingResult({
    required this.width,
    required this.height,
    required this.duration,
    this.videoPath,
    this.liveFrames,
  });

  /// Path to recorded video file (for extraction-based approaches)
  final String? videoPath;

  /// Real-time captured frames (for streaming-based approaches)
  final List<Uint8List>? liveFrames;

  /// Video dimensions
  final int width;
  final int height;

  /// Recording duration
  final Duration duration;

  /// Whether this result has usable frames
  bool get hasFrames =>
      (liveFrames != null && liveFrames!.isNotEmpty) ||
      (videoPath != null && videoPath!.isNotEmpty);

  /// Determine the frame extraction strategy needed
  FrameExtractionStrategy get extractionStrategy {
    if (liveFrames != null && liveFrames!.isNotEmpty) {
      return FrameExtractionStrategy.useRealTimeFrames;
    }
    if (videoPath != null && videoPath!.isNotEmpty) {
      return FrameExtractionStrategy.extractFromVideo;
    }
    return FrameExtractionStrategy.usePlaceholderFrames;
  }
}

/// Strategy for extracting frames from camera recording
enum FrameExtractionStrategy {
  /// Use frames captured in real-time during recording
  useRealTimeFrames,

  /// Extract frames from recorded video file
  extractFromVideo,

  /// Fallback to placeholder frames (development/testing)
  usePlaceholderFrames,
}

/// Exception thrown when camera provider operations fail
class CameraProviderException implements Exception {
  CameraProviderException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'CameraProviderException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}
