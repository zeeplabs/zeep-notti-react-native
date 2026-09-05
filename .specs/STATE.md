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
- **Phase / Task**: Batch 1 (T1-T10, Phases 1-2) complete + a post-batch fix pass. About to dispatch Batch 2 (T11-T15, Phase 3, iOS).
- **Completed**: Specify, Design (AD-001/AD-002), Tasks (validate_tasks.py 0 errors). Batch 1: T1-T10 all ✅, commits `6ac087c`..`b60256c`. Fix pass on top (found by orchestrator review, not a formal task): `2ba2928` (baseUrl param added to `initialize()`, self-hosted Nuntis has no fixed host — spec.md/design.md amended), `ff059b1` (real `FirebaseMessaging.getInstance().token` wired into the previously-stubbed `tokenProvider`), `3d477cf` (fixed `example/android/settings.gradle`'s relative `node_modules` path for this repo's pnpm/hoisted layout), `3bdcb89` (commit Podfile.lock/Gemfile.lock, gitignore generated `.xcworkspace`), `e21d10c` (eslint now ignores native `build/` output dirs — was sweeping up a Gradle-generated JS test report). Along the way found and killed a genuine test hang (unbounded `MockWebServer.takeRequest()` in `NuntisCoreTest.kt`, confirmed via `jstack`, fixed with a bounded timeout) — not an environment flake. Final Android gate re-verified green by the orchestrator directly (forced `--rerun`, not cache): `BUILD SUCCESSFUL`, 32 tests / 0 failures.
- **In-progress** (file:line): none
- **Next step**: Dispatch Batch 2 (T11-T15, iOS native core) as a sub-agent batch worker, same model as Batch 1 — mirror Android's contract into Swift, informed by T2/T3's confirmed bridging mechanism (AD-002) and the corrected `baseUrl`-bearing `initialize()` signature from the fix pass above (do NOT let iOS mirror the old 2-arg signature).
- **Blockers**: none. Note for the iOS batch worker: budget real wall-clock time for Xcode/XCTest builds and gate runs (first-run CocoaPods installs and Xcode builds are slow) and watch them to actual completion rather than leaving them backgrounded unattended — Batch 1's Android gate run stalled on an unrelated test bug and looked identical to "just slow" until directly inspected with `jstack`, costing real time before it was caught.
- **Uncommitted files**: none (`example/node_modules` is an untracked local symlink workaround for the settings.gradle path issue, safe to ignore — not meant to be committed)
- **Branch**: feat/sdk-core-v1
