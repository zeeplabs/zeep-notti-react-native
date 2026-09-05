# SDK Core v1 Tasks

## Execution Protocol (MANDATORY — do not skip)

Implement these tasks with the `tlc-spec-driven` skill: **activate it by name and follow its Execute flow and Critical Rules.** Do not search for skill files by filesystem path. The skill is the source of truth for the full flow (per-task cycle, sub-agent delegation, adequacy review, Verifier, discrimination sensor).

**If the skill cannot be activated, STOP and tell the user — do not proceed without it.**

---

**Design**: `.specs/features/sdk-core-v1/design.md`
**Status**: Approved

---

## Test Coverage Matrix

> Generated from codebase sampling + spec. Guidelines found: `AGENTS.md` does not exist yet in this repo; `.github/workflows/ci.yml` defines `lint`, `typecheck`, `test` (jest), `build-library`, `build-android`, `build-ios` jobs — used as the gate-command source of truth. No Android (`android/src/test`) or iOS (XCTest target) test infrastructure exists yet in the scaffold — created as part of the first task that needs it (T5, T11), using the ecosystem-standard approach for each (JUnit4 + OkHttp `MockWebServer` on Android, XCTest + `URLProtocol` stubbing on iOS) since no existing native test sample exists to infer style from.

| Code Layer | Required Test Type | Coverage Expectation | Location Pattern | Run Command |
| --- | --- | --- | --- | --- |
| Android business logic (`NuntisCore`, `NuntisApiClient`, `NuntisDeviceStore`, pure parsing functions) | unit (JUnit4) | All branches; 1:1 to spec ACs SDK-01–19 (Android-applicable subset); every listed Edge Case has a test | `android/src/test/java/com/nuntis/*Test.kt` | `cd example/android && ./gradlew :react-native-nuntis:testDebugUnitTest` |
| iOS business logic (`NuntisCore`, `NuntisApiClient`, `NuntisDeviceStore`, pure parsing functions) | unit (XCTest) | All branches; 1:1 to spec ACs SDK-01–19 (iOS-applicable subset); every listed Edge Case has a test | `ios/Tests/*Tests.swift` | `xcodebuild test -workspace example/ios/NuntisExample.xcworkspace -scheme NuntisTests -destination 'platform=iOS Simulator,name=iPhone 16'` |
| TurboModule thin entry (`NuntisModule.kt`, `Nuntis.swift`) | none (wiring only, exercised transitively by the business-logic tests above via manual construction) | build gate only | `android/src/main/java/com/nuntis/NuntisModule.kt`, `ios/Nuntis.swift` | `pnpm run build:android` / `pnpm run build:ios` (Turbo pipeline tasks already wired in `package.json`/`turbo.json`) |
| TS facade (`src/index.tsx`, `src/NativeNuntis.ts`) | unit (Jest) | 1:1 to public API surface (every exported method/listener has at least one test); mirrors existing `src/__tests__/index.test.tsx` pattern | `src/__tests__/*.test.tsx` | `pnpm test` |
| Config (Expo plugin, `AndroidManifest.xml`, `Info.plist`, CI files) | none | build gate only | `plugin/`, `android/src/main/AndroidManifest.xml`, `ios/`, `.github/` | `pnpm typecheck && pnpm lint` + CI build jobs |

## Gate Check Commands

> Generated from `.github/workflows/ci.yml` and `package.json` scripts, converted to `pnpm` (CI currently still invokes `yarn` — fixed by T1 below).

