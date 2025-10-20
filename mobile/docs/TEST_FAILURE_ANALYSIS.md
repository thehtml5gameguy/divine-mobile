# Test Failure Analysis Report

## Summary Statistics
- **Total tests**: 2,243
- **Passing**: 1,735 (77.4%)
- **Skipped**: 10 (0.4%)
- **Failing**: 498 (22.2%)
- **Pass rate**: 77.4%

## Failure Distribution by Directory

| Directory | Failures | Percentage |
|-----------|----------|------------|
| test/services | 184 | 37.0% |
| test/integration | 105 | 21.1% |
| test/screens | 85 | 17.1% |
| test/unit | 47 | 9.4% |
| test/providers | 29 | 5.8% |
| test/tools | 11 | 2.2% |
| test/performance | 10 | 2.0% |
| test/widget | 9 | 1.8% |
| test/infrastructure | 8 | 1.6% |
| test/goldens | 5 | 1.0% |
| Other | 5 | 1.0% |

## Failure Categories

### Category A: Timeout Issues (12 tests, ~2.4% of failures)

**Root Causes:**
- Tests waiting for real relay connections that never complete
- Missing test timeout configurations
- Async operations without proper completion handling
- Real network calls in integration tests

**Failed Test Files:**
- `test/integration/explore_screen_real_relay_test.dart` (2 failures)
- `test/providers/video_events_provider_test.dart` (2 failures)
- `test/integration/video_pipeline_debug_test.dart` (2 failures)
- `test/integration/video_upload_integration_test.dart` (3 failures)
- `test/integration/real_nostr_video_integration_test.dart` (1 failure)
- `test/services/social_service_test.dart` (1 failure)
- `test/integration/video_record_publish_e2e_test.dart` (1 failure)

**Fix Strategy:**
- Replace real relay calls with mock relay services in tests
- Add proper async completion signals (Completers, StreamControllers)
- Ensure all async operations have clear completion conditions
- Use test-specific relay configurations with faster timeouts

**Estimated Effort:** 4-6 hours

---

### Category B: Mock/Setup Issues (20 tests, ~4.0% of failures)

**Root Causes:**
- MissingStubError: Tests calling mock methods without proper `when()` setup
- Missing @GenerateNiceMocks or @GenerateMocks annotations
- Incomplete mock implementations for NostrService and CurationService

**Failed Test Files:**
- `test/services/curation_service_analytics_test.dart` (4 failures)
- `test/services/curation_service_editors_picks_test.dart` (4 failures)
- `test/services/curation_service_test.dart` (5 failures)
- `test/services/curation_service_trending_fetch_test.dart` (3 failures)
- `test/unit/services/social_service_comment_test.dart` (2 failures)
- `test/integration/nostr_function_channel_test.dart` (2 failures)

**Common Missing Stubs:**
- `MockINostrService.broadcastEvent()`
- `MockINostrService.subscribeToEvents()`
- `MockAnalyticsService.getTrendingVideos()`
- `MockCurationService.fetchVideoEvents()`

**Fix Strategy:**
- Add missing `when()` stubs for all mock method calls
- Use `@GenerateNiceMocks` with proper method stubs
- Create reusable mock setup helpers for common services
- Ensure all mock methods return proper Future/Stream types

**Estimated Effort:** 3-4 hours

---

### Category C: Provider Lifecycle Issues (2 tests, ~0.4% of failures)

**Root Causes:**
- Provider disposed while async operations still running
- Missing `ref.mounted` checks after async gaps
- Accessing `ref.state` after provider disposal

**Failed Test Files:**
- `test/unit/providers/comments_provider_test.dart` (1 failure)
  - "Cannot use the Ref after it has been disposed"
- `test/providers/analytics_provider_test.dart` (1 failure)
  - Provider disposed during async tracking

**Fix Strategy:**
- Add `ref.mounted` checks before state updates after async operations
- Use `ref.onDispose` to cancel pending async work
- Ensure test cleanup properly disposes providers

**Estimated Effort:** 1 hour

---

### Category D: Assertion Failures (218 tests, ~43.8% of failures)

