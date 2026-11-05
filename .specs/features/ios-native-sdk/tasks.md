# iOS on the Native SDK Tasks

**Design**: `.specs/features/ios-native-sdk/design.md` (approved by Julio, 2026-10-31)
**Status**: T1-T9 implemented on `feat/ios-native-sdk` (2026-11-05). T10 waits for `NottiSDK` 0.2.0 on the CocoaPods trunk (EXT-2); T11 is Julio's device run.

---

## Test Coverage Convention (no `.specs/codebase/TESTING.md`; derived from `AGENTS.md`)

| Code layer | Test type | Command |
| --- | --- | --- |
| iOS adapter (`ios/*.swift`, `ios/Notti.mm`) | XCTest (`ios/Tests`, scheme `NottiTests`) with a fake `NottiNativeSDK` | `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'` |
| Podspec, Podfile, CI | Build | `cd example/ios && pod install && xcodebuild build ... -sdk iphonesimulator` (default, plus `USE_FRAMEWORKS=static` and `dynamic`) |
| TS (`src/`), plugin (`plugin/`) | Jest | `pnpm typecheck && pnpm lint && pnpm test` |
| Behavior of `NottiSDK` itself | Tested in `zeep-notti-ios-sdk`, not here (L-001) | - |

**Gates**:
- `quick` (iOS tasks): `NottiTests` scheme.
- `build` (podspec/CI tasks): `pod install` + simulator build in the three linkages.
- `full` (T10): `pnpm typecheck && pnpm lint && pnpm test && pnpm run build:android && pnpm run build:ios`,
  `NottiTests`, and the two `use_frameworks!` builds.

`src/` is not touched (no JS API change). Android is not touched.

---

## Prerequisites and blockers

| ID | What | Owner | Blocks |
| --- | --- | --- | --- |
| EXT-1 | `NottiSDK` 0.2.0 in `zeep-notti-ios-sdk`: `@_spi(Wrapper)` initialize with `sdkName` and `sdkVersion` (G4, AD-024 there). Spec lives in that repo. Status 2026-10-31: implemented on branch `feat/wrapper-support` (T1-T6), not released. | iOS SDK repo | T2 (compiles against a `:path` checkout of the branch), T10 (published version) |
| EXT-2 | `NottiSDK` 0.2.0 and `NottiSDKExtension` 0.2.0 on the CocoaPods trunk before the cutoff (G3) | Julio (`pod trunk push`) | T10 |
| EXT-3 | Report to the iOS SDK repo: `NottiSDK.Notti` does not compile for CocoaPods Swift consumers (Obj-C class `NottiSDK` shadows the module). Status 2026-10-31: done; fixed there by renaming the class to `NottiSDKFacade` (AD-023), on `feat/wrapper-support`. | iOS SDK repo | nothing (this repo never qualifies) |
| HF-1 | Hotfix `fix/ios-use-frameworks-swift-header` (0.8.1) merged to `main`: `Notti.mm` header import + CI `use_frameworks!` legs | Julio (merge, release) | T1 (branch from `main` after it) |
| B-1 | Local CoreSimulator out of date (`Current version (1174.9.2) is older than build version (1174.21.0)`): no XCTest run and no app launch on this machine until Xcode components are updated | Julio | every `quick` gate, T11 |

---

## Execution Plan

### Phase 1: Packaging (sequential)

```
HF-1 ──→ T1 ──→ T2
EXT-1 (branch) ──┘
```

### Phase 2: Adapter (sequential within `NottiImpl.swift`; T5 and T8 in other files)

```
T2 ──→ T3 ──→ T4 ──→ T6
T2 ──→ T5 ─────────→ T6
T8 [P] (independent)
```

### Phase 3: Cleanup, docs, publish, validate

```
T6 ──→ T7
T5, T6 ──→ T9
T7, T8, T9, EXT-2 ──→ T10 ──→ T11
```

---

## Task Breakdown

