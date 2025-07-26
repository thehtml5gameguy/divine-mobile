// ABOUTME: Simplified camera service using direct video recording for vine creation
// ABOUTME: Records MP4 videos directly without frame extraction complexity

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:openvine/utils/unified_logger.dart';

/// Camera recording configuration
/// REFACTORED: Removed ChangeNotifier - now uses pure state management via Riverpod
class CameraConfiguration {
  const CameraConfiguration({
    this.recordingDuration =
        const Duration(milliseconds: 6300), // 6.3 seconds like original Vine
    this.enableAutoStop = true,
  });
  final Duration recordingDuration;
  final bool enableAutoStop;

  /// Create configuration for vine-style recording (3-15 seconds)
  static CameraConfiguration vine({
    Duration? duration,
    bool? autoStop,
  }) {
    Duration clampedDuration;
    if (duration != null) {
      final seconds = duration.inSeconds;
      final clampedSeconds = seconds.clamp(3, 15);
      clampedDuration = Duration(seconds: clampedSeconds);
    } else {
      clampedDuration =
          const Duration(milliseconds: 6300); // 6.3 seconds like original Vine
    }

    return CameraConfiguration(
      recordingDuration: clampedDuration,
      enableAutoStop: autoStop ?? true,
    );
  }

  @override
  String toString() =>
      'CameraConfiguration(duration: ${recordingDuration.inSeconds}s)';
}

enum RecordingState {
  idle,
  initializing,
  recording,
  processing,
  completed,
  error,
}

/// REFACTORED: Removed ChangeNotifier - now uses pure state management via Riverpod
class CameraService  {
  CameraController? _controller;
  RecordingState _state = RecordingState.idle;
  bool _disposed = false;

  // Recording state
  bool _isRecording = false;
  DateTime? _recordingStartTime;
  Timer? _progressTimer;
  Timer? _autoStopTimer;

  // Recording configuration
  CameraConfiguration _configuration = const CameraConfiguration();

  // Zoom state
  double _currentZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  double _minZoomLevel = 1.0;
  bool _isZoomSupported = false;
  final StreamController<double> _zoomChangeController = StreamController<double>.broadcast();

  // Convenience getters for current configuration
  Duration get maxVineDuration => _configuration.recordingDuration;
  bool get enableAutoStop => _configuration.enableAutoStop;
  CameraConfiguration get configuration => _configuration;

  // Getters
  RecordingState get state => _state;
  bool get isInitialized => _controller?.value.isInitialized ?? false;
  bool get isRecording => _isRecording;
  double get recordingProgress {
    if (!_isRecording || _recordingStartTime == null) return 0;
    final elapsed = DateTime.now().difference(_recordingStartTime!);
    return (elapsed.inMilliseconds / maxVineDuration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  // Zoom getters
  double get currentZoomLevel => _currentZoomLevel;
  double get maxZoomLevel => _maxZoomLevel;
  double get minZoomLevel => _minZoomLevel;
  bool get isZoomSupported => _isZoomSupported;
  Stream<double> get onZoomChanged => _zoomChangeController.stream;

  /// Initialize camera for vine recording
  Future<void> initialize() async {
    try {
      _setState(RecordingState.initializing);

      // Skip camera initialization on Linux/Windows (not supported)
      if (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows) {
        throw Exception(
            'Camera recording not currently supported on Linux/Windows. Please use mobile app for recording.');
      }

      // Handle macOS camera initialization differently
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        await _initializeMacOSCamera();
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        // Check if we're running on iOS/Android simulator
        if (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android) {
          throw Exception(
              'Camera not available on simulator. Please test on a real device.');
        }
        throw Exception('No cameras available on device');
      }

      // Prefer back camera for initial setup
      final camera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        camera,
        ResolutionPreset.high, // High quality for vine videos
        enableAudio: true, // Enable audio for videos
      );

      await _controller!.initialize();

      // Prepare for video recording
      await _controller!.prepareForVideoRecording();

      // Initialize zoom capabilities
      await _initializeZoomCapabilities();

      _setState(RecordingState.idle);

      Log.info('📱 Camera initialized successfully',
          name: 'CameraService', category: LogCategory.video);
    } catch (e) {
      _setState(RecordingState.error);
      Log.error('Camera initialization failed: $e',
          name: 'CameraService', category: LogCategory.video);
      rethrow;
    }
  }

