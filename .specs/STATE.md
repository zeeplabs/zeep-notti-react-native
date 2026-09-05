# STATE

## Decisions

### AD-001
- **Decision**: All Nuntis API integration logic (HTTP calls to `POST`/`PATCH /v1/apps/{app_id}/devices`, retry/backoff, tag-merge cache, subscription/external-id state) lives in native code (Kotlin on Android, Swift on iOS), not in the TypeScript/JS layer. The TS layer is a thin Turbo Module facade only.
- **Reason**: Mirrors `react-native-onesignal`'s real architecture — the SDK keeps working (registers devices, handles token refresh) even if the JS thread isn't running yet or has crashed, which matches this SDK's stated goal of OneSignal-equivalent reliability.
- **Trade-off**: Business logic (retry policy, tag-merge semantics, queue serialization) must be implemented and tested twice — once in Kotlin, once in Swift — with no shared code between them. Slower to iterate than a single TS implementation; requires platform-specific (instrumented/XCTest) tests rather than fast Jest unit tests to verify the actual behavior.
- **Scope**: Governs every future feature in `zeep-nuntis-react-native` that adds SDK behavior (v1 core, and any P2/P3 work like In-App Messages or Live Activities later) — new logic goes native-side by default, not into `src/`.
- **Date**: 2026-09-05
- **Status**: active

### AD-002
- **Decision**: The iOS module is scaffolded as Objective-C (`create-react-native-library`'s only Turbo Module template) but will be converted to Swift as an early implementation task — the exact Codegen bridging mechanism for a Swift-implemented Turbo Module is not yet confirmed and is treated as a research spike (first task of the SDK Core v1 implementation), not assumed.
- **Reason**: New Architecture Turbo Modules support Swift, but no scaffolding tool preset exists for Turbo Module + Swift as of `create-react-native-library` v0.63.0; rather than fabricate the bridging shape, it's verified via official RN docs/source before any push logic is written on iOS.
- **Trade-off**: iOS implementation work cannot start until the spike lands; if the spike concludes Swift bridging is impractical, this decision must be revisited (falls back to Objective-C, superseding this entry).
- **Scope**: iOS native module structure for `zeep-nuntis-react-native`, any future iOS-side feature work.
- **Date**: 2026-09-05
- **Status**: active-confirmed by spike (T2, 2026-09-05) — Swift Turbo Module bridging works via an Obj-C++ `getTurboModule:`/`moduleName` shim (`ios/Nuntis.mm`) delegating into a plain Swift class exposed through CocoaPods' auto-generated `Nuntis-Swift.h`, confirmed by a real `pod install` + Xcode build succeeding in this repo. Not an officially-documented Meta pattern (`reactnative.dev`'s Turbo Native Modules docs show Obj-C++ only, Context7 MCP unavailable in this environment) — corroborated by independent 2025 community write-ups and by this repo's own passing build. Full detail in `design.md`'s "iOS APNs delegate hooks" component.

## Handoff

- **Feature**: sdk-core-v1
- **Phase / Task**: Batch 2 (T11-T15, Phase 3, iOS native core) complete. Phases 1-3 (T1-T15) all done. Next up: Phase 4 (T16 TS facade, T17 Expo plugin) and Phase 5 (T18 example wiring, T19 README).
- **Completed**: Specify, Design (AD-001/AD-002), Tasks (validate_tasks.py 0 errors). Batch 1: T1-T10 ✅ + post-batch fix pass (see prior handoff entry, superseded below). Batch 2: T11-T15 all ✅, commits `1c9c4d2`, `ed97a90`, `9be9f67`, `898a562`, `42fd177`. iOS unit tests (`ios/Tests/*.swift`) run via a dedicated `NuntisTests` XCTest target added directly to `example/ios/NuntisExample.xcodeproj` (via the `xcodeproj` Ruby gem — CocoaPods test_spec wiring conflicted with RN autolinking's unconditional pod declaration, so this was the pragmatic call, documented in T11's deviation note): 29 tests, 0 failures, no hangs. `pnpm run build:ios` (real Xcode build) green after T14 and again after T15. TS-layer gate (`pnpm typecheck && pnpm lint && pnpm test`) re-confirmed green and unaffected, as expected.
- **In-progress** (file:line): none
- **Next step**: Phase 4 (T16 `src/index.tsx` facade, T17 Expo config plugin) then Phase 5 (T18 example app wiring, T19 README) — 4 tasks total, fits in one more batch inline or as a single worker.
- **Blockers**: none.
- **Notes for future iOS work**: (1) `Nuntis.podspec` needs `s.exclude_files = "ios/Tests/**/*"` — its `ios/**/*.swift` glob would otherwise compile XCTest-importing test files into the main pod target. (2) Any new Swift file in `ios/` that conforms to a UIKit/UserNotifications/etc. protocol needs that framework already imported in `ios/Nuntis.h` before `Nuntis.mm` includes the auto-generated `Nuntis-Swift.h` — Swift's generated ObjC header forward-declares the types it uses but does not import the owning framework itself (hit and fixed for `UserNotifications` in T15; the same class of gap will recur for any new framework the Swift sources start using). (3) Real end-to-end token flow requires a device or paid Apple push entitlement to fully verify — T15's `NuntisBridge`/`NuntisPushDelegate` are unit-tested only at the pure `parseUserInfo` layer; full verification is deferred to Phase 5's manual example-app smoke test (T18), same as Android's FCM service.
- **Uncommitted files**: none (`example/node_modules` is an untracked local symlink workaround, and `example/ios/Podfile.lock`/`example/ios/NuntisExample/Info.plist` regenerate with environment-local path/flag noise on `pod install`/`react-native build-ios` in this sandbox — both are reverted via `git checkout` after each gate run before committing, not meant to be committed)
- **Branch**: feat/sdk-core-v1
