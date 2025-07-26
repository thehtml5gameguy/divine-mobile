#!/bin/bash
# Script to fix SubscriptionManager() calls in tests

echo "Fixing SubscriptionManager() calls in test files..."

# Find all test files with SubscriptionManager() and update them
find test -name "*.dart" -type f | while read file; do
  if grep -q "SubscriptionManager()" "$file"; then
    echo "Fixing: $file"
    # Replace SubscriptionManager() with proper mock/test implementation
    sed -i '' 's/final subscriptionManager = SubscriptionManager();/final nostrService = TestNostrService();\n      final subscriptionManager = SubscriptionManager(nostrService);/g' "$file"
    sed -i '' 's/SubscriptionManager()/SubscriptionManager(TestNostrService())/g' "$file"
    
    # Add import if not present
    if ! grep -q "test_nostr_service.dart" "$file"; then
      # Add import after the last import statement
      sed -i '' '/^import/!b;:a;n;/^import/ba;i\
import '"'"'../helpers/test_nostr_service.dart'"'"';
' "$file"
    fi
  fi
done

echo "Done fixing SubscriptionManager calls"