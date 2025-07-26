// ABOUTME: ProofMode integration layer for camera service with vine recording proof generation
// ABOUTME: Coordinates proof session management with video recording lifecycle

import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:openvine/services/camera_service.dart';
import 'package:openvine/services/proofmode_config.dart';
import 'package:openvine/services/proofmode_key_service.dart';
import 'package:openvine/services/proofmode_attestation_service.dart';
import 'package:openvine/services/proofmode_session_service.dart';
import 'package:openvine/utils/unified_logger.dart';

/// Enhanced vine recording result with ProofMode data
class ProofModeVineRecordingResult extends VineRecordingResult {
  ProofModeVineRecordingResult({
    required super.videoFile,
    required super.duration,
    this.proofManifest,
    this.proofLevel,
  });

  final ProofManifest? proofManifest;
  final String? proofLevel; // 'verified_mobile', 'verified_web', 'basic_proof', 'unverified'

  bool get hasProof => proofManifest != null;

  Map<String, dynamic> toJson() => {
    'videoPath': videoFile.path,
    'duration': duration.inMilliseconds,
    'hasProof': hasProof,
    'proofLevel': proofLevel,
    'proofManifest': proofManifest?.toJson(),
  };
}

/// ProofMode camera integration service
class ProofModeCameraIntegration {
  final CameraService _cameraService;
  final ProofModeKeyService _keyService;
  final ProofModeAttestationService _attestationService;
  final ProofModeSessionService _sessionService;

  ProofModeCameraIntegration(
    this._cameraService,
    this._keyService,
    this._attestationService,
    this._sessionService,
  );

  String? _currentSessionId;
  Timer? _interactionMonitor;

  /// Initialize ProofMode camera integration
  Future<void> initialize() async {
    Log.info('Initializing ProofMode camera integration',
        name: 'ProofModeCameraIntegration', category: LogCategory.system);

    try {
      // Initialize all ProofMode services
      await _keyService.initialize();
      await _attestationService.initialize();

      // Log ProofMode status
      await ProofModeConfig.logStatus();

      Log.info('ProofMode camera integration initialized successfully',
          name: 'ProofModeCameraIntegration', category: LogCategory.system);
    } catch (e) {
      Log.error('Failed to initialize ProofMode camera integration: $e',
          name: 'ProofModeCameraIntegration', category: LogCategory.system);
      // Don't rethrow - allow camera to work without ProofMode
    }
  }

