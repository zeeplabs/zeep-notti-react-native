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
- **Status**: active

## Handoff

- **Feature**: sdk-core-v1
- **Phase / Task**: Tasks approved (19 tasks, 5 phases) — about to start Execute at T1
- **Completed**: Specify (spec.md), Design (design.md, AD-001/AD-002 recorded), Tasks (tasks.md, validate_tasks.py 0 errors)
- **In-progress** (file:line): none — Execute has not started a task yet
- **Next step**: Begin Execute at T1 (fix CI/setup action from yarn to pnpm), following tasks.md's Execution Plan in order
- **Blockers**: none
- **Uncommitted files**: `.specs/STATE.md`, `.specs/features/sdk-core-v1/design.md`, `.specs/features/sdk-core-v1/tasks.md`
- **Branch**: main
