// ABOUTME: Complete camera widget with zoom functionality for easy integration
// ABOUTME: Combines camera preview with zoom controls in a ready-to-use component

import 'package:flutter/material.dart';
import 'package:openvine/services/camera_service.dart';
import 'package:openvine/widgets/camera_zoom_widget.dart';

/// Complete camera widget with built-in zoom functionality
class CameraWithZoom extends StatefulWidget {
  const CameraWithZoom({
    super.key,
    this.showZoomIndicator = true,
    this.showZoomSlider = true,
    this.onZoomChanged,
    this.onCameraReady,
  });

  /// Whether to show zoom level indicator
  final bool showZoomIndicator;
  
  /// Whether to show zoom slider controls
  final bool showZoomSlider;
  
  /// Callback when zoom level changes
  final ValueChanged<double>? onZoomChanged;
  
  /// Callback when camera is initialized and ready
  final VoidCallback? onCameraReady;

  @override
  State<CameraWithZoom> createState() => _CameraWithZoomState();
}

class _CameraWithZoomState extends State<CameraWithZoom> {
  late final CameraService _cameraService;
  bool _isInitialized = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _cameraService = CameraService();
    _initializeCamera();
  }

  @override
  void dispose() {
    _cameraService.dispose();
    
  }

  Future<void> _initializeCamera() async {
    try {
      await _cameraService.initialize();
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _errorMessage = null;
        });
        widget.onCameraReady?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitialized = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  void _onZoomChanged(double level) {
    widget.onZoomChanged?.call(level);
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.camera_alt,
              size: 64,
              color: Colors.grey,
            ),
            const SizedBox(height: 16),
            Text(
              'Camera Error',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _initializeCamera,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (!_isInitialized) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Initializing camera...'),
          ],
        ),
      );
    }

    return CameraZoomWidget(
      cameraService: _cameraService,
      showZoomIndicator: widget.showZoomIndicator,
      showZoomSlider: widget.showZoomSlider,
      onZoomChanged: _onZoomChanged,
      child: _cameraService.cameraPreview,
    );
  }
  
  @override
  void dispose() {
    super.dispose();
  }
}

/// Simple camera screen demonstrating zoom functionality
class ZoomDemoScreen extends StatelessWidget {
  const ZoomDemoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera Zoom Demo'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: const CameraWithZoom(
        showZoomIndicator: true,
        showZoomSlider: true,
      ),
    );
  }
}