### T1: Podspec depends on `NottiSDK`; NSE subspec becomes an alias

**What**: `Notti.podspec` Core gets `core.dependency "NottiSDK", "~> 0.2.0"`, loses `resource_bundles` and
`frameworks = "CoreLocation"`. NSE subspec: sources = `ios/NotificationServiceExtension/NottiSDKExtensionReexport.swift`
(`@_exported import NottiSDKExtension`), `nse.dependency "NottiSDKExtension", "~> 0.2.0"`, no `test_spec`.
Example Podfile: drop `:testspecs => ['Tests']`; add a development override
`pod 'NottiSDK', :path => '../../../zeep-notti-ios-sdk'` and the same for `NottiSDKExtension` (removed in
T10). Old Swift core still compiles in this task.
**Where**: `Notti.podspec`, `ios/NotificationServiceExtension/`, `example/ios/Podfile`
**Depends on**: HF-1, EXT-1 branch checked out locally
**Reuses**: spike diff (`spike/ios-native-sdk`)
**Requirement**: NSDK-01 (partial), NSDK-13, NSDK-18, NSDK-21 (partial)
**Done when**:
- [x] `pod install` and simulator build pass in default, `USE_FRAMEWORKS=static`, `USE_FRAMEWORKS=dynamic`
- [x] Example NSE target compiles with `import Notti` unchanged
- [x] `example/ios/Podfile.lock` and `Info.plist` noise reverted (AGENTS.md)
**Tests**: none (build)
**Gate**: build

### T2: `NottiNativeSDK` seam

**What**: Protocol covering every SDK call the adapter makes (initialize via SPI with `sdkVersion`, identity,
tags, email/phone, subscription, location, `deviceId`, `trackEvent`, `requestPermission(completion:)`,
the four `add…Listener`, `takeInitialClick`, manual APNs forwarding) and the production implementation
calling `Notti.*` unqualified, with `@_spi(Wrapper) import NottiSDK`.
**Where**: `ios/NottiNativeSDK.swift` (new)
**Depends on**: T1
**Requirement**: NSDK-02, NSDK-03, NSDK-17
**Done when**:
- [x] Builds in the three linkages; no `NottiSDK.` qualification anywhere (`grep -n "NottiSDK\.Notti" ios/` empty)
**Tests**: none (pure pass-through; covered through the fake in T3-T5)
**Gate**: build

### T3: Adapter method forwarding

**What**: Rewrite `NottiImpl`'s Spec methods to call the facade: `initialize` with
`Options(baseUrl:, opensInAppURLs: false)` and `sdkVersion`; one-line forwards for the rest;
`getDeviceId`; `requestPermission` resolving the promise from the completion. `NottiImpl` takes the
facade by injection (production default). Old core references removed from these methods.
**Where**: `ios/NottiImpl.swift`, `ios/Tests/NottiImplAdapterTests.swift` (new), `ios/Tests/FakeNottiNativeSDK.swift` (new)
**Depends on**: T2
**Requirement**: NSDK-02, NSDK-03, NSDK-04
**Done when**:
- [x] Each Spec method forwards the exact arguments (one test per method)
- [x] `initialize` passes `opensInAppURLs == false`, `sdkName == "react-native"` and the JS `sdkVersion`, empty string included
- [x] `requestPermission` resolves with the facade's Bool
**Tests**: XCTest with the fake facade
**Gate**: quick (blocked by B-1 until resolved)

### T4: Event bridging and initial click

