// ABOUTME: Mobile camera provider using the camera plugin for iOS/Android
// ABOUTME: Supports real-time frame streaming and video recording

import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:openvine/services/camera/camera_provider.dart';
import 'package:openvine/utils/unified_logger.dart';

/// Camera provider for iOS and Android using the camera plugin
class MobileCameraProvider implements CameraProvider, CameraZoomCapable {
  CameraController? _controller;
  bool _isRecording = false;
  bool _isStreaming = false;
  DateTime? _recordingStartTime;
  final List<Uint8List> _realtimeFrames = [];
  Function(Uint8List)? _frameCallback;

  // Zoom state
  double _currentZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  double _minZoomLevel = 1.0;
  bool _isZoomSupported = false;

  @override
  bool enableSmoothZoom = false;

  // Recording parameters
  static const Duration maxVineDuration =
      Duration(milliseconds: 6300); // 6.3 seconds like original Vine
  static const double targetFPS = 5;

  @override
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  // Zoom getters
  @override
  double get currentZoomLevel => _currentZoomLevel;

  @override
  double get maxZoomLevel => _maxZoomLevel;

  @override
  double get minZoomLevel => _minZoomLevel;

  @override
  bool get isZoomSupported => _isZoomSupported;

  @override
  Future<void> initialize() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraProviderException('No cameras available on device');
      }

      _controller = CameraController(
        cameras.first, // Use back camera by default
        ResolutionPreset.medium, // Balance quality vs performance
        enableAudio: false, // GIFs don't need audio
        imageFormatGroup: ImageFormatGroup.yuv420, // Efficient for processing
      );

      await _controller!.initialize();
      
      // Initialize zoom capabilities
      await _initializeZoomCapabilities();
      
      Log.info('📱 Mobile camera initialized successfully',
          name: 'MobileCameraProvider', category: LogCategory.video);
    } catch (e) {
      throw CameraProviderException('Failed to initialize mobile camera', e);
    }
  }

  @override
  Widget buildPreview() {
    if (!isInitialized) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }
    return CameraPreview(_controller!);
  }

  @override
  Future<void> startRecording({Function(Uint8List)? onFrame}) async {
    if (!isInitialized || _isRecording) {
      throw CameraProviderException(
          'Cannot start recording: camera not ready or already recording');
    }

    try {
      _isRecording = true;
      _realtimeFrames.clear();
      _frameCallback = onFrame;
      _recordingStartTime = DateTime.now();

      // Start video recording
      await _controller!.startVideoRecording();

      // Start real-time frame streaming (mobile platforms support this)
      await _controller!.startImageStream((image) {
        if (!_isStreaming || !_isRecording) return;

        try {
          final frameData = _convertCameraImageToBytes(image);
          _realtimeFrames.add(frameData);
          _frameCallback?.call(frameData);
        } catch (e) {
          Log.error('Frame capture error: $e',
              name: 'MobileCameraProvider', category: LogCategory.video);
        }
      });
      _isStreaming = true;

      // Auto-stop after max duration
      Future.delayed(maxVineDuration, () {
        if (_isRecording) {
          stopRecording();
        }
      });

      Log.info('Started mobile camera recording with real-time streaming',
          name: 'MobileCameraProvider', category: LogCategory.video);
    } catch (e) {
      _isRecording = false;
      throw CameraProviderException('Failed to start recording', e);
    }
  }

  @override
  Future<CameraRecordingResult> stopRecording() async {
    if (!_isRecording) {
      throw CameraProviderException('Not currently recording');
    }

    try {
      final duration = _recordingStartTime != null
          ? DateTime.now().difference(_recordingStartTime!)
          : Duration.zero;

      // Stop streaming
      _isStreaming = false;
      await _controller!.stopImageStream();

      // Stop video recording
      final videoFile = await _controller!.stopVideoRecording();

      Log.info(
          'Mobile camera recording stopped: ${_realtimeFrames.length} real-time frames',
          name: 'MobileCameraProvider',
          category: LogCategory.video);

      return CameraRecordingResult(
        videoPath: videoFile.path,
        liveFrames: List.from(_realtimeFrames),
        width: 640, // TODO: Get actual resolution from controller
        height: 480,
        duration: duration,
      );
    } catch (e) {
      throw CameraProviderException('Failed to stop recording', e);
    } finally {
      _isRecording = false;
      _recordingStartTime = null;
      _frameCallback = null;
    }
  }

  /// Set zoom level for the camera
  @override
  Future<bool> setZoomLevel(double level) async {
    if (!isInitialized || _controller == null) {
      return false;
    }

    if (level <= 0) {
      return false;
    }

    try {
      // Clamp zoom level to device capabilities
      final clampedLevel = level.clamp(_minZoomLevel, _maxZoomLevel);
      
      await _controller!.setZoomLevel(clampedLevel);
      _currentZoomLevel = clampedLevel;
      
      Log.debug('Set zoom level to ${clampedLevel}x',
          name: 'MobileCameraProvider', category: LogCategory.video);
      
      return true;
    } catch (e) {
      Log.error('Failed to set zoom level: $e',
          name: 'MobileCameraProvider', category: LogCategory.video);
      return false;
    }
  }

  /// Convert pinch gesture scale to zoom level
  @override
  double convertScaleToZoom(double scale) {
    // Simple 1:1 mapping - could be made more sophisticated
    return scale.clamp(_minZoomLevel, _maxZoomLevel);
  }

  @override
  Future<void> switchCamera() async {
    if (!isInitialized || _isRecording) return;

    try {
      final cameras = await availableCameras();
      if (cameras.length < 2) return;

      final currentCamera = _controller!.description;
      final newCamera = cameras.firstWhere(
        (camera) => camera != currentCamera,
        orElse: () => cameras.first,
      );

      _controller?.dispose();
      _controller = null;

      _controller = CameraController(
        newCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _controller!.initialize();
      
      // Reset zoom to default and reinitialize capabilities
      _currentZoomLevel = 1.0;
      await _initializeZoomCapabilities();
      
      Log.debug('Switched to ${newCamera.lensDirection} camera',
          name: 'MobileCameraProvider', category: LogCategory.video);
    } catch (e) {
      Log.error('Failed to switch camera: $e',
          name: 'MobileCameraProvider', category: LogCategory.video);
    }
  }

  @override
  Future<void> dispose() async {
    if (_isRecording) {
      try {
        await stopRecording();
      } catch (e) {
        Log.error('Error stopping recording during disposal: $e',
            name: 'MobileCameraProvider', category: LogCategory.video);
      }
    }

    _controller?.dispose();
    _controller = null;
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
      
      Log.info('Mobile camera zoom capabilities: min=${_minZoomLevel}x, max=${_maxZoomLevel}x, supported=$_isZoomSupported',
          name: 'MobileCameraProvider', category: LogCategory.video);
    } catch (e) {
      Log.warning('Failed to initialize zoom capabilities: $e',
          name: 'MobileCameraProvider', category: LogCategory.video);
      // Fallback to no zoom support
      _maxZoomLevel = 1.0;
      _minZoomLevel = 1.0;
      _currentZoomLevel = 1.0;
      _isZoomSupported = false;
    }
  }

  /// Convert CameraImage to RGB bytes
  Uint8List _convertCameraImageToBytes(CameraImage image) {
    // Handle different image formats
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        return _convertYUV420ToRGB(image);
      case ImageFormatGroup.bgra8888:
        return _convertBGRA8888ToRGB(image);
      default:
        // Fallback: create placeholder frame
        return _createPlaceholderFrame(image.width, image.height);
    }
  }

  /// Convert YUV420 to RGB (most common format)
  Uint8List _convertYUV420ToRGB(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final rgbData = Uint8List(width * height * 3);

    // Simplified YUV to RGB conversion
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final yIndex = y * yPlane.bytesPerRow + x;
        final uvIndex = (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2);

        if (yIndex < yPlane.bytes.length && uvIndex < uPlane.bytes.length) {
          final yValue = yPlane.bytes[yIndex];
          final uValue = uPlane.bytes[uvIndex];
          final vValue = vPlane.bytes[uvIndex];

          // YUV to RGB conversion
          final r = (yValue + 1.402 * (vValue - 128)).clamp(0, 255).toInt();
          final g = (yValue - 0.344 * (uValue - 128) - 0.714 * (vValue - 128))
              .clamp(0, 255)
              .toInt();
          final b = (yValue + 1.772 * (uValue - 128)).clamp(0, 255).toInt();

          final rgbIndex = (y * width + x) * 3;
          rgbData[rgbIndex] = r;
          rgbData[rgbIndex + 1] = g;
          rgbData[rgbIndex + 2] = b;
        }
      }
    }

    return rgbData;
  }

  /// Convert BGRA8888 to RGB
  Uint8List _convertBGRA8888ToRGB(CameraImage image) {
    final bytes = image.planes[0].bytes;
    final rgbData = Uint8List((bytes.length ~/ 4) * 3);

    for (var i = 0; i < bytes.length; i += 4) {
      final b = bytes[i];
      final g = bytes[i + 1];
      final r = bytes[i + 2];
      // Skip alpha channel

      final rgbIndex = (i ~/ 4) * 3;
      rgbData[rgbIndex] = r;
      rgbData[rgbIndex + 1] = g;
      rgbData[rgbIndex + 2] = b;
    }

    return rgbData;
  }

  /// Create placeholder frame for unsupported formats
  Uint8List _createPlaceholderFrame(int width, int height) {
    final rgbData = Uint8List(width * height * 3);
    // Fill with gray color
    for (var i = 0; i < rgbData.length; i += 3) {
      rgbData[i] = 128; // R
      rgbData[i + 1] = 128; // G
      rgbData[i + 2] = 128; // B
    }
    return rgbData;
  }
}
