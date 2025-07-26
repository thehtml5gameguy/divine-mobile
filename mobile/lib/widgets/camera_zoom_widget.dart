// ABOUTME: Camera zoom widget for pinch-to-zoom and zoom controls UI
// ABOUTME: Provides gesture handling and visual feedback for zoom operations

import 'package:flutter/material.dart';
import 'package:openvine/services/camera_service.dart';
import 'package:openvine/utils/unified_logger.dart';

/// Widget that provides zoom controls and pinch-to-zoom functionality
class CameraZoomWidget extends StatefulWidget {
  const CameraZoomWidget({
    super.key,
    required this.cameraService,
    required this.child,
    this.showZoomIndicator = true,
    this.showZoomSlider = false,
    this.onZoomChanged,
  });

  /// Camera service for zoom operations
  final CameraService cameraService;
  
  /// Child widget (typically camera preview)
  final Widget child;
  
  /// Whether to show zoom level indicator
  final bool showZoomIndicator;
  
  /// Whether to show zoom slider
  final bool showZoomSlider;
  
  /// Callback when zoom level changes
  final ValueChanged<double>? onZoomChanged;

  @override
  State<CameraZoomWidget> createState() => _CameraZoomWidgetState();
}

class _CameraZoomWidgetState extends State<CameraZoomWidget> {
  double _baseZoomLevel = 1.0;
  double _currentScale = 1.0;
  bool _showZoomControls = false;

  @override
  void initState() {
    super.initState();
    _baseZoomLevel = widget.cameraService.currentZoomLevel;
    
    // Listen to zoom changes from camera service
      // REFACTORED: Service no longer extends ChangeNotifier - use Riverpod ref.watch instead
  }

  @override
  void dispose() {
      // REFACTORED: Service no longer needs manual listener cleanup
    
  }

  void _onCameraServiceChanged() {
    if (mounted) {
      setState(() {
        _baseZoomLevel = widget.cameraService.currentZoomLevel;
      });
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _baseZoomLevel = widget.cameraService.currentZoomLevel;
    _currentScale = 1.0;
    
    if (widget.showZoomSlider) {
      setState(() {
        _showZoomControls = true;
      });
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (!widget.cameraService.isZoomSupported) return;
    
    _currentScale = details.scale;
    final newZoomLevel = (_baseZoomLevel * _currentScale).clamp(
      widget.cameraService.minZoomLevel,
      widget.cameraService.maxZoomLevel,
    );

    // Debounce zoom updates to prevent excessive calls
    _setZoomLevelDebounced(newZoomLevel);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // Finalize zoom level
    final finalZoomLevel = (_baseZoomLevel * _currentScale).clamp(
      widget.cameraService.minZoomLevel,
      widget.cameraService.maxZoomLevel,
    );
    
    _setZoomLevel(finalZoomLevel);
    
    // Hide zoom controls after a delay
    if (widget.showZoomSlider) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _showZoomControls = false;
          });
        }
      });
    }
  }

  void _onSliderChanged(double value) {
    _setZoomLevel(value);
  }

  void _setZoomLevel(double level) {
    widget.cameraService.setZoomLevel(level).then((_) {
      widget.onZoomChanged?.call(level);
    }).catchError((error) {
      Log.error('Failed to set zoom level: $error',
          name: 'CameraZoomWidget', category: LogCategory.ui);
    });
  }

  // Debounced zoom level setter to prevent excessive updates
  void _setZoomLevelDebounced(double level) {
    // Simple debouncing - could be improved with a proper debouncer
    Future.microtask(() => _setZoomLevel(level));
  }

  void _onTapToShowControls() {
    if (widget.showZoomSlider) {
      setState(() {
        _showZoomControls = !_showZoomControls;
      });
      
      if (_showZoomControls) {
        // Auto-hide after 5 seconds
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted && _showZoomControls) {
            setState(() {
              _showZoomControls = false;
            });
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Main gesture detector for pinch-to-zoom
        GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          onTap: _onTapToShowControls,
          child: widget.child,
        ),
        
        // Zoom level indicator
        if (widget.showZoomIndicator)
          Positioned(
            top: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${widget.cameraService.currentZoomLevel.toStringAsFixed(1)}x',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        
        // Zoom slider controls
        if (widget.showZoomSlider && _showZoomControls && widget.cameraService.isZoomSupported)
          Positioned(
            bottom: 100,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Zoom',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        '${widget.cameraService.minZoomLevel.toStringAsFixed(1)}x',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: widget.cameraService.currentZoomLevel,
                          min: widget.cameraService.minZoomLevel,
                          max: widget.cameraService.maxZoomLevel,
                          divisions: ((widget.cameraService.maxZoomLevel - widget.cameraService.minZoomLevel) * 10).round(),
                          onChanged: _onSliderChanged,
                          activeColor: Colors.white,
                          inactiveColor: Colors.white30,
                        ),
                      ),
                      Text(
                        '${widget.cameraService.maxZoomLevel.toStringAsFixed(1)}x',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
  
  @override
  void dispose() {
    super.dispose();
  }
}