**Root Causes:**
- Business logic changes broke test expectations
- Mock return values don't match actual implementation
- Test data setup doesn't match current API requirements
- Expected vs Actual value mismatches

**Top Failed Files:**
- `test/services/social_service_test.dart` (24 assertion failures)
  - Like count fetching logic changed
  - Follow/unfollow expectations outdated
- `test/integration/analytics_api_endpoints_test.dart` (10 failures)
  - Analytics API response format changed
  - Missing fields in mock responses
- `test/services/curation_publish_test.dart` (12 failures)
  - Invalid key format in test data
  - Pubkey validation stricter than tests expect
- `test/integration/proofmode_camera_integration_test.dart` (10 failures)
  - Camera initialization expectations changed
- `test/services/vine_recording_controller_concatenation_test.dart` (10 failures)
  - Virtual segment tracking logic changed for macOS

**Common Patterns:**
- `Expected: <value>, Actual: <different_value>` (most common)
- `Bad state: No element` (empty list access)
- `Invalid argument (pubkey): Invalid key` (data validation)
- HTTP status code mismatches (400 vs 200)

**Fix Strategy:**
- **Phase 1 (Quick Wins):** Update test expectations to match current implementation
  - Fix invalid test data (pubkeys, event IDs)
  - Update expected HTTP response formats
  - Adjust assertion values for changed business logic
- **Phase 2 (Medium):** Refactor tests to use real data builders
  - Create factory methods for valid test data
  - Use real event/profile generators
  - Replace hardcoded values with dynamic builders
- **Phase 3 (Long-term):** Add contract tests
  - Define explicit API contracts
  - Auto-generate test expectations from contracts
  - Use snapshot testing for complex data structures

**Estimated Effort:** 15-20 hours total
- Quick wins (fixing simple assertion values): 8-10 hours
- Medium refactoring (data builders): 5-7 hours
- Contract tests: 2-3 hours

---

### Category E: Missing Plugin Exceptions (17 tests, ~3.4% of failures)

**Root Causes:**
- Platform-specific plugins not registered in test environment
- Camera plugins require real device/simulator
- macOS native camera plugin missing in test context

**Failed Test Files:**
- `test/services/camera_service_macos_test.dart` (8 failures)
  - `MissingPluginException(No implementation found for method listCameras)`
- `test/services/camera/enhanced_mobile_camera_interface_test.dart` (9 failures)
  - Camera plugins not available in unit test context

**Fix Strategy:**
- Mock platform channel responses for camera methods
- Use `TestDefaultBinaryMessengerBinding` to register fake plugin handlers
- Create mock camera service for unit tests
- Move real camera tests to integration test suite with `@Tags(['requires-device'])`

**Estimated Effort:** 3-4 hours

---

### Category F: API/Architecture Changes (229 tests, ~46.0% of failures)

**Root Causes:**
- NostrService API refactored but tests not updated
- VideoEventService method signatures changed
- Provider structure reorganized
- Service dependencies changed

**Common Error Patterns:**
- `No matching calls` - Mock expectations don't match actual calls
- `Exception: Failed to initialize` - Service initialization changed
- `Bad state: No element` - Collection access patterns changed
- `Unexpected status code` - HTTP API contracts changed

**Top Failed Files:**
- `test/widget/screens/hashtag_feed_screen_test.dart` (9 failures)
- `test/tools/future_delayed_detector_test.dart` (9 failures)
- `test/services/notification_service_enhanced/event_handlers_simple_test.dart` (9 failures)
- `test/screens/profile_video_deletion_test.dart` (8 failures)
- `test/services/embedded_relay_service_test.dart` (8 failures)

**Fix Strategy:**
- **Phase 1:** Update service constructor calls and method signatures
- **Phase 2:** Fix mock setup to match new API contracts
- **Phase 3:** Update test data to match new validation requirements
- **Phase 4:** Replace deprecated patterns with current architecture

**Estimated Effort:** 20-25 hours

---

## Prioritized Action Plan

### Phase 1: Quick Wins (4-6 hours total)

**Goal:** Fix tests with simple assertion updates and mock stubs

