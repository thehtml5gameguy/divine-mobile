# Repository Guidelines

## Project Structure & Modules
- `mobile/`: Flutter app. Code in `lib/`; tests in `test/` and `integration_test/`; assets in `assets/`.
- `backend/`: Cloudflare Workers (TypeScript). Code in `src/`; tests in `test/`; config in `wrangler.jsonc` and `.wrangler/`.
- `nostr_sdk/`: Dart package used by the app (`lib/`, `test/`). Other roots: `docs/`, `website/`, `crawler/`.

## Build, Test, Develop
- Mobile
  - `cd mobile && flutter pub get && flutter run` (Chrome or device)
  - `cd mobile && flutter test` (unit/widget) • `flutter analyze` (lints)
  - `cd mobile && dart format --set-exit-if-changed .` (format)
  - Native builds: `cd mobile && ./build_native.sh ios|macos [debug|release]` (avoids CocoaPods sync issues)
- Backend
  - `cd backend && npm install && npm run dev` (Wrangler dev)
  - `cd backend && npm test` (Vitest Workers pool)
  - `cd backend && npm run deploy` • `npm run cf-typegen`

## Coding Style & Conventions
- Dart/Flutter: `analysis_options.yaml` (Flutter lints). 2-space indent; files `snake_case.dart`; classes/widgets `PascalCase`; members `camelCase`. Pre-commit checks: max ~200 lines/file, ~30 lines/function, and a “no `Future.delayed` in lib/” rule.
- TypeScript: Prettier per `backend/.prettierrc` (tabs, single quotes, semicolons, width 140) and `backend/.editorconfig`. Files `kebab-case.ts`; tests `*.test.ts|*.spec.ts` in `backend/test`.

## Agent-Specific Instructions (from CLAUDE.md)
- Embedded Nostr Relay: The app must not connect directly to external relays. Use the embedded relay at `ws://localhost:7447`; external connectivity is managed via `addExternalRelay()` (see `mobile/docs/NOSTR_RELAY_ARCHITECTURE.md`).
- Async Standards: Never fix timing with arbitrary sleeps or `Future.delayed()`. Prefer callbacks, `Completer`, streams, and explicit readiness signals.
- Required Quality Gate: After any Dart change, run `flutter analyze` and address all findings before considering work complete.
- Analytics Ops: From `backend/`, use `./flush-analytics-simple.sh true|false` to preview/flush analytics KV.

## Testing Guidelines
- Mobile: `flutter test`; target ≥80% overall coverage (see `mobile/coverage_config.yaml`). Co-locate tests as `*_test.dart`.
- Backend: Vitest with Cloudflare Workers pool. Place tests in `backend/test` with descriptive names.

## Commit & PRs
- Use Conventional Commits (`feat:`, `fix:`, `docs:`...).
- PRs: clear description, linked issues, tests for new logic, and screenshots/recordings for UI.
- Pre-flight: analyzers, formatters, and tests pass locally (`pre-commit run -a` if configured).
