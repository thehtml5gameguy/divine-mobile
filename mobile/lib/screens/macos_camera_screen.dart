// ABOUTME: macOS-specific camera screen using camera_macos plugin with proper Vine recording
// ABOUTME: Implements press-to-record, release-to-pause segmented recording system

import 'dart:async';
import 'dart:io';

import 'package:camera_macos/camera_macos.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:openvine/models/pending_upload.dart';
import 'package:openvine/providers/app_providers.dart';
import 'package:openvine/screens/video_metadata_screen.dart';
import 'package:openvine/services/nostr_key_manager.dart';
import 'package:openvine/services/upload_manager.dart';
import 'package:openvine/theme/vine_theme.dart';
import 'package:openvine/utils/unified_logger.dart';
import 'package:openvine/widgets/upload_progress_indicator.dart';
import 'package:path_provider/path_provider.dart';

/// Represents a single recording segment in the Vine-style recording
class RecordingSegment {
  RecordingSegment({
    required this.startTime,
    required this.endTime,
    required this.duration,
    this.filePath,
  });
  final DateTime startTime;
  final DateTime endTime;
  final Duration duration;
  final String? filePath;

  @override
  String toString() => 'Segment(${duration.inMilliseconds}ms)';
}

/// Recording state for Vine-style segmented recording
enum VineRecordingState {
  idle, // Camera preview active, not recording
  recording, // Currently recording a segment
  paused, // Between segments, camera preview active
  processing, // Assembling final video
  completed, // Recording finished
  error, // Error state
}

class MacOSCameraScreen extends ConsumerStatefulWidget {
  const MacOSCameraScreen({super.key});

  @override
  ConsumerState<MacOSCameraScreen> createState() => _MacOSCameraScreenState();
}

class _MacOSCameraScreenState extends ConsumerState<MacOSCameraScreen> {
  final GlobalKey _cameraKey = GlobalKey(debugLabel: 'macOSCameraKey');
  CameraMacOSController? _macOSController;
  late final NostrKeyManager _keyManager;
  UploadManager? _uploadManager;

  bool _isRecording = false;
  bool _isInitialized = false;
  String? _errorMessage;
  PendingUpload? _currentUpload;
  bool _isProcessing = false;

  // Recording progress
  DateTime? _recordingStartTime;
  static const Duration _maxRecordingDuration = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  @override
  void dispose() {
    
    super.dispose();
  }

  Future<void> _initializeServices() async {
    // Get services from providers
    _uploadManager = ref.read(uploadManagerProvider);
    _keyManager = ref.read(nostrKeyManagerProvider);
  }

  void _onCameraInitialized(CameraMacOSController controller) {
    setState(() {
      _macOSController = controller;
      _isInitialized = true;
      _errorMessage = null;
    });
    Log.info('📱 macOS Camera initialized successfully',
        name: 'MacosCameraScreen', category: LogCategory.ui);
  }

  // ignore: unused_element
  void _onCameraError(String error) {
    setState(() {
      _errorMessage = 'Camera error: $error';
      _isInitialized = false;
    });
    Log.error('macOS Camera error: $error',
        name: 'MacosCameraScreen', category: LogCategory.ui);
  }

  Future<void> _startRecording() async {
    if (!_isInitialized || _macOSController == null || _isRecording) {
      return;
    }

    try {
      // Get temporary directory for video file
      final tempDir = await getTemporaryDirectory();
      final videoPath =
          '${tempDir.path}/vine_${DateTime.now().millisecondsSinceEpoch}.mov';

      setState(() {
        _isRecording = true;
        _recordingStartTime = DateTime.now();
      });

      // Start recording with macOS camera
      await _macOSController!.recordVideo(
        url: videoPath,
        maxVideoDuration: _maxRecordingDuration.inSeconds.toDouble(),
        onVideoRecordingFinished: (file, exception) {
          _onVideoRecordingFinished(file, exception);
        },
      );

      Log.info(
          'Started macOS vine recording (${_maxRecordingDuration.inSeconds}s max)',
          name: 'MacosCameraScreen',
          category: LogCategory.ui);
    } catch (e) {
      setState(() {
        _isRecording = false;
        _recordingStartTime = null;
        _errorMessage = 'Failed to start recording: $e';
      });
      Log.error('Failed to start macOS recording: $e',
          name: 'MacosCameraScreen', category: LogCategory.ui);
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording || _macOSController == null) {
      return;
    }

    try {
      // For now, just mark as not recording - the callback will handle the file
      setState(() {
        _isRecording = false;
        _recordingStartTime = null;
      });
      Log.info('📱 Stopped macOS recording - waiting for callback',
          name: 'MacosCameraScreen', category: LogCategory.ui);
    } catch (e) {
      Log.error('Error stopping recording: $e',
          name: 'MacosCameraScreen', category: LogCategory.ui);
    }
  }