**What**: `activate()` takes the initial click into a process-wide slot, then adds received, clicked,
device id and In-App click listeners, mapping payloads to the 0.8.0 dictionaries (`title`, `body`,
`data`; `messageId`, `buttonId`, `action {type, value}` or null). `invalidate()` removes every
subscription. `takeInitialNotificationClick()` returns and clears the slot, falling back to
`takeInitialClick()`.
**Where**: `ios/NottiImpl.swift`, `ios/Tests/NottiImplEventTests.swift` (new)
**Depends on**: T3
**Requirement**: NSDK-05, NSDK-06, NSDK-07
**Done when**:
- [x] Take happens before the clicked listener is added (fake records call order)
- [x] Payload mapping matches the 0.8.0 shapes, including `action: null`
- [x] After `invalidate()` the fake has zero live subscriptions; a second module instance gets each event once
- [x] Initial click returned once, nil afterwards, also across a simulated reload
**Tests**: XCTest with the fake facade
**Gate**: quick

### T5: Deprecated `NottiBridge` and `NottiPushDelegate`

**What**: Move both to `ios/NottiLegacyIntegration.swift`, marked `@available(*, deprecated, message:)`.
`NottiBridge` forwards to the facade's manual APNs API. `NottiPushDelegate.shared` completes `willPresent`
with `[.banner, .list, .sound, .badge]` and `didReceive` with `completionHandler()`, reporting nothing.
Keep the Obj-C names `NottiBridge` and `NottiPushDelegate`.
**Where**: `ios/NottiLegacyIntegration.swift` (new), `ios/NottiPushDelegate.swift` (deleted),
`ios/Tests/NottiLegacyIntegrationTests.swift` (new)
**Depends on**: T2
**Requirement**: NSDK-11, NSDK-12
**Done when**:
- [x] Bridge calls reach the fake's manual API with the same token/error
- [x] Delegate completes with the documented options and never calls the facade
- [x] 0.8.0 README `AppDelegate` snippet compiles in the example (with deprecation warnings only)
**Tests**: XCTest
**Gate**: quick

### T6: Delete the in-repo core and its tests

**What**: Delete `NottiApiClient`, `NottiCore`, `NottiDeviceStore`, `NottiEventBuffer`, `NottiEventStore`,
`NottiInApp*`, `NottiNetworkObserver`, `NottiNotificationParsing`, `NottiPushPermissionAction`,
`ios/PrivacyInfo.xcprivacy`, the old NSE helper and its tests, and every matching suite in `ios/Tests/`
(keep `StubURLProtocol.swift` only if an adapter test uses it). Fix `Notti.mm` if it referenced removed
symbols; add `.gitignore`/`package.json` `files` cleanup for removed paths.
**Where**: `ios/`, `ios/Tests/`, `package.json` (`files`)
**Depends on**: T4, T5
**Requirement**: NSDK-01, NSDK-19, NSDK-21
**Done when**:
- [x] `ios/` holds only `Notti.h`, `Notti.mm`, `NottiImpl.swift`, `NottiNativeSDK.swift`, `NottiLegacyIntegration.swift`, the NSE re-export and adapter tests
- [x] Swift line count under 600 (excluding tests)
- [x] Builds in the three linkages; `NottiTests` green
- [ ] Archive privacy report lists the `NottiSDK` manifest, not `Notti_Privacy` (manual check, recorded in T11)
**Tests**: existing adapter tests
**Gate**: quick + build

### T7: CI follows the new layout

**What**: Remove the NSE unit-test step (its scheme no longer exists; tests live in the SDK). Keep the
`NottiTests` step and HF-1's `use_frameworks!` legs.
**Where**: `.github/workflows/ci.yml`
**Depends on**: T6
**Requirement**: NSDK-16, NSDK-20
**Done when**:
- [x] Workflow parses; no step references a removed scheme
**Tests**: none
**Gate**: CI run on the PR (note: GitHub Actions billing may block runs, see iOS SDK history; then run locally)

### T8: Expo config plugin review [P]

**What**: Confirm the plugin does not write `AppDelegate` push code or an NSE source that imports the old
helper; update plugin code and its Jest tests only if it does. Record the result in this task.
**Where**: `plugin/src/withNotti.ts`, `src/__tests__/`
**Depends on**: none
**Requirement**: NSDK-14
**Finding (2026-11-05)**: no change needed. The iOS side of `plugin/src/withNotti.ts` only writes the `aps-environment` entitlement (`withEntitlementsPlist`); it edits no `AppDelegate` and creates no NSE source, so nothing imports the old helper. No code or Jest change.