1. **Add Missing Mock Stubs** (2-3 hours) - 20 tests
   - Add `when()` stubs for `MockINostrService.broadcastEvent()`
   - Stub `MockAnalyticsService` methods
   - Fix social service comment test mocks

2. **Fix Provider Lifecycle Issues** (1 hour) - 2 tests
   - Add `ref.mounted` checks in CommentsNotifier
   - Fix analytics provider disposal timing

3. **Update Simple Assertions** (1-2 hours) - ~30 tests
   - Fix expected values that just need updating
   - Correct HTTP status codes
   - Update event count expectations

**Files to Target:**
- `test/services/curation_service_*.dart` - Mock setup fixes
- `test/unit/providers/comments_provider_test.dart` - Lifecycle fix
- `test/integration/analytics_api_endpoints_test.dart` - Assertion updates

---

### Phase 2: Medium Effort (8-12 hours total)

**Goal:** Fix architectural mismatches and data validation

1. **Fix Invalid Test Data** (3-4 hours) - ~50 tests
   - Replace invalid pubkeys with valid test keys
   - Use proper Nostr event ID formats
   - Fix malformed API request bodies

2. **Update Service API Calls** (3-4 hours) - ~40 tests
   - Update NostrService method calls to new signatures
   - Fix VideoEventService subscription patterns
   - Update provider initialization

3. **Mock Platform Plugins** (2-3 hours) - 17 tests
   - Create camera plugin mocks
   - Register test platform channels
   - Move device-dependent tests to integration suite

**Files to Target:**
- `test/services/social_service_test.dart` - 24 tests, invalid data
- `test/services/curation_publish_test.dart` - 12 tests, key validation
- `test/services/camera_service_macos_test.dart` - 8 tests, plugin mocks

---

### Phase 3: High Effort (12-16 hours total)

**Goal:** Address timeouts and major refactoring needs

1. **Fix Timeout Tests** (4-6 hours) - 12 tests
   - Replace real relay calls with mocks
   - Add proper async completion handling
   - Create test relay fixtures

2. **Refactor Architecture-Changed Tests** (6-8 hours) - ~100 tests
   - Update deprecated service patterns
   - Refactor provider structure usage
   - Fix embedded relay architecture tests

3. **Create Test Data Builders** (2-3 hours) - Infrastructure
   - Build factory methods for valid test events
   - Create profile/video generators
   - Reusable mock setup helpers

**Files to Target:**
- `test/integration/*_real_relay_test.dart` - Timeout fixes
- `test/services/embedded_relay_service_test.dart` - Architecture updates
- `test/screens/*.dart` - Provider structure changes

---

### Phase 4: Long-term Improvements (4-6 hours, optional)

**Goal:** Prevent future test failures

1. **Add Contract Tests** (2-3 hours)
   - Define API contracts for services
   - Auto-validate mock responses
   - Snapshot testing for complex data

2. **Improve Test Infrastructure** (2-3 hours)
   - Create test base classes with common setup
   - Build mock service registry
   - Add test data validation helpers

---

## Recommended Fix Order (Most Impact First)

### Week 1: Foundation (12-16 hours)
1. **Mock stubs** → Fixes 20 tests quickly
2. **Invalid test data** → Fixes 50+ tests, prevents future issues
3. **Provider lifecycle** → Fixes 2 tests, prevents flakiness
4. **Platform plugins** → Fixes 17 tests

**Total: ~89 tests fixed (18% of failures)**

### Week 2: Architecture Updates (14-18 hours)
1. **Service API updates** → Fixes ~40 tests
2. **Simple assertions** → Fixes ~30 tests
3. **Timeout fixes** → Fixes 12 tests

**Total: ~82 tests fixed (16% of failures)**

### Week 3: Deep Refactoring (12-16 hours)
1. **Architecture-changed tests** → Fixes ~100 tests
2. **Test data builders** → Infrastructure for remaining tests

**Total: ~100 tests fixed (20% of failures)**

### Week 4: Remaining Tests (10-12 hours)
1. **Complex assertion failures** → Case-by-case fixes
2. **Edge cases and flaky tests** → Individual debugging

