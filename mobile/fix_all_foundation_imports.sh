#!/bin/bash

# Fix all missing flutter/foundation.dart imports
echo "🔧 Fixing missing Flutter foundation imports..."

# Services that need foundation imports
services=(
  "lib/services/connection_status_service.dart"
  "lib/services/nostr_service.dart"
  "lib/services/profile_cache_service.dart"
  "lib/services/secure_key_storage_service.dart"
  "lib/services/stream_upload_service.dart"
  "lib/services/subscription_manager.dart"
  "lib/services/vine_recording_controller.dart"
)

for file in "${services[@]}"; do
  if [ -f "$file" ]; then
    echo "Fixing $file..."
    # Check if flutter/foundation.dart import already exists
    if ! grep -q "import 'package:flutter/foundation.dart';" "$file"; then
      # Add import after the first import statement
      sed -i '' "/^import /i\\
import 'package:flutter/foundation.dart';
" "$file"
    fi
  fi
done

echo "✅ Foundation imports fixed!"