#!/bin/bash

# ABOUTME: Script to systematically remove ChangeNotifier from all services
# ABOUTME: Part of zen:refactor clean migration to pure Riverpod

set -e

echo "🚀 Starting ChangeNotifier removal - zen:refactor clean migration"

# Define the services to refactor (already have Riverpod providers)
services=(
    "services/video_event_service.dart"
    "services/social_service.dart" 
    "services/user_profile_service.dart"
    "services/nostr_service.dart"
    "services/subscription_manager.dart"
    "services/hashtag_service.dart"
    "services/video_event_publisher.dart"
    "services/api_service.dart"
    "services/nip05_service.dart"
    "services/seen_videos_service.dart"
    "services/content_blocklist_service.dart"
    "services/upload_manager.dart"
    "services/direct_upload_service.dart"
    "services/stream_upload_service.dart"
    "services/nip98_auth_service.dart"
    "services/curation_service.dart"
    "services/explore_video_manager.dart"
    "services/content_reporting_service.dart"
    "services/curated_list_service.dart"
    "services/video_sharing_service.dart"
    "services/content_deletion_service.dart"
)

cd "/Users/rabble/code/andotherstuff/openvine/mobile/lib"

for service in "${services[@]}"; do
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
echo "🎉 ChangeNotifier removal complete!"
echo "📊 Next steps:"
echo "1. Run flutter analyze to check for issues"
echo "2. Update widgets to use Riverpod ref.watch/read"
echo "3. Remove Provider package imports"