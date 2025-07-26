#!/bin/bash

# Fix missing super.dispose() calls in dispose methods
echo "🔧 Fixing missing super.dispose() calls..."

# Files that need super.dispose() added
files=(
  "lib/screens/activity_screen.dart"
  "lib/screens/comments_screen.dart"
  "lib/screens/explore_screen.dart"
  "lib/screens/explore_video_feed_screen.dart"
  "lib/screens/explore_video_screen.dart"
  "lib/screens/infinite_feed_screen.dart"
  "lib/screens/key_import_screen.dart"
  "lib/screens/macos_camera_screen.dart"
  "lib/screens/notifications_screen.dart"
  "lib/screens/profile_screen.dart"
  "lib/screens/profile_screen_scrollable.dart"
  "lib/screens/profile_setup_screen.dart"
  "lib/screens/relay_settings_screen.dart"
  "lib/screens/search_screen.dart"
  "lib/screens/video_feed_screen.dart"
  "lib/screens/video_metadata_screen.dart"
  "lib/screens/vine_preview_screen.dart"
  "lib/screens/web_auth_screen.dart"
)

for file in "${files[@]}"; do
  if [ -f "$file" ]; then
    echo "Fixing $file..."
    # Add super.dispose() after other disposals in dispose() method
    # Look for dispose() methods that don't already have super.dispose()
    if ! grep -q "super.dispose()" "$file"; then
      # Find dispose methods and add super.dispose() at the end
      sed -i '' '/void dispose() {/,/^  }$/ {
        /^  }$/ {
          s/^  }$/    super.dispose();\
  }/
        }
      }' "$file"
    fi
  fi
done

echo "✅ Fixed super.dispose() calls!"