  void _onVideoRecordingFinished(
      CameraMacOSFile? file, CameraMacOSException? exception) {
    setState(() {
      _isRecording = false;
      _recordingStartTime = null;
    });

    if (exception != null) {
      setState(() {
        _errorMessage = 'Recording failed: $exception';
      });
      Log.error('Recording failed: $exception',
          name: 'MacosCameraScreen', category: LogCategory.ui);
      return;
    }

    if (file != null) {
      _handleVideoRecorded(File(file.url!));
    }
  }

  Future<void> _handleVideoRecorded(File videoFile) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      // Navigate to metadata screen
      final result = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          builder: (context) => VideoMetadataScreen(
            videoFile: videoFile,
            duration: _maxRecordingDuration,
          ),
        ),
      );

      if (result != null && mounted) {
        // Get current user's pubkey
        final pubkey = _keyManager.publicKey ?? '';

        // Start upload through upload manager
        final upload = await _uploadManager!.startUpload(
          videoFile: videoFile,
          nostrPubkey: pubkey,
          title: result['caption'] ?? '',
          description: result['caption'] ?? '',
          hashtags: result['hashtags'] ?? [],
        );

        setState(() {
          _currentUpload = upload;
        });
      }
    } catch (e) {
      Log.error('Error processing video: $e',
          name: 'MacosCameraScreen', category: LogCategory.ui);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to process video: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  double get _recordingProgress {
    if (!_isRecording || _recordingStartTime == null) return 0;
    final elapsed = DateTime.now().difference(_recordingStartTime!);
    return (elapsed.inMilliseconds / _maxRecordingDuration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('Record Vine'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: Stack(
          children: [
            // Camera preview
            if (_errorMessage == null)
              CameraMacOSView(
                key: _cameraKey,
                fit: BoxFit.cover,
                cameraMode: CameraMacOSMode.video,
                onCameraInizialized: _onCameraInitialized,
              )
            else
              _buildErrorView(),

            // Recording controls
            if (_isInitialized && _errorMessage == null)
              _buildRecordingControls(),

            // Upload progress indicator
            if (_currentUpload != null)
              Positioned(
                top: 50,
                left: 0,
                right: 0,
                child: UploadProgressIndicator(
                  upload: _currentUpload!,
                ),
              ),
          ],
        ),
      );

  Widget _buildErrorView() => Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.white,
                size: 64,
              ),
              const SizedBox(height: 16),
              Text(
                'Camera Error',
                style: Theme.of(context)
                    .textTheme
                    .displayLarge
                    ?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage ?? 'Unknown error',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[700],
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Go Back'),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _errorMessage = null;
                      });
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: VineTheme.vineGreen,
                    ),
                    child: const Text('Try Again'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _buildRecordingControls() => Positioned(
        bottom: 50,
        left: 0,
        right: 0,
        child: Column(
          children: [
            // Recording progress
            if (_isRecording)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: _recordingProgress,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          VineTheme.vineGreen),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(_recordingProgress * _maxRecordingDuration.inSeconds).toInt()}s / ${_maxRecordingDuration.inSeconds}s',
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 20),

            // Recording button
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Record/Stop button
                GestureDetector(
                  onTap: _isRecording ? _stopRecording : _startRecording,
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isRecording ? Colors.red : VineTheme.vineGreen,
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                    child: Icon(
                      _isRecording ? Icons.stop : Icons.videocam,
                      color: Colors.white,
                      size: 40,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Instructions
            Text(
              _isRecording
                  ? 'Recording... Tap to stop or wait for auto-stop'
                  : 'Tap to start recording a ${_maxRecordingDuration.inSeconds}s vine',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
}
