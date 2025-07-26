# Test Infrastructure Fix Strategy

## Current State
- **293 failing tests** (compilation errors)
- **591 analyzer issues** (up from 378)
- Core models changed significantly
- Test helpers and mocks removed

## Root Causes
1. VideoEvent model breaking changes
2. Service initialization patterns changed  
3. Test infrastructure files deleted
4. Mock classes removed

## Fix Strategy (Zen Refactor Approach)

### Phase 1: Core Model Fixes (Day 1)
1. **Create test builders** to replace DefaultContentService:
   ```dart
   class TestVideoEventBuilder {
     static VideoEvent create({String? id, String? title}) {
       return VideoEvent(
         id: id ?? 'test_${DateTime.now().millisecondsSinceEpoch}',
         pubkey: 'test_pubkey',
         createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
         content: 'Test video content',
         timestamp: DateTime.now(),
         videoUrl: 'https://example.com/test.mp4',
         title: title ?? 'Test Video',
       );
     }
   }
   ```

2. **Fix all VideoEvent constructor calls**:
   - Remove `metadataMap`
   - Add required `content` and `timestamp`
   - Change timestamp type to DateTime

### Phase 2: Service Dependencies (Day 1-2)
1. **Create minimal test service implementations**:
   - TestNostrService (implements INostrService)
   - TestSubscriptionManager
   - TestVideoEventService

2. **Fix service initialization patterns**:
   - Add required constructor parameters
   - Update provider overrides in tests

### Phase 3: Mock Generation (Day 2)
1. **Regenerate mocks using mockito**:
   ```bash
   flutter pub run build_runner build --delete-conflicting-outputs
   ```

2. **Create shared test setup**:
   ```dart
   // test/helpers/test_setup.dart
   class TestSetup {
     static ProviderContainer createContainer({
       List<Override>? overrides,
     }) {
       return ProviderContainer(
         overrides: [
           nostrServiceProvider.overrideWithValue(TestNostrService()),
           ...?overrides,
         ],
       );
     }
   }
   ```

### Phase 4: Critical Path Tests (Day 3)
Focus on fixing tests for:
1. Video playback flow
2. Authentication flow
3. Upload flow
4. Social features (likes, follows, comments)

### Phase 5: Cleanup (Day 3-4)
1. Delete truly obsolete tests
2. Update test documentation
3. Run coverage report
4. Update CODEBASE_CLEANUP_PLAN.md

## Success Metrics
- [ ] All tests compile
- [ ] Core functionality tests pass
- [ ] Test coverage > 60%
- [ ] No Future.delayed in tests
- [ ] Analyzer issues < 400

## Notes
- Following "zen:refactor" - no gradual migration
- Clean, complete changes only
- Delete rather than comment out
- No backwards compatibility