**Done when**:
- [x] Finding recorded; tests updated if code changed; JS gate green
**Tests**: Jest (only if code changes)
**Gate**: `pnpm typecheck && pnpm lint && pnpm test`

### T9: README, CHANGELOG, STATE

**What**: README iOS section: no `AppDelegate` forwarding (swizzling, opt-out key named only after the iOS
SDK confirms it), NSE Podfile line and import, foreground presentation rule, frameworks support.
`CHANGELOG.md` `[Unreleased]` upgrade notes with `BREAKING CHANGE` content (remove `AppDelegate` lines,
NSE import if the re-export ever has to go, foreground rule, warning for identity calls before
`initialize`). `STATE.md` AD-005 status, Known limitations (duplicate-module warnings).
**Where**: `README.md`, `CHANGELOG.md`, `.specs/STATE.md`
**Depends on**: T5, T6
**Requirement**: NSDK-11, NSDK-13, NSDK-15
**Done when**:
- [x] Every integrator-visible change from spec P1 "Integrator setup" has an upgrade note
- [x] README snippets compile in the example
**Tests**: none
**Gate**: `pnpm lint` (prettier on markdown)

### T10: Switch to the published `NottiSDK` and run the full gate

**What**: Remove the `:path` overrides from the example Podfile; `pod install` resolves `NottiSDK` and
`NottiSDKExtension` 0.2.x from the trunk; run the full gate.
**Where**: `example/ios/Podfile`
**Depends on**: T7, T8, T9, EXT-2
**Requirement**: NSDK-16, NSDK-20
**Done when**:
- [ ] Full gate green (commands at the top), outputs pasted in the PR
**Tests**: all
**Gate**: full

### T11: Device validation

**What**: On a device (or a simulator once B-1 is fixed) record in `validation.md`: upgrade from 0.8.0 in
place (one device row, same `getDeviceId()`, queued events flushed), push received in foreground and
background, cold-start tap via `getInitialNotificationClick()`, rich push through the alias NSE, In-App
click listener with no link opened, 0.8.0 `AppDelegate` lines kept vs removed (no duplicate `received`),
launch in the three linkages (`+load` ran: device registers without any `AppDelegate` code), privacy
report from an archive.
**Where**: `.specs/features/ios-native-sdk/validation.md` (new)
**Depends on**: T10
**Requirement**: NSDK-08, NSDK-09, NSDK-11, NSDK-12, NSDK-16, NSDK-18, NSDK-21 (runtime)
**Done when**:
- [ ] Every item has a recorded result by Julio or by a run with evidence
**Tests**: manual
**Gate**: manual

NSDK-10 (key audit) is verified by analysis in `design.md` ("Data continuity"); T11's upgrade check is its
runtime proof.

---

## Validation (pre-approval checks)

### Check 1: Granularity

| Task | One deliverable? | Result |
| --- | --- | --- |
| T1 | Packaging change (podspec + its alias file + example Podfile override, one build concern) | ✅ |
| T2 | One file | ✅ |
| T3 | Method forwarding in one class + its tests | ✅ |
| T4 | Event bridging in one class + its tests | ✅ |
| T5 | One new file + its tests | ✅ |
| T6 | Deletion only | ✅ |
| T7 | One workflow file | ✅ |
| T8 | One review, conditional edit | ✅ |
| T9 | Docs only | ✅ |
| T10 | One Podfile change + gate | ✅ |
| T11 | Validation record | ✅ |

### Check 2: Diagram vs `Depends on`