  /// Start vine recording (direct video recording)
  Future<void> startRecording() async {
    if (!isInitialized || _isRecording) {
      Log.warning(
          'Cannot start recording: initialized=$isInitialized, recording=$_isRecording',
          name: 'CameraService',
          category: LogCategory.video);
      return;
    }

    try {
      _setState(RecordingState.recording);
      _isRecording = true;
      _recordingStartTime = DateTime.now();

      // Start video recording
      await _controller!.startVideoRecording();

      // Start progress timer to update UI regularly
      _startProgressTimer();

      // Set up auto-stop timer if enabled
      if (enableAutoStop) {
        _autoStopTimer = Timer(maxVineDuration, () {
          if (_isRecording) {
            Log.debug(
                '⏰ Auto-stopping recording after ${maxVineDuration.inSeconds}s',
                name: 'CameraService',
                category: LogCategory.video);
            stopRecording();
          }
        });
      }

      Log.info('Started vine recording (${maxVineDuration.inSeconds}s max)',
          name: 'CameraService', category: LogCategory.video);
    } catch (e) {
      _setState(RecordingState.error);
      _isRecording = false;
      Log.error('Failed to start recording: $e',
          name: 'CameraService', category: LogCategory.video);
      rethrow;
    }
  }

  /// Stop recording and return video file
  Future<VineRecordingResult> stopRecording() async {
    if (!_isRecording) {
      Log.warning('Not currently recording, cannot stop',
          name: 'CameraService', category: LogCategory.video);
      throw Exception('Not currently recording');
    }

    try {
      _setState(RecordingState.processing);

      // Cancel timers
      _stopProgressTimer();
      _autoStopTimer?.cancel();
      _autoStopTimer = null;

      // Calculate recording duration
      final duration = _recordingStartTime != null
          ? DateTime.now().difference(_recordingStartTime!)
          : Duration.zero;

      // Stop video recording
      final xFile = await _controller!.stopVideoRecording();
      final videoFile = File(xFile.path);

      _setState(RecordingState.completed);

      Log.info('Vine recording completed:',
          name: 'CameraService', category: LogCategory.video);
      Log.debug('  📹 File: ${videoFile.path}',
          name: 'CameraService', category: LogCategory.video);
      Log.debug('  ⏱️ Duration: ${duration.inSeconds}s',
          name: 'CameraService', category: LogCategory.video);
      Log.debug(
          '  📦 Size: ${(await videoFile.length() / 1024 / 1024).toStringAsFixed(2)}MB',
          name: 'CameraService',
          category: LogCategory.video);

      return VineRecordingResult(
        videoFile: videoFile,
        duration: duration,
      );
    } catch (e) {
      _setState(RecordingState.error);
      Log.error('Failed to stop recording: $e',
          name: 'CameraService', category: LogCategory.video);
      rethrow;
    } finally {
      _isRecording = false;
      _recordingStartTime = null;
    }
  }

  /// Cancel current recording
  Future<void> cancelRecording() async {
    if (!_isRecording) return;

    try {
      // Cancel timers
      _stopProgressTimer();
      _autoStopTimer?.cancel();
      _autoStopTimer = null;

      // Stop the recording without saving
      await _controller!.stopVideoRecording();

      _setState(RecordingState.idle);
      _isRecording = false;
      _recordingStartTime = null;

      Log.debug('Recording canceled',
          name: 'CameraService', category: LogCategory.video);
    } catch (e) {
      Log.error('Error canceling recording: $e',
          name: 'CameraService', category: LogCategory.video);
    }
  }

  /// Set zoom level (1.0 = no zoom, higher values = zoomed in)
  Future<void> setZoomLevel(double level) async {
    if (!isInitialized || _controller == null) {
      throw Exception('Camera not initialized');
    }

    if (level <= 0) {
      throw ArgumentError('Zoom level must be positive');
    }

    try {
      // Clamp zoom level to device capabilities
      final clampedLevel = level.clamp(_minZoomLevel, _maxZoomLevel);
      
      await _controller!.setZoomLevel(clampedLevel);
      
      _currentZoomLevel = clampedLevel;
      _zoomChangeController.add(clampedLevel);
      

      
      Log.debug('Set zoom level to ${clampedLevel}x',
          name: 'CameraService', category: LogCategory.video);
    } catch (e) {
      Log.error('Failed to set zoom level: $e',
          name: 'CameraService', category: LogCategory.video);
      rethrow;
    }
  }

  /// Handle app lifecycle state changes for zoom persistence
  void onAppLifecycleStateChanged(AppLifecycleState state) {
    // For now, maintain zoom level across lifecycle changes
    // In a more advanced implementation, we might save/restore zoom preferences
    Log.debug('App lifecycle changed: $state, maintaining zoom: $_currentZoomLevel',
        name: 'CameraService', category: LogCategory.video);
  }