| Gate Level | When to Use | Command |
| --- | --- | --- |
| Quick | After a TS-only task (facade, Spec) | `pnpm typecheck && pnpm lint && pnpm test` |
| Native-quick | After an Android-only or iOS-only business-logic task | `cd example/android && ./gradlew :react-native-nuntis:testDebugUnitTest` (Android) or the `xcodebuild test` command above (iOS) |
| Full | After a task touching both a native module and its TS Spec | Quick + Native-quick for the platform(s) touched |
| Build | After phase completion, or a config/wiring-only task | `pnpm typecheck && pnpm lint && pnpm test && pnpm run build:android && pnpm run build:ios` (mirrors CI's four jobs) |

---

## Execution Plan

Phases are ordered and run sequentially — each phase completes before the next begins, and tasks within a phase execute in order.

### Phase 1: Foundation

```
T2 -> T3
```

(T1 and T4 have no intra-phase dependencies — they run in document order but depend on nothing within this phase.)

### Phase 2: Android native core

```
T5 -> T6
T5 -> T7
T6 -> T7
T7 -> T8
T7 -> T9
T8 -> T9
T8 -> T10
T9 -> T10
```

### Phase 3: iOS native core

```
T11 -> T12
T11 -> T13
T12 -> T13
T13 -> T14
T14 -> T15
```

### Phase 4: TS facade, events, Expo plugin

(T16 and T17 have no intra-phase dependencies on each other — both depend only on earlier-phase tasks.)

### Phase 5: Example integration and docs

```
T18 -> T19
```

---

## Task Breakdown

### T1: Fix CI and setup action to use pnpm instead of stale yarn references

**What**: `.github/actions/setup/action.yml` and `.github/workflows/ci.yml` still invoke `yarn` and cache `yarn.lock`/`.yarn/install-state.gz` — leftover from the scaffold before the pnpm conversion; CI is currently broken (no `yarn.lock` exists). Replace with `pnpm install --frozen-lockfile`, cache keyed on `pnpm-lock.yaml`, and `pnpm`-prefixed script invocations throughout.
**Where**: `.github/actions/setup/action.yml`, `.github/workflows/ci.yml`
**Depends on**: None
**Reuses**: existing job/step structure, only the package-manager invocations change
**Requirement**: N/A (infra fix, not a spec AC)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `action.yml` installs/caches via pnpm, no `yarn` reference remains
- [x] `ci.yml`'s `lint`/`test`/`build-library`/`build-android`/`build-ios` jobs invoke `pnpm`-prefixed commands
- [x] A local dry-run of each changed command (`pnpm install --frozen-lockfile`, `pnpm lint`, `pnpm typecheck`, `pnpm test`) succeeds

**Tests**: none
**Gate**: build

**Status**: ✅ Complete

**Commit**: `chore(ci): convert CI and setup action from yarn to pnpm`

---

### T2: Research spike — Swift Turbo Module Codegen bridging (AD-002, part 1)

**What**: Determine, via official React Native docs/source (Context7 MCP first, web search fallback — never fabricate), the correct way to implement a Turbo Module's native class in Swift under the current scaffold's RN version (`0.85.0`), given the scaffold only generated an Objective-C++ (`Nuntis.mm`/`Nuntis.h`) bridge. Prove it with a minimal spike: convert the existing placeholder `multiply` implementation to Swift and get it building and callable from the example app. Record the confirmed mechanism in `design.md`'s "iOS APNs delegate hooks" component and update `.specs/STATE.md` AD-002 (resolve as active-confirmed, or supersede with a new AD-NNN if Swift bridging proves impractical).
**Where**: `ios/` (spike files, kept if the mechanism is confirmed working), `.specs/features/sdk-core-v1/design.md`, `.specs/STATE.md`
**Depends on**: None
**Reuses**: existing `ios/Nuntis.h`/`ios/Nuntis.mm` scaffold as the starting point
**Requirement**: N/A (spike backing AD-002)

**Tools**:
- MCP: `context7` (resolve React Native library docs)
- Skill: NONE

**Done when**:
- [x] The `multiply` TurboModule method is reimplemented in Swift and the example app's iOS build succeeds (`xcodebuild`/`pod install` actually run, not just typecheck)
- [x] The example app calling `NativeNuntis.multiply(2, 3)` still returns `6` from the Swift implementation (verified by the arithmetic delegating unchanged into `NuntisImpl.multiply`; full runtime UI launch not separately captured — see commit note)
- [x] `design.md` and `.specs/STATE.md` AD-002 updated with the confirmed mechanism (or a superseding decision if Swift proved impractical)

**Tests**: none (spike)
**Gate**: build (`pnpm run build:ios` must actually succeed on a real Xcode build, not a dry run)

**Status**: ✅ Complete

**Commit**: `feat(ios): confirm Swift Turbo Module bridging via spike (AD-002)`

---

### T3: Research spike — iOS APNs delegate wiring approach (AD-002, part 2)

**What**: Determine, via official Apple/React Native community docs (Context7/web search, never fabricate), whether the SDK can register for APNs callbacks (`didRegisterForRemoteNotificationsWithDeviceToken`, `UNUserNotificationCenterDelegate`) via method swizzling (OneSignal's real approach — zero integrator `AppDelegate` code) or whether it requires the host app to forward calls from its own `AppDelegate`. Record the confirmed approach in `design.md`'s "iOS APNs delegate hooks" component.
**Where**: `.specs/features/sdk-core-v1/design.md`
**Depends on**: T2 (same spike area, avoids re-deriving Swift/ObjC interop context)
**Reuses**: n/a
**Requirement**: N/A (spike backing AD-002)

**Tools**:
- MCP: `context7`
- Skill: NONE

**Done when**:
- [x] `design.md`'s iOS APNs delegate hooks component states the confirmed wiring approach and cites the source (doc URL or Context7 resolution) it was confirmed against
- [x] If swizzling is confirmed impractical/unsafe for this RN version, the integrator-facing `AppDelegate` forwarding requirement is written down as the fallback plan before Phase 3 starts building against it

**Tests**: none (spike, doc-only output)
**Gate**: none (no code produced)

**Status**: ✅ Complete

**Commit**: `docs(ios): confirm APNs delegate wiring approach (AD-002)`

---

### T4: Define the full `NativeNuntis` TurboModule TS Spec

**What**: Replace the scaffolded `multiply(a, b)` placeholder in `src/NativeNuntis.ts` with the real v1 Spec surface: `initialize(appId, clientKey)`, `requestPermission(): Promise<boolean>`, `login(externalUserId)`, `logout()`, `addTags(tags)`, `removeTags(keys)`, `setSubscription(enabled)`, plus Codegen-declared events `onNotificationReceived`/`onNotificationClicked` carrying a `NotificationPayload` (design.md Data Models).
**Where**: `src/NativeNuntis.ts`
**Depends on**: None (can run in parallel with T1–T3; sequenced here for phase tidiness since Phase 2/3's module-entry tasks T8/T14 need it)
**Reuses**: scaffolded `TurboModuleRegistry.getEnforcing<Spec>('Nuntis')` pattern
**Requirement**: SDK-01, SDK-08, SDK-12, SDK-13, SDK-14, SDK-15, SDK-16, SDK-17, SDK-18

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `Spec` interface includes every v1 method and event listed above with correct TS types
- [x] Codegen runs cleanly (`pnpm typecheck` passes, no Codegen errors on `pnpm run build:android`/`build:ios` dry invocation)
- [x] No leftover reference to `multiply` in the Spec file

**Tests**: none (type-only interface; exercised indirectly once T16 writes the facade tests)
**Gate**: quick

**Status**: ✅ Complete

**Commit**: `feat(sdk): define full NativeNuntis TurboModule spec`

---

### T5: `NuntisDeviceStore.kt` — persisted device state + tag-merge logic

**What**: Implement `SharedPreferences`-backed storage for `deviceId`, `lastToken`, `tags`, `externalUserId`, `subscribed` (design.md `DeviceState`), plus a pure `mergeTags(current, add, remove): Map<String,String>` function. Create the `android/src/test/java/com/nuntis/` unit test source set (does not exist yet) with JUnit4.
**Where**: `android/src/main/java/com/nuntis/NuntisDeviceStore.kt`, `android/src/test/java/com/nuntis/NuntisDeviceStoreTest.kt`, `android/build.gradle` (add `testImplementation "junit:junit:4.13.2"` and enable the test task)
**Depends on**: None
**Reuses**: n/a (new)
**Requirement**: SDK-12, SDK-13 (tag-merge semantics)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `mergeTags` correctly adds, removes, and handles overlapping add+remove of the same key in one call (last-operation-wins within the call, matching spec P3-AC8's serialization assumption)
- [x] Persisted fields round-trip through `SharedPreferences` correctly, including the empty/never-initialized state
- [x] `./gradlew testDebugUnitTest` passes
- [x] Test count: at least 6 tests (empty state, add, remove, add+remove overlap, persistence round-trip, external-id/subscribed round-trip)

**Tests**: unit
**Gate**: native-quick

**Commit**: `feat(android): add NuntisDeviceStore with tag-merge logic`

**Status**: ✅ Complete

**Deviation note**: `android/` has no standalone `gradlew` (library modules in this scaffold build only via the example app's Gradle project). The real gate command used: `cd example/android && ./gradlew :react-native-nuntis:testDebugUnitTest` (module name from Gradle autolinking). `tasks.md`'s literal `cd example/android && ./gradlew :react-native-nuntis:testDebugUnitTest` does not exist as a runnable command in this repo. Also required forcing `example/node_modules -> ../node_modules` locally (this repo's `.npmrc` sets `node-linker=hoisted`, but `example/android/settings.gradle` resolves the RN Gradle plugin via a relative `../node_modules` path) — a local, untracked workaround, not a repo change.

---

### T6: `NuntisApiClient.kt` — Nuntis device registration HTTP client with retry

**What**: OkHttp-based client implementing `createOrUpdateDevice` (`POST /v1/apps/{appId}/devices`) and `patchDevice` (`PATCH /v1/apps/{appId}/devices/{id}`, always including the cached `token` per AD-009), with exponential backoff per design.md's Tech Decisions (2s base, ×2, capped at 5 attempts). Use `MockWebServer` to simulate success, 5xx, and network-failure responses.
**Where**: `android/src/main/java/com/nuntis/NuntisApiClient.kt`, `android/src/test/java/com/nuntis/NuntisApiClientTest.kt`, `android/build.gradle` (add `testImplementation "com.squareup.okhttp3:mockwebserver:4.12.0"`)
**Depends on**: T5 (shares the test source-set setup)
**Reuses**: OkHttp (already a transitive `react-native` dependency)
**Requirement**: SDK-01, SDK-05, SDK-06

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `POST` sends the correct body/headers (`Authorization: Bearer {clientKey}`, `{token, platform}`)
- [x] `PATCH` always includes the `token` field
- [x] On a 5xx or network failure, the client retries exactly per the 2/4/8/16/32s schedule, capped at 5 attempts, then surfaces a terminal failure
- [x] A successful response before the retry cap stops further retries
- [x] `./gradlew testDebugUnitTest` passes
- [x] Test count: at least 6 tests (POST success, PATCH success+token field, 5xx retry-then-succeed, retry-cap-exhausted, network-error path, request header/body shape)

**Tests**: unit
**Gate**: native-quick

**Commit**: `feat(android): add NuntisApiClient with retry backoff`

**Status**: ✅ Complete (gate run via `cd example/android && ./gradlew :react-native-nuntis:testDebugUnitTest`, same deviation note as T5)

---

### T7: `NuntisCore.kt` — orchestration, init, permission, mutation queue

**What**: Orchestrates `initialize` (no-op on repeat identical calls), `registerDevice`/`onTokenRefreshed`, `requestPermission` → `PATCH {subscribed}`, `mutateTags`/`setExternalUserId`/`setSubscription` serialized one-in-flight-at-a-time (spec P3-AC8), and the crash-safety edge cases (missing `appId`/`clientKey` logs and no-ops, missing push prerequisite logs and no-ops). Depends on `NuntisApiClient`/`NuntisDeviceStore` via constructor injection so both can be faked in tests.
**Where**: `android/src/main/java/com/nuntis/NuntisCore.kt`, `android/src/test/java/com/nuntis/NuntisCoreTest.kt`
**Depends on**: T5, T6
**Reuses**: `NuntisApiClient`, `NuntisDeviceStore`
**Requirement**: SDK-01, SDK-02, SDK-03, SDK-04, SDK-05, SDK-06, SDK-07, SDK-08, SDK-09, SDK-10, SDK-11, SDK-19

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `initialize` with missing/empty `appId`/`clientKey` logs and does not call the API client (SDK-03)
- [x] Repeat `initialize` calls with identical args are a no-op (SDK-07)
- [x] `requestPermission` grant/deny paths call `patchDevice` with the correct `subscribed` value (SDK-09, SDK-10)
- [x] `requestPermission` called before any `initialize` logs and does not prompt (Edge Case)
- [x] Two rapid tag-mutation calls serialize (second waits for the first's API call to resolve) and the final persisted state reflects the net merged result (SDK-19/P3-AC8)
- [x] `./gradlew testDebugUnitTest` passes
- [x] Test count: at least 9 tests (one per Done-when bullet above, plus a happy-path init→register test)

**Tests**: unit
**Gate**: native-quick

**Commit**: `feat(android): add NuntisCore orchestration layer`

**Status**: ✅ Complete (10 tests). SDK-05 retry-backoff behavior is exercised at `NuntisApiClientTest.kt` (T6), not retested here. SDK-11 (Android <13 auto-grant) is delegated to the concrete `permissionRequester` implementation T8 wires in — out of `NuntisCore`'s own layer, so not tested at this level; flagged, not silently skipped.

---

### T8: `NuntisModule.kt` — thin TurboModule entry wired to `NuntisCore`

**What**: Replace the scaffolded `multiply` implementation with the real Spec methods (from T4), each delegating one line into a `NuntisCore` singleton/instance held by the module. No business logic in this class.
**Where**: `android/src/main/java/com/nuntis/NuntisModule.kt`
**Depends on**: T4, T7
**Reuses**: `NuntisCore`
**Requirement**: SDK-01 through SDK-19 (wiring only — logic already covered by T7's tests)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] Every Spec method from T4 has a corresponding one-line delegation in `NuntisModule`
- [x] `pnpm run build:android` succeeds (Codegen + Gradle compile)

**Tests**: none (thin wiring, exercised transitively by T7's tests against `NuntisCore` directly)
**Gate**: build

**Commit**: `feat(android): wire NuntisModule TurboModule entry to NuntisCore`

**Status**: ✅ Complete

**Deviations**:
1. `tokenProvider` is a temporary `{ null }` stub — the real FCM token fetch needs `com.google.firebase:firebase-messaging`, which T9 (not T8) adds as a dependency. `NuntisCore` already handles a null token safely (logs, no-ops, verified in T7), so this doesn't crash; auto-registration simply won't fire until T9 lands.
2. `NUNTIS_API_BASE_URL` is a placeholder (`https://api.nuntis.io`) — neither spec.md nor design.md specifies Nuntis' base host (`Nuntis.initialize` only takes `appId`/`clientKey`). Flagged for the orchestrator to confirm the real host before ship.
3. Real Android permission-request plumbing (`PermissionAwareActivity`/SDK_INT<33 auto-grant) was implemented here, since no other task in the plan owns it and NuntisCore's `permissionRequester` was designed (T7) to have this injected.
4. Blocking, pre-existing scaffold defects unrelated to any task's declared file scope, fixed here because they blocked the mandatory `pnpm run build:android` gate for T8 (and would have blocked it for every later Android build-gated task too): `example/android/app/build.gradle`'s `namespace`/`applicationId` was `"nuntisexample"` (no dot — invalid Android package id, failed manifest merge); fixed to `"com.nuntisexample"`. Also removed a stale `android/build/` directory left over from an earlier manual Codegen dry-run (T4), which was colliding with the example app's own CMake target names (`add_library` duplicate-target error) — not a repo file, gitignored, no commit impact.

---

### T9: `NuntisFirebaseMessagingService.kt` — token refresh + foreground message handling

**What**: `FirebaseMessagingService` subclass: `onNewToken` calls `NuntisCore.onTokenRefreshed`; `onMessageReceived` (foreground-only, per design.md's confirmed FCM notification-message behavior) parses the `RemoteMessage` into a `NotificationPayload` via a pure, unit-testable `parseRemoteMessage` function and emits the `onNotificationReceived` Codegen event. Register the service in `AndroidManifest.xml` and add the `com.google.firebase:firebase-messaging` dependency.
**Where**: `android/src/main/java/com/nuntis/NuntisFirebaseMessagingService.kt`, `android/src/test/java/com/nuntis/NuntisFirebaseMessagingServiceTest.kt` (tests `parseRemoteMessage` only — the service class itself needs an Android framework context and is exercised at Phase 5's example-app smoke test instead), `android/src/main/AndroidManifest.xml`, `android/build.gradle`
**Depends on**: T7, T8
**Reuses**: `NuntisCore.onTokenRefreshed`
**Requirement**: SDK-06 (token refresh path)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `parseRemoteMessage` correctly extracts `title`/`body`/`data` from a `RemoteMessage` fixture, including the no-notification-block (data-only) edge case
- [x] `onNewToken` calls into `NuntisCore` with the new token
- [x] Manifest registers the service with the correct intent-filter (`com.google.firebase.MESSAGING_EVENT`)
- [x] `./gradlew testDebugUnitTest` passes
- [x] Test count: at least 3 tests for `parseRemoteMessage`

**Tests**: unit (parsing function only, per Done-when)
**Gate**: native-quick

**Commit**: `feat(android): add FCM messaging service for token refresh and foreground receive`

**Status**: ✅ Complete (25 tests total in the module, 3 new for this task)

**Deviations**:
1. Added `org.robolectric:robolectric:4.14.1` as a test-only dependency, scoped via `@RunWith(RobolectricTestRunner::class)` to just `NuntisFirebaseMessagingServiceTest` - `RemoteMessage` is backed by `android.os.Bundle`, which is unmockable on the plain JVM without it. Not applied repo-wide.
2. `onNewToken` is not unit-tested directly (matches this task's own file-scope note: the service class needs a real Android framework context, exercised at Phase 5's example-app smoke test instead) - only the pure `parseRemoteMessage` function is unit-tested, per the Done-when bullet's own scoping.
3. Emitting the Codegen event required a small, necessary addition to `NuntisModule.kt` (not in this task's `Where` field): a static bridge (`activeInstance`/`activeCore` + `emitReceived`/`emitClicked`), since `NuntisFirebaseMessagingService` is a separate Android `Service`, not a `NuntisModule` subclass, and design.md's Tech Decisions rule out `RCTDeviceEventEmitter` as an alternative.

---

### T10: Android cold-start/background notification-click detection

**What**: Since `onMessageReceived` doesn't fire reliably outside the foreground (design.md Risk), detect a notification click that launched or resumed the Activity by reading the launch `Intent`'s extras (the same `data` keys FCM attaches to the system-tray notification's `PendingIntent`) in the module's Activity-lifecycle hook, parse them with a pure function (`parseClickIntentExtras`, mirrors T9's parsing pattern), and emit `onNotificationClicked`.
**Where**: `android/src/main/java/com/nuntis/NuntisModule.kt` (or a small dedicated `NuntisActivityLifecycleListener.kt` if the Activity-hook wiring doesn't fit cleanly in the module class — implementer's call, keep it one file either way), `android/src/test/java/com/nuntis/...` (parsing function test)
**Depends on**: T8, T9
**Reuses**: `parseRemoteMessage`'s pattern from T9 (same payload shape, different source object)
**Requirement**: SDK-18

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `parseClickIntentExtras` correctly extracts the same `NotificationPayload` shape from launch-`Intent` extras
- [x] The click path fires `onNotificationClicked` exactly once per actual notification tap (not on every unrelated Activity resume) — verified by the intent-extras presence check itself, not a heuristic
- [x] `./gradlew testDebugUnitTest` passes
- [x] Test count: at least 3 tests for `parseClickIntentExtras` (present extras, absent extras/unrelated launch, malformed data map)

**Tests**: unit
**Gate**: native-quick

**Commit**: `feat(android): detect notification clicks from cold-start/background launch intents`

**Status**: ✅ Complete (4 new tests; 29 total in the Android module). `pnpm run build:android` also re-verified green as this is the last Phase 2 task.

**Deviations**:
1. Implemented as a dedicated `NuntisActivityLifecycleListener.kt` (the task's own listed alternative), registered via `Application.ActivityLifecycleCallbacks` from `NuntisModule`'s `init` block (one line, forced touch, same pattern as T9's necessary `NuntisModule.kt` addition) — auto-wires cold-start/background click detection without requiring integrator code.
2. "Exactly once per tap" is enforced by clearing the handled `Intent`'s extras (`intent.replaceExtras(Bundle())`) after firing, so a subsequent `onActivityResumed` for the same Activity instance finds no `google.message_id` key and `parseClickIntentExtras` correctly returns null — the presence-check test is the actual evidence for this property, per the Done-when bullet's own wording.
3. The "unrelated launch" detection uses FCM's reserved `google.message_id` extra key (confirmed by inspecting the `firebase-messaging` AAR's `Constants.MessagePayloadKeys`) as the deterministic presence signal, not a heuristic.

---

### T11: `NuntisDeviceStore.swift` — persisted device state + tag-merge logic

**What**: iOS mirror of T5 — `UserDefaults`-backed storage for the same `DeviceState` fields, plus the same pure `mergeTags` function contract. Create the XCTest target (does not exist yet in the scaffold) under `ios/Tests/`.
**Where**: `ios/NuntisDeviceStore.swift`, `ios/Tests/NuntisDeviceStoreTests.swift`, `Nuntis.podspec` or `example/ios/NuntisExample.xcodeproj` test-target wiring (whichever the T2 spike determined is the correct place for iOS unit tests in this scaffold — verify, don't assume)
**Depends on**: T2, T3 (Swift bridging + APNs approach confirmed first — same interop context)
**Reuses**: n/a (new); mirrors T5's contract exactly (same field names, same `mergeTags` semantics) so the two platforms stay provably in sync per design.md's Risks & Concerns mitigation
**Requirement**: SDK-12, SDK-13

**Tools**:
- MCP: `context7` (only if the XCTest-target wiring mechanics from T2/T3 need clarifying further)
- Skill: NONE

**Done when**:
- [x] Same test scenario list as T5's `NuntisDeviceStoreTest.kt`, ported to XCTest (add/remove/overlap/persistence/empty-state — same scenarios, both platforms, per design.md's parallel-platform-test-matrix mitigation)
- [x] `xcodebuild test` (command from the coverage matrix) passes
- [x] Test count: at least 6 tests, matching T5's count

**Tests**: unit
**Gate**: native-quick

**Commit**: `feat(ios): add NuntisDeviceStore with tag-merge logic`

**Status**: ✅ Complete (6 tests)

**Deviation note**: No standalone `NuntisTests` XCTest scheme/target existed in the scaffold (`tasks.md`'s literal `xcodebuild test -workspace example/ios/NuntisExample.xcworkspace -scheme NuntisTests ...` referenced a scheme that did not exist yet). Rather than wire iOS unit tests through the CocoaPods `Nuntis` pod target (would require a podspec `test_spec` plus a matching explicit `pod 'Nuntis', :testspecs: ['Tests']` Podfile line, which conflicts with RN autolinking's own unconditional `pod name, :path => path` declaration for the same pod), a dedicated `NuntisTests` unit-test-bundle target was added directly to `example/ios/NuntisExample.xcodeproj` (via the `xcodeproj` Ruby gem CocoaPods already vendors) with no CocoaPods/module dependency: its Sources build phase compiles the same on-disk `ios/*.swift` business-logic files (not pod-linked, not `@testable import`) plus `ios/Tests/*.swift`, as a standalone logic-test bundle (no `TEST_HOST`/`BUNDLE_LOADER`). This is stable across `pod install` re-runs (only `Pods.xcodeproj` is regenerated, not the app project) and avoids all CocoaPods/module-linking complexity for pure-Foundation business logic. `xcodebuild -list` confirms the scheme exists; real command used matches the coverage matrix's shape with `-scheme NuntisTests -destination 'platform=iOS Simulator,name=iPhone 17'` (device name adjusted to what's actually available in this environment, mirrors the same class of correction Batch 1 made for Android's gate command).

---

### T12: `NuntisApiClient.swift` — Nuntis device registration HTTP client with retry

**What**: iOS mirror of T6 — `URLSession`-based client implementing the same `createOrUpdateDevice`/`patchDevice` contract and identical retry schedule (2/4/8/16/32s, capped at 5). Stub `URLSession` via a custom `URLProtocol` for success/5xx/network-failure scenarios.
**Where**: `ios/NuntisApiClient.swift`, `ios/Tests/NuntisApiClientTests.swift`
**Depends on**: T11 (shares the test-target setup)
**Reuses**: n/a (new); mirrors T6's contract exactly
**Requirement**: SDK-01, SDK-05, SDK-06

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] Same test scenario list as T6's `NuntisApiClientTest.kt` (POST success, PATCH success+token, 5xx retry-then-succeed, retry-cap-exhausted, network-error, request shape)
- [ ] `xcodebuild test` passes
- [ ] Test count: at least 6 tests, matching T6's count

**Tests**: unit
**Gate**: native-quick

**Commit**: `feat(ios): add NuntisApiClient with retry backoff`

---

### T13: `NuntisCore.swift` — orchestration, init, permission, mutation queue

**What**: iOS mirror of T7 — identical orchestration contract and crash-safety behavior.
**Where**: `ios/NuntisCore.swift`, `ios/Tests/NuntisCoreTests.swift`
**Depends on**: T11, T12
**Reuses**: `NuntisApiClient`, `NuntisDeviceStore` (iOS versions); mirrors T7's contract exactly
**Requirement**: SDK-01 through SDK-11, SDK-19

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] Same test scenario list as T7's `NuntisCoreTest.kt` (missing-config no-op, repeat-init no-op, permission grant/deny, requestPermission-before-initialize, tag-mutation serialization)
- [ ] `xcodebuild test` passes
- [ ] Test count: at least 9 tests, matching T7's count

**Tests**: unit
**Gate**: native-quick

**Commit**: `feat(ios): add NuntisCore orchestration layer`

---

### T14: `Nuntis.swift` — thin TurboModule entry wired to `NuntisCore`

**What**: iOS mirror of T8 — the Swift TurboModule entry class (mechanism confirmed by T2), delegating every Spec method one line into `NuntisCore`.
**Where**: `ios/Nuntis.swift` (replaces/supplements the `Nuntis.mm`/`Nuntis.h` scaffold per T2's confirmed bridging mechanism)
**Depends on**: T4, T13
**Reuses**: `NuntisCore`; T2's confirmed bridging pattern
**Requirement**: SDK-01 through SDK-19 (wiring only)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] Every Spec method from T4 has a corresponding one-line delegation
- [ ] `pnpm run build:ios` succeeds (real Xcode build)

**Tests**: none (thin wiring, exercised transitively by T13's tests)
**Gate**: build

**Commit**: `feat(ios): wire Nuntis TurboModule entry to NuntisCore`

---

### T15: iOS APNs delegate hooks + notification-click detection

**What**: Implement the APNs registration/receive/click callbacks per T3's confirmed wiring approach (swizzling or `AppDelegate`-forwarding fallback): `didRegisterForRemoteNotificationsWithDeviceToken` → `NuntisCore.onTokenRefreshed`; `UNUserNotificationCenterDelegate`'s `willPresent` (foreground receive) and `didReceive response` (click, any app state) → parse via a pure `parseUserInfo` function (mirrors Android's T9/T10 pattern) and emit the corresponding Codegen event.
**Where**: `ios/` (exact file per T3's confirmed approach), `ios/Tests/...` (parsing function tests)
**Depends on**: T3, T14
**Reuses**: T3's confirmed wiring mechanism; mirrors Android's T9+T10 payload-parsing pattern
**Requirement**: SDK-06, SDK-17, SDK-18

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `parseUserInfo` correctly extracts the same `NotificationPayload` shape from `UNNotification.request.content.userInfo`
- [ ] Foreground receive fires `onNotificationReceived`; any-state click fires `onNotificationClicked`
- [ ] `xcodebuild test` passes for the parsing function
- [ ] Test count: at least 3 tests

**Tests**: unit
**Gate**: native-quick

**Commit**: `feat(ios): add APNs delegate hooks and click detection`

---

### T16: `src/index.tsx` facade — public API surface

**What**: Replace the scaffolded `export { multiply }` with the real public API: `Nuntis.initialize`, `Nuntis.requestPermission`, `Nuntis.User.addTag`/`addTags`/`removeTag`/`removeTags`, `Nuntis.login`/`logout`, `Nuntis.setSubscription`, `Nuntis.addEventListener('notificationReceived' | 'notificationClicked', callback)` — each a thin call into `NativeNuntis` (T4's Spec), with the event listeners wrapping the Codegen-declared native events into a plain callback-registration API.
**Where**: `src/index.tsx`, `src/__tests__/index.test.tsx` (replaces the scaffolded `multiply` test)
**Depends on**: T4
**Reuses**: existing `src/__tests__/index.test.tsx` jest pattern already in the scaffold
**Requirement**: SDK-01, SDK-08, SDK-12 through SDK-18

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] Every public method/listener above exists and calls the correct `NativeNuntis` method (verified by mocking `NativeNuntis` in tests, standard RN jest pattern)
- [ ] `addTag`/`addTags` and `removeTag`/`removeTags` both funnel into the Spec's `addTags`/`removeTags` (single-key convenience wrappers around the plural form)
- [ ] `pnpm test` passes
- [ ] Test count: at least 9 tests (one per public method/listener)

**Tests**: unit
**Gate**: quick

**Commit**: `feat(sdk): implement public facade API in src/index.tsx`

---

### T17: Expo config plugin

**What**: A `withNuntis` Expo config plugin (`plugin/src/withNuntis.ts`, built to `plugin/build/`) that, on `expo prebuild`, wires the Android FCM manifest service registration (already static per T9, but the plugin ensures `google-services.json` is placed and the Google Services Gradle plugin applied) and the iOS push-notification capability/entitlement — so Expo (dev client/prebuild) integrators don't hand-edit native project files, matching the bare-RN integrator's manual steps documented in T19's README.
**Where**: `plugin/src/withNuntis.ts`, `plugin/package.json` or root `package.json` `"app.plugin.js"` entry (per Expo config-plugin convention), `app.plugin.js`
**Depends on**: T9, T15 (needs the confirmed native wiring both platforms require)
**Reuses**: `@expo/config-plugins` (standard dependency for this exact purpose)
**Requirement**: N/A (packaging goal from spec.md's Goals, not a numbered AC)

**Tools**:
- MCP: `context7` (resolve `@expo/config-plugins` current API before writing modifier code — don't assume the API shape)
- Skill: NONE

**Done when**:
- [ ] Plugin adds the Google Services Gradle plugin + `google-services.json` reference on Android
- [ ] Plugin adds the push-notification entitlement/capability on iOS
- [ ] `pnpm typecheck` and `pnpm lint` pass on the new plugin code

**Tests**: none (config-mutation script, per coverage matrix)
**Gate**: build

**Commit**: `feat(plugin): add Expo config plugin for Nuntis push setup`

---

### T18: Wire the example app for manual end-to-end smoke testing

**What**: Update `example/src/App.tsx` to call `Nuntis.initialize`/`requestPermission`/`addTags`/etc. against a real (developer-provided, not committed) Nuntis App's Client key, and add the placeholder native config the example needs (a `.gitignore`d `google-services.json` slot, iOS push capability in the example's `Info.plist`) so a developer can manually verify device registration against a running Nuntis instance before release.
**Where**: `example/src/App.tsx`, `example/android/app/`, `example/ios/NuntisExample/Info.plist`, `.gitignore` (ensure no real credentials get committed)
**Depends on**: T16, T17
**Reuses**: existing example app scaffold
**Requirement**: N/A (manual-verification support, spec's Independent Test lines for P1/P2/P3)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] Example app builds for both platforms (`pnpm run build:android`, `pnpm run build:ios`)
- [ ] No real credentials/keys committed (`.gitignore` covers the local-only config slot)
- [ ] Manual run against a local Nuntis instance shows a new Device row created (recorded as a note in the task's completion, not an automated test)

**Tests**: none (example app, manual verification)
**Gate**: build

**Commit**: `feat(example): wire example app for manual SDK smoke testing`

---

### T19: README quickstart and integration docs

**What**: Document the public API (T16), Android/iOS manual setup steps for bare RN (per T3/T9/T15's confirmed mechanisms), and the Expo path (per T17), including the explicit prerequisites the SDK cannot provision itself (host app's own `google-services.json`, APNs capability/entitlement) per design.md's Error Handling Strategy.
**Where**: `README.md`
**Depends on**: T17, T18
**Reuses**: n/a
**Requirement**: N/A (docs)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] Every public method from T16 is documented with a usage example
- [ ] Bare-RN and Expo setup paths are both documented, including the confirmed APNs wiring requirement from T3
- [ ] `pnpm typecheck && pnpm lint && pnpm test && pnpm run build:android && pnpm run build:ios` all pass (final repo-wide sanity check)

**Tests**: none
**Gate**: build

**Commit**: `docs: add SDK quickstart and integration guide`

---

## Phase Execution Map

Phases run in order: Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5. Within each phase, tasks execute in document order. Every dependency edge declared anywhere in the Task Breakdown (`Depends on:`) is listed below, one per line, so this map is the single complete cross-check source (both same-phase and cross-phase edges — a task never depends on a later-phase task, verified in the Diagram-Definition Cross-Check table):

```
T2 -> T3
T5 -> T6
T5 -> T7
T6 -> T7
T7 -> T8
T7 -> T9
T8 -> T9
T8 -> T10
T9 -> T10
T2 -> T11
T3 -> T11
T11 -> T12
T11 -> T13
T12 -> T13
T4 -> T14
T13 -> T14
T3 -> T15
T14 -> T15
T4 -> T16
T9 -> T17
T15 -> T17
T16 -> T18
T17 -> T18
T17 -> T19
T18 -> T19
T4 -> T8
```

Execution is strictly sequential — there is no intra-phase parallelism. A single agent (or batch worker) works one task at a time, in order.

---

## Task Granularity Check

| Task | Scope | Status |
| --- | --- | --- |
| T1: Fix CI/setup to pnpm | 2 files, 1 concept | ✅ Granular |
| T2: Swift bridging spike | 1 concept (spike + minimal proof) | ✅ Granular |
| T3: APNs wiring spike | 1 concept (research + doc) | ✅ Granular |
| T4: TS Spec definition | 1 file | ✅ Granular |
| T5: Android DeviceStore | 1 component + its test | ✅ Granular |
| T6: Android ApiClient | 1 component + its test | ✅ Granular |
| T7: Android Core | 1 component + its test | ✅ Granular |
| T8: Android Module wiring | 1 file | ✅ Granular |
| T9: Android FCM service | 1 component + its test | ✅ Granular |
| T10: Android click detection | 1 concept (parsing fn + wiring) | ✅ Granular |
| T11: iOS DeviceStore | 1 component + its test | ✅ Granular |
| T12: iOS ApiClient | 1 component + its test | ✅ Granular |
| T13: iOS Core | 1 component + its test | ✅ Granular |
| T14: iOS Module wiring | 1 file | ✅ Granular |
| T15: iOS APNs hooks | 1 concept (delegate hooks + parsing fn) | ✅ Granular |
| T16: TS facade | 1 file + its test | ✅ Granular |
| T17: Expo config plugin | 1 component | ✅ Granular |
| T18: Example app wiring | 1 concept (example integration) | ✅ Granular |
| T19: README docs | 1 file | ✅ Granular |

---

## Diagram-Definition Cross-Check

| Task | Depends On (task body) | Diagram Shows | Status |
| --- | --- | --- | --- |
| T1 | None | (start of Phase 1, no incoming arrow) | ✅ Match |
| T2 | None | T1 → T2 (phase-order arrow) | ✅ Match |
| T3 | T2 | T2 → T3 | ✅ Match |
| T4 | None | T3 → T4 (phase-order arrow) | ✅ Match |
| T5 | None | (start of Phase 2, no incoming arrow) | ✅ Match |
| T6 | T5 | T5 → T6 | ✅ Match |
| T7 | T5, T6 | T6 → T7 | ✅ Match |
| T8 | T4, T7 | T7 → T8 | ✅ Match |
| T9 | T7, T8 | T8 → T9 | ✅ Match |
| T10 | T8, T9 | T9 → T10 | ✅ Match |
| T11 | T2, T3 | (start of Phase 3, no incoming arrow) | ✅ Match |
| T12 | T11 | T11 → T12 | ✅ Match |
| T13 | T11, T12 | T12 → T13 | ✅ Match |
| T14 | T4, T13 | T13 → T14 | ✅ Match |
| T15 | T3, T14 | T14 → T15 | ✅ Match |
| T16 | T4 | (start of Phase 4, no incoming arrow) | ✅ Match |
| T17 | T9, T15 | T16 → T17 | ✅ Match |
| T18 | T16, T17 | (start of Phase 5, no incoming arrow) | ✅ Match |
| T19 | T17, T18 | T18 → T19 | ✅ Match |

No task depends on a later-phase task — all cross-phase dependencies (T8→T4, T11→T2/T3, T14→T4, T17→T9/T15, T19→T17) point backward only.

---

## Test Co-location Validation

| Task | Code Layer Created/Modified | Matrix Requires | Task Says | Status |
| --- | --- | --- | --- | --- |
| T1 | Config (CI) | none | none | ✅ OK |
| T2 | Config/spike (iOS) | none | none | ✅ OK |
| T3 | Docs/spike | none | none | ✅ OK |
| T4 | TS Spec (interface only) | none (type-only) | none | ✅ OK |
| T5 | Android business logic | unit | unit | ✅ OK |
| T6 | Android business logic | unit | unit | ✅ OK |
| T7 | Android business logic | unit | unit | ✅ OK |
| T8 | Android TurboModule entry | none (wiring) | none | ✅ OK |
| T9 | Android business logic (parsing fn) + config (manifest/service) | unit (parsing fn) | unit | ✅ OK |
| T10 | Android business logic (parsing fn) | unit | unit | ✅ OK |
| T11 | iOS business logic | unit | unit | ✅ OK |
| T12 | iOS business logic | unit | unit | ✅ OK |
| T13 | iOS business logic | unit | unit | ✅ OK |
| T14 | iOS TurboModule entry | none (wiring) | none | ✅ OK |
| T15 | iOS business logic (parsing fn) + config (delegate wiring) | unit (parsing fn) | unit | ✅ OK |
| T16 | TS facade | unit | unit | ✅ OK |
| T17 | Config (Expo plugin) | none | none | ✅ OK |
| T18 | Config (example app) | none | none | ✅ OK |
| T19 | Docs | none | none | ✅ OK |

No violations — every business-logic task carries unit tests co-located in the same task; every wiring/config/docs-only task correctly claims `none` per the coverage matrix.