**Total: Remaining ~227 tests**

---

## High-Priority Test Files (Fix These First)

### Top 10 by Impact:
1. **test/services/social_service_test.dart** (24 failures)
   - Fix: Update invalid pubkeys, mock NostrService properly
   - Effort: 2-3 hours

2. **test/services/curation_publish_test.dart** (12 failures)
   - Fix: Use valid key formats, add missing mock stubs
   - Effort: 1-2 hours

3. **test/integration/analytics_api_endpoints_test.dart** (10 failures)
   - Fix: Update expected API response formats
   - Effort: 1 hour

4. **test/integration/proofmode_camera_integration_test.dart** (10 failures)
   - Fix: Mock camera plugin or tag as `@Tags(['requires-device'])`
   - Effort: 1-2 hours

5. **test/services/vine_recording_controller_concatenation_test.dart** (10 failures)
   - Fix: Update virtual segment expectations for macOS
   - Effort: 1-2 hours

6. **test/widget/screens/hashtag_feed_screen_test.dart** (9 failures)
   - Fix: Update provider structure usage
   - Effort: 1-2 hours

7. **test/tools/future_delayed_detector_test.dart** (9 failures)
   - Fix: Update async pattern detection logic
   - Effort: 1 hour

8. **test/services/notification_service_enhanced/event_handlers_simple_test.dart** (9 failures)
   - Fix: Update event handler mocks
   - Effort: 1 hour

9. **test/services/camera/enhanced_mobile_camera_interface_test.dart** (9 failures)
   - Fix: Mock platform channels
   - Effort: 1-2 hours

10. **test/screens/profile_video_deletion_test.dart** (8 failures)
    - Fix: Update provider invalidation patterns
    - Effort: 1 hour

**Total effort for top 10**: 11-16 hours
**Tests fixed**: 110 tests (22% of all failures)

---

## Next Steps

### Immediate Actions (Start Today)
1. **Run** `/Users/rabble/code/andotherstuff/openvine/mobile/test/services/curation_service_analytics_test.dart`
   - Read the MissingStubError messages
   - Add the 4-5 missing `when()` stubs
   - Verify tests pass
   - **Time:** 30 minutes

2. **Fix** `test/unit/providers/comments_provider_test.dart`
   - Add `if (!ref.mounted) return;` before state updates
   - **Time:** 15 minutes

3. **Update** `test/services/curation_publish_test.dart`
   - Replace `"test_pubkey"` with proper hex pubkeys
   - Use `Keychain.generate().public.toHex()`
   - **Time:** 30 minutes

### This Week Goals
- Fix all 20 mock stub errors
- Fix all 17 plugin exception tests
- Update 30-40 simple assertion failures
- **Target:** 80-100 tests fixed (16-20% reduction in failures)

### Success Metrics
- **Week 1 Target:** 85%+ pass rate (currently 77.4%)
- **Week 2 Target:** 90%+ pass rate
- **Week 3 Target:** 95%+ pass rate
- **Week 4 Target:** 98%+ pass rate

### Blockers to Watch For
- Tests requiring real device access (camera, Bluetooth)
- Tests depending on external services (analytics API, relays)
- Flaky tests due to timing issues
- Tests covering deprecated features

---

## Conclusion

The test suite has a **77.4% pass rate** with **498 failing tests**. The failures break down into:

- **43.8% Assertion failures** - Business logic changed, need expectation updates
- **46.0% Architecture changes** - API refactoring, need test updates
- **4.0% Mock setup** - Missing stubs, easy fixes
- **3.4% Plugin errors** - Need mocking or device tagging
- **2.4% Timeouts** - Need async handling fixes
- **0.4% Provider lifecycle** - Need disposal guards

The **top 10 files account for 110 failures (22%)**, making them high-impact targets. Fixing mock stubs, invalid test data, and simple assertions in **Phases 1-2 (20-24 hours)** should bring the pass rate to **90%+**.

**Recommended first action:** Fix `curation_service_analytics_test.dart` mock stubs (30 min) to build momentum with quick wins.