  /// Switch between front and back camera
  Future<void> switchCamera() async {
    if (!isInitialized || _isRecording) return;

    try {
      final cameras = await availableCameras();
      if (cameras.length < 2) return;

      final currentCamera = _controller!.description;
      final currentDirection = currentCamera.lensDirection;

      // Find camera with opposite direction
      final newCamera = cameras.firstWhere(
        (camera) => camera.lensDirection != currentDirection,
        orElse: () => cameras.firstWhere((cam) => cam != currentCamera),
      );

      // Dispose current controller
      await _controller?.dispose();

      // Create new controller with new camera
      _controller = CameraController(
        newCamera,
        ResolutionPreset.high,
        enableAudio: true,
      );

      await _controller!.initialize();
      await _controller!.prepareForVideoRecording();

      // Reset zoom to default when switching cameras
      _currentZoomLevel = 1.0;
      await _initializeZoomCapabilities();
      

      Log.debug('Switched to ${newCamera.lensDirection} camera',
          name: 'CameraService', category: LogCategory.video);
    } catch (e) {
      Log.error('Failed to switch camera: $e',
          name: 'CameraService', category: LogCategory.video);
    }
  }

  /// Get camera preview widget
  Widget get cameraPreview {
    if (!isInitialized || _controller == null) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }
    return CameraPreview(_controller!);
  }

  /// Update camera configuration
  void updateConfiguration(CameraConfiguration newConfiguration) {
    _configuration = newConfiguration;
    Log.debug('📱 Updated camera configuration: $newConfiguration',
        name: 'CameraService', category: LogCategory.video);

  }

  /// Set recording duration (clamped to 3-15 seconds)
  void setRecordingDuration(Duration duration) {
    final seconds = duration.inSeconds.clamp(3, 15);
    final clampedDuration = Duration(seconds: seconds);

    _configuration = CameraConfiguration(
      recordingDuration: clampedDuration,
      enableAutoStop: _configuration.enableAutoStop,
    );
    Log.debug('📱 Updated recording duration to ${clampedDuration.inSeconds}s',
        name: 'CameraService', category: LogCategory.video);

  }

  /// Configure recording using vine-style presets
  void useVineConfiguration({
    Duration? duration,
    bool? autoStop,
  }) {
    _configuration = CameraConfiguration.vine(
      duration: duration,
      autoStop: autoStop,
    );
    Log.debug('📱 Applied vine configuration: $_configuration',
        name: 'CameraService', category: LogCategory.video);

  }

  /// Dispose resources
  void dispose() {
    _disposed = true;
    _stopProgressTimer();
    _autoStopTimer?.cancel();
    _zoomChangeController.close();
    _controller?.dispose();
    
  }

  // Private methods

  void _setState(RecordingState newState) {
    _state = newState;
    // With Riverpod, state changes are handled by the StateNotifier wrapper
    // No need for manual listener notification
  }

  /// Start progress timer to update UI during recording
  void _startProgressTimer() {
    _stopProgressTimer(); // Clean up any existing timer
    _progressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_isRecording && !_disposed) {
        // Progress updates are handled by Riverpod state management
        // No need for manual notification
      }
    });
  }

  /// Stop progress timer
  void _stopProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  /// Initialize zoom capabilities for the current camera
  Future<void> _initializeZoomCapabilities() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      return;
    }

    try {
      // Get zoom capabilities from camera controller
      _maxZoomLevel = await _controller!.getMaxZoomLevel();
      _minZoomLevel = await _controller!.getMinZoomLevel();
      _isZoomSupported = _maxZoomLevel > _minZoomLevel;
      
      // Reset current zoom to minimum (typically 1.0)
      _currentZoomLevel = _minZoomLevel;
      await _controller!.setZoomLevel(_currentZoomLevel);
      
      Log.info('Zoom capabilities initialized: min=${_minZoomLevel}x, max=${_maxZoomLevel}x, supported=$_isZoomSupported',
          name: 'CameraService', category: LogCategory.video);
    } catch (e) {
      Log.warning('Failed to initialize zoom capabilities: $e',
          name: 'CameraService', category: LogCategory.video);
      // Fallback to no zoom support
      _maxZoomLevel = 1.0;
      _minZoomLevel = 1.0;
      _currentZoomLevel = 1.0;
      _isZoomSupported = false;
    }
  }

  /// Initialize macOS camera using camera_macos plugin
  Future<void> _initializeMacOSCamera() async {
    try {
      // For now, throw an exception to indicate macOS needs special handling
      // We'll implement a proper macOS camera widget in the next step
      throw Exception(
          'macOS camera requires CameraMacOSView widget. Use dedicated macOS camera screen.');
    } catch (e) {
      Log.error('macOS camera initialization failed: $e',
          name: 'CameraService', category: LogCategory.video);
      // Fall back to showing error
      throw Exception('macOS camera initialization failed: $e');
    }
  }
}

/// Result from vine recording
/// REFACTORED: Removed ChangeNotifier - now uses pure state management via Riverpod
class VineRecordingResult {
  VineRecordingResult({
    required this.videoFile,
    required this.duration,
  });
  final File videoFile;
  final Duration duration;

  bool get hasVideo => videoFile.existsSync();

  @override
  String toString() =>
      'VineRecordingResult(file: ${videoFile.path}, duration: ${duration.inSeconds}s)';
}