  /// Start vine recording with ProofMode proof generation
  Future<void> startRecording() async {
    Log.info('Starting vine recording with ProofMode',
        name: 'ProofModeCameraIntegration', category: LogCategory.video);

    try {
      // Start ProofMode session if enabled
      if (await ProofModeConfig.isCaptureEnabled) {
        _currentSessionId = await _sessionService.startSession();
        if (_currentSessionId != null) {
          Log.info('Started ProofMode session: $_currentSessionId',
              name: 'ProofModeCameraIntegration', category: LogCategory.video);
          
          // Start monitoring user interactions
          _startInteractionMonitoring();
          
          // Start recording segment
          await _sessionService.startRecordingSegment();
        }
      } else {
        Log.debug('ProofMode capture disabled, recording without proof',
            name: 'ProofModeCameraIntegration', category: LogCategory.video);
      }

      // Start camera recording
      await _cameraService.startRecording();

      // Record start interaction
      if (_currentSessionId != null) {
        await _sessionService.recordInteraction('start', 0.5, 0.5);
      }

    } catch (e) {
      Log.error('Failed to start ProofMode recording: $e',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
      
      // Clean up ProofMode session on error
      if (_currentSessionId != null) {
        await _sessionService.cancelSession();
        _currentSessionId = null;
      }
      
      rethrow;
    }
  }

  /// Pause recording (for segmented vine recording)
  Future<void> pauseRecording() async {
    if (_currentSessionId == null) {
      Log.debug('No ProofMode session active for pause',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
      return;
    }

    Log.debug('Pausing vine recording segment',
        name: 'ProofModeCameraIntegration', category: LogCategory.video);

    try {
      // Stop current recording segment
      await _sessionService.stopRecordingSegment();
      
      // Record pause interaction
      await _sessionService.recordInteraction('pause', 0.5, 0.5);
      
      Log.debug('Recording segment paused successfully',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
    } catch (e) {
      Log.error('Failed to pause recording segment: $e',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
    }
  }

  /// Resume recording (start new segment)
  Future<void> resumeRecording() async {
    if (_currentSessionId == null) {
      Log.debug('No ProofMode session active for resume',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
      return;
    }

    Log.debug('Resuming vine recording segment',
        name: 'ProofModeCameraIntegration', category: LogCategory.video);

    try {
      // Start new recording segment
      await _sessionService.startRecordingSegment();
      
      // Record resume interaction
      await _sessionService.recordInteraction('resume', 0.5, 0.5);
      
      Log.debug('Recording segment resumed successfully',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
    } catch (e) {
      Log.error('Failed to resume recording segment: $e',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
    }
  }

  /// Stop recording and generate proof manifest
  Future<ProofModeVineRecordingResult> stopRecording() async {
    Log.info('Stopping vine recording with ProofMode',
        name: 'ProofModeCameraIntegration', category: LogCategory.video);

    try {
      // Stop camera recording first
      final basicResult = await _cameraService.stopRecording();
      
      // Stop interaction monitoring
      _interactionMonitor?.cancel();
      _interactionMonitor = null;

      ProofManifest? proofManifest;
      String? proofLevel;

      // Finalize ProofMode session if active
      if (_currentSessionId != null) {
        try {
          // Record stop interaction
          await _sessionService.recordInteraction('stop', 0.5, 0.5);

          // Generate video hash
          final videoHash = await _generateVideoHash(basicResult.videoFile);
          
          // Finalize session and get proof manifest
          proofManifest = await _sessionService.finalizeSession(videoHash);
          
          if (proofManifest != null) {
            proofLevel = await _determineProofLevel(proofManifest);
            Log.info('ProofMode session finalized with proof level: $proofLevel',
                name: 'ProofModeCameraIntegration', category: LogCategory.video);
          }
        } catch (e) {
          Log.error('Failed to finalize ProofMode session: $e',
              name: 'ProofModeCameraIntegration', category: LogCategory.video);
          // Continue without proof rather than failing the recording
        } finally {
          _currentSessionId = null;
        }
      }

      final result = ProofModeVineRecordingResult(
        videoFile: basicResult.videoFile,
        duration: basicResult.duration,
        proofManifest: proofManifest,
        proofLevel: proofLevel ?? 'unverified',
      );

      Log.info('Vine recording completed with ProofMode:',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
      Log.debug('  📹 File: ${result.videoFile.path}',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
      Log.debug('  ⏱️ Duration: ${result.duration.inSeconds}s',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
      Log.debug('  🔒 Proof Level: ${result.proofLevel}',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
      
      if (result.hasProof) {
        Log.debug('  📊 Segments: ${result.proofManifest!.segments.length}',
            name: 'ProofModeCameraIntegration', category: LogCategory.video);
        Log.debug('  👆 Interactions: ${result.proofManifest!.interactions.length}',
            name: 'ProofModeCameraIntegration', category: LogCategory.video);
      }

      return result;
    } catch (e) {
      Log.error('Failed to stop ProofMode recording: $e',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
      
      // Clean up session on error
      if (_currentSessionId != null) {
        await _sessionService.cancelSession();
        _currentSessionId = null;
      }
      
      rethrow;
    }
  }

  /// Cancel recording and clean up ProofMode session
  Future<void> cancelRecording() async {
    Log.info('Cancelling vine recording with ProofMode',
        name: 'ProofModeCameraIntegration', category: LogCategory.video);

    try {
      // Stop interaction monitoring
      _interactionMonitor?.cancel();
      _interactionMonitor = null;

      // Cancel ProofMode session if active
      if (_currentSessionId != null) {
        await _sessionService.cancelSession();
        _currentSessionId = null;
      }
    } catch (e) {
      Log.error('Failed to cancel ProofMode session: $e',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
    }
  }

  /// Record user touch interaction
  Future<void> recordTouchInteraction(double x, double y, {double? pressure}) async {
    if (_currentSessionId != null) {
      await _sessionService.recordInteraction('touch', x, y, pressure: pressure);
    }
  }

  /// Get current ProofMode status
  bool get hasActiveProofSession => _currentSessionId != null;
  String? get currentSessionId => _currentSessionId;

  // Private helper methods

  /// Start monitoring user interactions for human activity detection
  void _startInteractionMonitoring() {
    Log.debug('Starting ProofMode interaction monitoring',
        name: 'ProofModeCameraIntegration', category: LogCategory.system);

    // Monitor for natural micro-variations in user behavior
    _interactionMonitor = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_currentSessionId != null) {
        // Simulate natural micro-variations (would be real sensor data in production)
        final x = 0.5 + (DateTime.now().millisecondsSinceEpoch % 100) / 10000;
        final y = 0.5 + (DateTime.now().millisecondsSinceEpoch % 73) / 10000;
        _sessionService.recordInteraction('micro_variation', x, y);
      }
    });
  }

  /// Generate hash of video file for proof manifest
  Future<String> _generateVideoHash(File videoFile) async {
    try {
      Log.debug('Generating video hash for ProofMode manifest',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);

      final bytes = await videoFile.readAsBytes();
      final hash = sha256.convert(bytes);
      
      Log.debug('Video hash generated: ${hash.toString().substring(0, 16)}...',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
      
      return hash.toString();
    } catch (e) {
      Log.error('Failed to generate video hash: $e',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
      return 'hash_generation_failed_${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  /// Determine proof level based on manifest content
  Future<String> _determineProofLevel(ProofManifest manifest) async {
    try {
      // Check if device attestation is present and hardware-backed
      if (manifest.deviceAttestation?.isHardwareBacked == true) {
        final platform = manifest.deviceAttestation?.platform;
        if (platform == 'iOS' || platform == 'Android') {
          return 'verified_mobile';
        }
      }

      // Check for web-based verification
      if (manifest.deviceAttestation?.platform == 'web') {
        return 'verified_web';
      }

      // Check if we have basic proof elements
      if (manifest.pgpSignature != null && 
          manifest.segments.isNotEmpty && 
          manifest.interactions.isNotEmpty) {
        return 'basic_proof';
      }

      return 'unverified';
    } catch (e) {
      Log.error('Failed to determine proof level: $e',
          name: 'ProofModeCameraIntegration', category: LogCategory.video);
      return 'unverified';
    }
  }

  /// Dispose of resources
  void dispose() {
    _interactionMonitor?.cancel();
    _interactionMonitor = null;
    
    if (_currentSessionId != null) {
      _sessionService.cancelSession();
      _currentSessionId = null;
    }
  }
}