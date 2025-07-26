#!/bin/bash

# ABOUTME: Remove invalid method calls on services that no longer extend ChangeNotifier
# ABOUTME: Clean up addListener, removeListener, dispose calls and @override markers

set -e

echo "🚀 Cleaning invalid method calls after ChangeNotifier removal"

cd "/Users/rabble/code/andotherstuff/openvine/mobile/lib"

# Find and fix files with addListener/removeListener calls
find . -name "*.dart" -not -path "./test/*" -not -path "./integration_test/*" -exec grep -l "\.addListener\|\.removeListener" {} \; | while read -r file; do
    echo "🔧 Cleaning $file..."
    
    # Comment out addListener/removeListener calls with refactor note
    sed -i.bak 's/.*\.addListener.*/      \/\/ REFACTORED: Service no longer extends ChangeNotifier - use Riverpod ref.watch instead/g' "$file"
    sed -i.bak 's/.*\.removeListener.*/      \/\/ REFACTORED: Service no longer needs manual listener cleanup/g' "$file"
    
    rm -f "$file.bak"
    echo "✅ Cleaned $file"
done

# Find and fix invalid @override dispose methods
find . -name "*.dart" -not -path "./test/*" -not -path "./integration_test/*" -exec grep -l "@override.*dispose\|super\.dispose" {} \; | while read -r file; do
    echo "🔧 Fixing dispose in $file..."
    
    # Remove invalid @override for dispose
    sed -i.bak '/@override/,/dispose/ {
        /@override/d
        /dispose/s/@override//g
    }' "$file"
    
    # Remove super.dispose calls
    sed -i.bak 's/super\.dispose();//g' "$file"
    sed -i.bak 's/super\.dispose()//g' "$file"
    
    rm -f "$file.bak"
    echo "✅ Fixed dispose in $file"
done

echo "🎉 Cleanup complete!"