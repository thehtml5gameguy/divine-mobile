#!/bin/bash

# Fix hasListeners calls in VineRecordingController
echo "🔧 Removing hasListeners references in VineRecordingController..."

# Comment out lines that reference hasListeners
sed -i '' '
/if (!_disposed && hasListeners)/s/^/      \/\/ ChangeNotifier removed - no listeners to notify\n      \/\/ /
/if (WidgetsBinding.instance.hasScheduledFrame || !hasListeners)/s/^/    \/\/ ChangeNotifier removed - no listeners to check\n    \/\/ /
/hasListeners &&/s/^/          \/\/ ChangeNotifier removed\n          \/\/ /
' lib/services/vine_recording_controller.dart

echo "✅ hasListeners references commented out!"