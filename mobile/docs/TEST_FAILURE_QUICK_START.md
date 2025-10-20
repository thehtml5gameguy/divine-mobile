# Test Failure Quick Start Guide

**Current Status:** 77.4% pass rate (1,735 passing, 498 failing out of 2,243 tests)

## Quick Wins (Start Here - 4-6 hours total, fixes ~50 tests)

### 1. Add Missing Mock Stubs (30 minutes each file)

**Files:**
- `/Users/rabble/code/andotherstuff/openvine/mobile/test/services/curation_service_analytics_test.dart`
- `/Users/rabble/code/andotherstuff/openvine/mobile/test/services/curation_service_editors_picks_test.dart`
- `/Users/rabble/code/andotherstuff/openvine/mobile/test/services/curation_service_test.dart`

**What to do:**
```dart
// Add these to test setup:
when(mockNostrService.broadcastEvent(any)).thenAnswer((_) async => 'event_id');
when(mockNostrService.subscribeToEvents(any)).thenAnswer((_) => Stream.value([]));
when(mockAnalyticsService.getTrendingVideos()).thenAnswer((_) async => []);
```

**Run test to see specific missing stubs:**
```bash
cd /Users/rabble/code/andotherstuff/openvine/mobile
flutter test test/services/curation_service_analytics_test.dart
```

### 2. Fix Provider Lifecycle (15 minutes)

**File:** `/Users/rabble/code/andotherstuff/openvine/mobile/lib/providers/comments_provider.dart`

**What to do:**
```dart
// In CommentsNotifier.postComment(), add guard:
Future<void> postComment(String content) async {
  // ... existing code ...

  await socialService.postComment(...);

  if (!ref.mounted) return;  // <-- ADD THIS LINE

  state = await AsyncValue.guard(() async {
    // ... existing code ...
  });
}
```

### 3. Fix Invalid Test Data (30 minutes)

**File:** `/Users/rabble/code/andotherstuff/openvine/mobile/test/services/curation_publish_test.dart`

**What to do:**
```dart
// Replace lines like:
final pubkey = "test_pubkey";  // ❌ WRONG

// With:
final keyPair = Keychain.generate();
final pubkey = keyPair.public.toHex();  // ✅ CORRECT
```

---

## Top Priority Files (Fix These First)

| File | Failures | Estimated Fix Time | Impact |
|------|----------|-------------------|---------|
| `test/services/social_service_test.dart` | 24 | 2-3 hours | High |
| `test/services/curation_publish_test.dart` | 12 | 1-2 hours | High |
| `test/integration/analytics_api_endpoints_test.dart` | 10 | 1 hour | Medium |
| `test/services/vine_recording_controller_concatenation_test.dart` | 10 | 1-2 hours | Medium |
| `test/integration/proofmode_camera_integration_test.dart` | 10 | 1-2 hours | Medium |

---

## Common Failure Patterns & Fixes

### Pattern 1: MissingStubError
```
Error: MissingStubError: 'broadcastEvent'
No stub was found which matches the arguments
```

**Fix:**
```dart
when(mockService.methodName(any))
    .thenAnswer((_) async => expectedReturnValue);
```

### Pattern 2: Provider Disposed Error
```
Error: Cannot use the Ref after it has been disposed
```

**Fix:**
```dart
await someAsyncOperation();
if (!ref.mounted) return;  // Add this guard
state = newState;
```

### Pattern 3: Invalid Pubkey
```
Error: Invalid argument (pubkey): Invalid key: "test_pubkey"
```

**Fix:**
```dart
// Generate valid keys:
final keys = Keychain.generate();
final pubkey = keys.public.toHex();
final privkey = keys.private.toHex();
```

### Pattern 4: MissingPluginException
```
Error: MissingPluginException(No implementation found for method listCameras)
```

**Fix Option A - Mock the plugin:**
```dart
TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
    .setMockMethodCallHandler(channel, (call) async {
  if (call.method == 'listCameras') return ['camera1'];
  return null;
});
```

**Fix Option B - Tag as device-only:**
```dart
@Tags(['requires-device'])
test('camera test', () { ... });
```

---

## Test Categories (Failure Breakdown)

1. **Assertion Failures** (218 tests, 43.8%) - Business logic changed
2. **Architecture Changes** (229 tests, 46.0%) - API refactored
3. **Mock Setup** (20 tests, 4.0%) - Missing stubs ⭐ START HERE
4. **Plugin Errors** (17 tests, 3.4%) - Need mocking
5. **Timeouts** (12 tests, 2.4%) - Need async fixes
6. **Provider Lifecycle** (2 tests, 0.4%) - Need disposal guards

---

## Weekly Goals

### Week 1: Foundation (Target: 85% pass rate)
- [ ] Fix all 20 mock stub errors
- [ ] Fix all 17 plugin exception tests
- [ ] Update 30-40 simple assertion failures
- [ ] Fix provider lifecycle issues
- **Expected result:** ~89 tests fixed

### Week 2: Architecture (Target: 90% pass rate)
- [ ] Update service API calls (~40 tests)
- [ ] Fix simple assertions (~30 tests)
- [ ] Fix timeout tests (12 tests)
- **Expected result:** ~82 tests fixed

### Week 3: Deep Work (Target: 95% pass rate)
- [ ] Refactor architecture-changed tests (~100 tests)
- [ ] Create test data builders
- **Expected result:** ~100 tests fixed

### Week 4: Polish (Target: 98% pass rate)
- [ ] Fix remaining complex failures
- [ ] Address edge cases
- **Expected result:** ~227 tests fixed

---

## Run Tests

**Full suite:**
```bash
cd /Users/rabble/code/andotherstuff/openvine/mobile
flutter test
```

**Specific file:**
```bash
flutter test test/services/curation_service_analytics_test.dart
```

**Watch mode (reruns on save):**
```bash
flutter test --watch
```

**With coverage:**
```bash
flutter test --coverage
```

---

## For Full Details

See `/Users/rabble/code/andotherstuff/openvine/mobile/docs/TEST_FAILURE_ANALYSIS.md`