| Task | Depends on (definition) | Diagram | Match |
| --- | --- | --- | --- |
| T1 | HF-1, EXT-1 | HF-1 → T1, EXT-1 → T1 | ✅ |
| T2 | T1 | T1 → T2 | ✅ |
| T3 | T2 | T2 → T3 | ✅ |
| T4 | T3 | T3 → T4 | ✅ |
| T5 | T2 | T2 → T5 | ✅ |
| T6 | T4, T5 | T4 → T6, T5 → T6 | ✅ |
| T7 | T6 | T6 → T7 | ✅ |
| T8 | none | [P] independent | ✅ |
| T9 | T5, T6 | T5, T6 → T9 | ✅ |
| T10 | T7, T8, T9, EXT-2 | T7, T8, T9, EXT-2 → T10 | ✅ |
| T11 | T10 | T10 → T11 | ✅ |

### Check 3: Test co-location

| Task | Layer | Required | In task | Result |
| --- | --- | --- | --- | --- |
| T1 | Podspec/Podfile | build | build in 3 linkages | ✅ |
| T2 | iOS adapter seam | XCTest via fake (pass-through) | covered by T3-T5 fakes; build gate | ✅ |
| T3 | iOS adapter | XCTest | `NottiImplAdapterTests` | ✅ |
| T4 | iOS adapter | XCTest | `NottiImplEventTests` | ✅ |
| T5 | iOS adapter | XCTest | `NottiLegacyIntegrationTests` | ✅ |
| T6 | deletion | existing tests + build | quick + build | ✅ |
| T7 | CI | parse + run | workflow run | ✅ |
| T8 | plugin (TS) | Jest if changed | JS gate | ✅ |
| T9 | docs | none | lint | ✅ |
| T10 | all | full | full gate | ✅ |
| T11 | runtime | manual | `validation.md` | ✅ |

---

## Requirement coverage

| ID | Tasks |
| --- | --- |
| NSDK-01 | T1, T6 |
| NSDK-02 | T2, T3 |
| NSDK-03 | T2, T3 (needs EXT-1) |
| NSDK-04 | T3 |
| NSDK-05 | T4 |
| NSDK-06 | T4 |
| NSDK-07 | T4 |
| NSDK-08 | T11 |
| NSDK-09 | T11 |
| NSDK-10 | design.md analysis, T11 |
| NSDK-11 | T5, T9, T11 |
| NSDK-12 | T5, T11 |
| NSDK-13 | T1, T9 |
| NSDK-14 | T8 |
| NSDK-15 | T9 |
| NSDK-16 | T7, T10, T11 |
| NSDK-17 | T2 |
| NSDK-18 | T1, T11 |
| NSDK-19 | T6 |
| NSDK-20 | T7, T10 |
| NSDK-21 | T1, T6, T11 |

**Coverage:** 21 total, 21 mapped, 0 unmapped.

---

## Deviations from this plan (implementation, 2026-11-05)

- **T1** uses the `:path` development override to the sibling `zeep-notti-ios-sdk` checkout at tag `0.2.0` (as the task says). It stays in `example/ios/Podfile` until T10, so `pod install` and the iOS CI jobs cannot pass on a clean checkout before `NottiSDK` 0.2.0 is on the trunk.
- **T2** seam carries its own `NottiNativeNotification`, `NottiNativeInAppClick` and `NottiNativeSubscription` types: the SDK's payload and subscription initializers are internal, so a test fake could not build them.
- **T2/T3** the seam is split in two files, `NottiNativeSDK.swift` (protocol and types) and `DefaultNottiNativeSDK.swift` (the `NottiSDK` pass-through). `NottiTests` is a hostless bundle that compiles `ios/` sources directly and has no `NottiSDK` module, so `ios/Tests/DefaultNottiNativeSDKStub.swift` stands in for the default there. `ios/` therefore holds one file more than T6 listed.
- **T3/T4/T5** new test files are registered in `NottiExample.xcodeproj` by hand (minimal insertions); regenerating the project reserializes it.
- **T3** removed four `NottiInAppWiringTests` cases that covered the old `initialize` wiring.
- **T5** `NottiPushDelegate.shared` no longer starts the old network observer.
