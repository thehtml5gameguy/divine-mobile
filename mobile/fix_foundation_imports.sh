#!/bin/bash

# ABOUTME: Fix missing Flutter foundation imports after ChangeNotifier removal
# ABOUTME: Adds foundation import where kDebugMode or debugPrint are used

set -e

echo "🚀 Adding missing Flutter foundation imports"

# Files that need flutter/foundation import
files_needing_foundation=(
    "lib/features/app/startup/startup_coordinator.dart"
    "lib/features/feature_flags/services/feature_flag_service.dart"
    "lib/services/analytics_service.dart"
    "lib/services/api_service.dart"
)

for file in "${files_needing_foundation[@]}"; do
    if [[ -f "$file" ]]; then
        echo "🔧 Adding foundation import to $file..."
        
        # Add flutter/foundation import if not already present
        if ! grep -q "import 'package:flutter/foundation.dart'" "$file"; then
            # Insert at top after existing imports
            sed -i.bak '1a\
import '\''package:flutter/foundation.dart'\'';' "$file"
        fi
        
        # Remove invalid @override and super.dispose calls
        sed -i.bak 's/@override.*dispose//g' "$file"
        sed -i.bak 's/super\.dispose();//g' "$file"
        
        rm -f "$file.bak"
        echo "✅ Fixed $file"
    else
        echo "⚠️  File not found: $file"
    fi
done

echo "🎉 Foundation imports fixed!"