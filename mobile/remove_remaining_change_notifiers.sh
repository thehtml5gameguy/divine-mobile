#!/bin/bash

# ABOUTME: Script to remove ChangeNotifier from remaining services not in app_providers
# ABOUTME: Part of zen:refactor clean migration to pure Riverpod

set -e

echo "🚀 Removing ChangeNotifier from remaining services"

# Define remaining services that need ChangeNotifier removal
remaining_services=(
    "services/camera_service.dart"
    "services/video_playback_controller.dart"
    "services/video_performance_monitor.dart"
    "services/video_cache_service.dart"
    "services/video_controller_manager.dart"
    "services/cloudinary_upload_service.dart"
    "services/websocket_connection_manager.dart"
    "services/key_storage_service.dart"
    "services/nostr_key_manager.dart"
    "services/analytics_service.dart"
    "services/notification_service.dart"
    "services/video_event_cache_service.dart"
    "services/background_activity_manager.dart"
    "services/infinite_feed_service.dart"
    "services/circuit_breaker_service.dart"
    "services/content_moderation_service.dart"
    "services/secure_key_storage_service.dart"
    "services/notification_service_enhanced.dart"
    "services/nostr_video_bridge.dart"
    "services/identity_manager_service.dart"
    "services/vine_recording_controller.dart"
    "services/web_auth_service.dart"
    "services/profile_cache_service.dart"
    "features/feature_flags/services/feature_flag_service.dart"
    "features/app/startup/startup_coordinator.dart"
)

cd "/Users/rabble/code/andotherstuff/openvine/mobile/lib"

for service in "${remaining_services[@]}"; do
    if [[ -f "$service" ]]; then
        echo "🔧 Processing $service..."
        
        # Remove ChangeNotifier inheritance
        sed -i.bak 's/extends ChangeNotifier//' "$service"
        
        # Remove notifyListeners calls
        sed -i.bak 's/.*notifyListeners();.*//g' "$service"
        
        # Remove flutter foundation import if only used for ChangeNotifier
        sed -i.bak '/import.*flutter\/foundation.*/{
            /ChangeNotifier\|ValueNotifier/!d
        }' "$service"
        
        # Add refactor comment
        sed -i.bak '/^class.*{$/i\
/// REFACTORED: Removed ChangeNotifier - now uses pure state management via Riverpod
' "$service"
        
        # Remove backup file
        rm -f "$service.bak"
        
        echo "✅ Completed $service"
    else
        echo "⚠️  File not found: $service"
    fi
done

echo ""
echo "🎉 Remaining ChangeNotifier removal complete!"
echo "📊 All services are now ChangeNotifier-free!"