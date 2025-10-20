# Obsolete Test Files

**Generated**: 2025-10-20

## Summary

This document identifies test files in `test/unit/` and `test/integration/` that may be testing code/features that no longer exist or have been refactored significantly.

## Tests for Deleted Code (MOVE TO old_files/)

### High Confidence (definitely obsolete)

**None found** - All test imports appear to reference existing production code.

### Medium Confidence (probably obsolete)

**None identified yet** - Need manual review of specific test files against current architecture.

### Low Confidence (needs review)

**None identified yet** - Further analysis required.

## Tests Using Deprecated Patterns

Tests referencing potentially old code patterns:

### Kind 22/NIP-71 References (27 files)
**Status**: **KEEP** - Kind 22 is still officially supported per `nip71_migration.dart`

The following tests reference Kind 22 events, which ARE still valid:
- Kind 22 (shortVideo) is defined in `lib/constants/nip71_migration.dart`
- Kind 34236 (addressableShortVideo) is the newer addressable variant
- Both kinds are supported per NIP-71 compliance
- Tests using kind 22 are NOT obsolete

Files testing Kind 22 functionality (VALID):
- `test/integration/embedded_relay_subscription_test.dart`
- `test/integration/relay_pagination_integration_test.dart`
- `test/integration/real_relay_test.dart`
- `test/integration/nostr_service_integration_test.dart`
- `test/integration/video_event_service_simple_test.dart`
- `test/integration/profile_fetch_embedded_relay_test.dart`
- `test/integration/auth_and_kind22_vine_relay_test.dart` - Tests AUTH and Kind 22 retrieval
- `test/services/social_service_test.dart`
- `test/services/nostr_service_search_kinds_test.dart`
- `test/unit/video_event_real_parsing_test.dart`
- `test/unit/services/video_event_service_infinite_scroll_test.dart`
- `test/unit/services/embedded_relay_performance_unit_test.dart`
- `test/unit/models/video_event_blurhash_parsing_test.dart`
- And 14 more files...

### VideoEventProcessor Tests (3 files)
**Status**: **KEEP** - VideoEventProcessor exists at `lib/services/video_event_processor.dart`

Files:
- `test/unit/services/video_event_processor_test.dart` - Comprehensive test suite
- `test/services/video_event_processor_test.dart` - Duplicate location?
- `test/services/video_event_processor_repost_integration_test.dart` - Repost integration tests

**Action**: Verify if we have duplicate test files for the same service.

### Tests Already in old_files/ (1 file)

- `test/old_files/nostr_pagination_relay_test.dart` - Already moved, references deprecated kind 22 pagination patterns

## Potential Issues to Investigate

### Duplicate Test Files
Some test files may exist in both `test/services/` and `test/unit/services/`:
- VideoEventProcessor tests appear in multiple locations
- Need to verify which is the canonical test location

### Tests with Arbitrary Delays
Per FLUTTER.md, tests should NOT use `Future.delayed()` or arbitrary timeouts. The following tests may need refactoring:

Need to scan for:
- `Future.delayed` usage in test files
- Arbitrary timeout parameters
- Tests that rely on timing instead of proper async patterns

### Tests Using Mocks in Integration Tests
Per project guidelines, integration/e2e tests should use real services, not mocks:

Need to check:
- `test/integration/*test.mocks.dart` files
- Whether integration tests are actually using mocks (violation of policy)

## Action Plan

1. ✅ **VERIFIED**: Kind 22 tests are NOT obsolete - Kind 22 is still supported
2. ✅ **VERIFIED**: VideoEventProcessor exists and tests are valid
3. **TODO**: Investigate duplicate test files (e.g., VideoEventProcessor in multiple locations)
4. **TODO**: Scan for tests using `Future.delayed()` and refactor to use proper async patterns
5. **TODO**: Check integration tests for mock usage (should use real services only)
6. **TODO**: Review tests that haven't been modified in 6+ months for relevance

## Notes

- No tests with obviously missing imports were found
- All major services (VideoEventProcessor, NostrService, VideoEventService) have valid tests
- The codebase appears well-maintained with minimal test rot
- Most deprecated patterns (Kind 32222, old activeVideoProvider.notifier) have been cleaned up already

## Recommended Next Steps

1. Run a more detailed analysis looking for:
   - Tests importing deleted files (check file existence)
   - Tests using deprecated API methods no longer in production code
   - Tests with stale comments referencing old features

2. Create a script to auto-detect:
   - Test files not executed in CI/CD
   - Tests with consistently failing runs
   - Tests with no assertions (dead tests)

3. Review git history for tests modified >12 months ago and verify relevance
