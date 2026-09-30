# Segment Telemetry Reporting Tasks

**Design**: `.specs/features/segment-telemetry-reporting/design.md`
**Status**: In Design — tasks drafted, pending approval. Execute not started.

---

## Test Coverage Convention (no `.specs/codebase/TESTING.md` yet — derived from `CONTRIBUTING.md`)

| Code layer | Test type | Command | Evidence |
| --- | --- | --- | --- |
| Android native (Kotlin, `android/src/main`) | JVM unit test (`android/src/test`) | `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest` | `CONTRIBUTING.md` "Native tests"; `android/src/test/java/com/notti/*Test.kt` |
| iOS native (Swift, `ios/`) | XCTest (`ios/Tests`) | `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'` | `CONTRIBUTING.md`; `ios/Tests/*.swift` |
| TS facade (`src/`) | Jest | `pnpm test` (+ `pnpm typecheck`, `pnpm lint`) | `src/__tests__/index.test.tsx` |

Unlike `ctr-event-reporting` (which touched only native layers), **this feature DOES touch `src/`** — P3's
`setLocationSharingEnabled` is the single deliberate `AD-001` exception (SEGTEL-10). So the JS gate
(`pnpm test`/`pnpm typecheck`/`pnpm lint`) is part of T1's gate, and the JS sanity trio runs again in
T10. Native-only tasks (T2-T9) gate on their platform's command only.

**Gate check commands**:
- Android `quick`/`full` (same command): `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- iOS `quick`/`full` (same command): `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- JS `quick`/`full` (T1 and T10 only): `pnpm typecheck && pnpm lint && pnpm test`

---

## Execution Plan

### Phase 1: JS surface first (single shared file, must land before native overrides compile against codegen)

```
T1 (JS Spec + facade)   ← sequential prerequisite
```

### Phase 2: Platform-parallel foundation (Android and iOS never touch the same file — parallel across platforms; within a platform, sequential because later tasks build on earlier ones in the same files)

```
Android: T2 ──→ T3 ──→ T4 ──→ T5
iOS:     T6 ──→ T7 ──→ T8 ──→ T9
```

### Phase 3: Cross-cutting review

```
(T1..T9 complete) ──→ T10
```

---

## Task Breakdown

### T1: JS — `setLocationSharingEnabled` Spec + facade

**What**: The one JS-visible API of this feature (deliberate `AD-001` exception, SEGTEL-10): add `setLocationSharingEnabled(enabled: boolean): void` to the codegen Spec and expose it on the `Notti` default export, following the exact `setSubscription` mould.
**Where**: `src/NativeNotti.ts` (modify: add to `Spec` interface), `src/index.tsx` (modify: add facade function + export on `Notti` object)
**Depends on**: None
**Reuses**: `setSubscription` pattern (verb-first camelCase, void, no Promise), the `Spec`→facade→export chain
**Requirement**: SEGTEL-10 (JS-visible toggle surface)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `Spec.setLocationSharingEnabled(enabled: boolean): void` declared in `src/NativeNotti.ts` (positioned with the other setters, after `setSubscription`)
- [ ] `function setLocationSharingEnabled(enabled: boolean): void { NativeNotti.setLocationSharingEnabled(enabled); }` added to `src/index.tsx` and included on the exported `Notti` object (AD-001: thin pass-through, no business logic in TS)
- [ ] Unit test in `src/__tests__/index.test.tsx` asserting the facade delegates to `NativeNotti.setLocationSharingEnabled` with the passed boolean (mock `NativeNotti` per the file's existing pattern)
- [ ] Gate check passes: `pnpm typecheck && pnpm lint && pnpm test`
- [ ] Test count: at least 1 new test passes, all pre-existing `index.test.tsx` tests still pass

**Tests**: unit (Jest)
**Gate**: quick (JS trio)

**Commit**: `feat(js): expose setLocationSharingEnabled opt-in toggle`

---

### T2: Android — `NottiDeviceStore` telemetry fields

**What**: Extend `NottiDeviceStore`/`DeviceState` with the persisted fields all three stories need: `appVersion` (last synced, P1), the session aggregate (`firstSessionAtMs`, `lastSessionAtMs`, `sessionCount`, `sessionTimeMs`, `sessionStartedAtMs`, P2), and the P3 opt-in flag (`locationSharingEnabled`, default `false`). Single cohesive change because `DeviceState` is one data class — adding fields incrementally would churn the constructor three times.
**Where**: `android/src/main/java/com/notti/NottiDeviceStore.kt` (modify), `android/src/test/java/com/notti/NottiDeviceStoreTest.kt` (modify)
**Depends on**: None
**Reuses**: Existing key + getter/setter + `prefs.edit().apply()` pattern; `DeviceState` data class
**Requirement**: SEGTEL-01 (hold version), SEGTEL-05/06/09 (session state), SEGTEL-10/15 (opt-in persistence)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `DeviceState` gains: `appVersion: String?`, `firstSessionAtMs: Long?`, `lastSessionAtMs: Long?`, `sessionCount: Int`, `sessionTimeMs: Long`, `sessionStartedAtMs: Long?`, `locationSharingEnabled: Boolean`
- [ ] Keys added (naming matches existing `notti_*` convention) + getter/setter per field, all `prefs.edit().putX(...).apply()` style; `locationSharingEnabled` defaults to `false` when absent; numeric session fields default to 0/null appropriately
- [ ] `getState()` returns the extended `DeviceState` with all new fields populated
- [ ] Unit tests: round-trip each new field (set → get); a fresh `NottiDeviceStore` over the same `SharedPreferences` sees persisted values (proves real persistence); `locationSharingEnabled` absent → `false`; numeric session defaults (0/null)
- [ ] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [ ] Test count: new tests pass, all pre-existing `NottiDeviceStoreTest.kt` tests still pass (constructor/getState call sites across the suite may need updating — that's expected, assertions unchanged)

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): add telemetry fields to NottiDeviceStore`

---

### T3: Android — P1 app version sync

**What**: `versionProvider` closure injected into `NottiCore`; `syncAppVersionIfNeeded()` called from `registerDevice`'s success branch that diffs current version against stored `appVersion` and enqueues a PATCH via the existing mutation queue. Opaque string, no semver parsing.
**Where**: `android/src/main/java/com/notti/NottiCore.kt` (modify: constructor + new method + call site), `android/src/main/java/com/notti/NottiModule.kt` (modify: provide the real `versionProvider` reading `PackageInfo.versionName`), `android/src/test/java/com/notti/NottiCoreTest.kt` (modify)
**Depends on**: T2 (needs `NottiDeviceStore.appVersion`)
**Reuses**: `mutate()`/`runOrQueue`/`flushPendingMutations` pipeline, `patchDevice(deviceId, token, fields)`, `tokenProvider`-style constructor injection
**Requirement**: SEGTEL-01, SEGTEL-02, SEGTEL-03, SEGTEL-04

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `NottiCore` constructor gains `versionProvider: () -> String?` (defaulting to `{ null }` so existing tests instantiate unchanged — the default returns null → sync is a no-op)
- [ ] `syncAppVersionIfNeeded()`: reads `versionProvider()`; if `null`, returns without enqueueing (SEGTEL edge: no crash, no registration block); if it differs from `deviceStore.getAppVersion()`, `mutate("appVersion") { ... patchDevice(deviceId, token, mapOf("app_version" to current)) ... on Success -> deviceStore.setAppVersion(current) }`
- [ ] Called from `registerDevice`'s `ApiResult.Success` branch, right after `flushPendingMutations()` (SEGTEL-02: "device registration or next mutation-queue flush")
- [ ] `NottiModule`'s `core` lazy passes a real `versionProvider` using `reactApplicationContext.packageManager.getPackageInfo(packageName, 0).versionName` (wrap in try/catch → `null` on failure; SDK must never crash here)
- [ ] Unit test: versionProvider returns `"1.2.3"` and store `appVersion` is `null` → a PATCH with `app_version = "1.2.3"` is enqueued/executed, and on Success `setAppVersion("1.2.3")`
- [ ] Unit test: versionProvider returns `"1.2.3"` and store `appVersion` already `"1.2.3"` → NO PATCH (diff-and-enqueue: no-op on equal)
- [ ] Unit test: versionProvider returns `null` → no PATCH, no crash
- [ ] Unit test: bump mocked version between two flows → second sync enqueues a PATCH with the NEW value (proves diff, not always-send)
- [ ] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [ ] Test count: 4 new tests pass, all pre-existing `NottiCoreTest.kt` tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): sync app version via device PATCH on change`

---

### T4: Android — P2 session lifecycle

**What**: New background hook + session start/end bookkeeping persisting into `NottiDeviceStore` and enqueueing a snapshot PATCH on session end. Foreground hook already exists (`NottiForegroundObserver.onStart`); this task adds `onStop` → `NottiCore.onAppBackgrounded()`.
**Where**: `android/src/main/java/com/notti/NottiInitProvider.kt` (modify: add `onStop` to `NottiForegroundObserver`), `android/src/main/java/com/notti/NottiCore.kt` (modify: `handleSessionStart`/`handleSessionEnd`/`onAppBackgrounded` + wiring into `onAppForegrounded` + ISO-8601 helper), `android/src/test/java/com/notti/NottiCoreTest.kt` (modify)
**Depends on**: T2 (session store fields)
**Reuses**: `dispatch(...)` executor handoff, `mutate()` queue, existing `onAppForegrounded()` (session-start), `NottiDeviceStore` persistence, `SimpleDateFormat`(UTC) helper
**Requirement**: SEGTEL-05, SEGTEL-06, SEGTEL-07, SEGTEL-08, SEGTEL-09

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `NottiForegroundObserver` gains `override fun onStop(owner: LifecycleOwner)` calling `NottiModule.activeCore?.onAppBackgrounded()` (the missing background hook; zero-integration, mirrors `onStart`)
- [ ] `NottiCore.onAppBackgrounded()` added — dispatches `handleSessionEnd(System.currentTimeMillis())` on the core executor
- [ ] `handleSessionStart(nowMs)` called at the top of `onAppForegrounded()` (before existing flush/retry logic): (1) if `sessionStartedAtMs != null` → close the missed session via `handleSessionEnd(nowMs)` using the stored start (unclean-kill estimate, SEGTEL-08); (2) if `firstSessionAtMs == null` → set it to `nowMs`; (3) `setSessionStartedAtMs(nowMs)`
- [ ] `handleSessionEnd(nowMs)`: if `sessionStartedAtMs == null` → no-op (no active session, excludes widget/background-fetch); else `count += 1`, `sessionTimeMs += nowMs - startedAt`, `lastSessionAtMs = nowMs`, `sessionStartedAtMs = null`, persist all, then enqueue a session PATCH **capturing a snapshot** of `{first_session_at, last_session_at, session_count, session_time_seconds}` computed at enqueue time (edge case: no double-count if a new session starts mid-flush)
- [ ] ISO-8601 helper: `internal fun formatIsoUtc(epochMs: Long): String` using `SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)` + UTC `TimeZone` (NO `java.time` — minSdk 24, no desugaring); `session_time_seconds = sessionTimeMs / 1000`
- [ ] Unit test: foreground → start session; background after ~30s → `sessionCount` +1, `sessionTime` ~30s, `lastSessionAt` set; snapshot PATCH enqueued with all four fields
- [ ] Unit test: process kill simulated — session started (no background), then a fresh `handleSessionStart` → missed session counted once (count +1, time += now − old start), then a new session starts
- [ ] Unit test: `handleSessionEnd` with no active session (`sessionStartedAtMs == null`) → no-op, no PATCH
- [ ] Unit test: session-start with `firstSessionAtMs == null` sets it; a later session does NOT overwrite it
- [ ] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [ ] Test count: 4 new tests pass, all pre-existing tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): track session lifecycle with persisted aggregate`

---

### T5: Android — P3 location opt-in country

**What**: `NottiCore.setLocationSharingEnabled(enabled)` (persist flag, clear-on-disable via `{country: null}` PATCH), plus injected `hasLocationPermission`/`countryProvider` closures wired into session-start to best-effort read country. `NottiModule` override of the new codegen method + real providers.
**Where**: `android/src/main/java/com/notti/NottiCore.kt` (modify: method + provider params + session-start read), `android/src/main/java/com/notti/NottiModule.kt` (modify: override `setLocationSharingEnabled`, provide `hasLocationPermission` via `ContextCompat.checkSelfPermission`, provide `countryProvider` via `LocationManager.getLastKnownLocation` + `Geocoder.getFromLocation(...).countryCode`), `android/src/test/java/com/notti/NottiCoreTest.kt`, `android/src/test/java/com/notti/NottiModuleTest.kt` (modify)
**Depends on**: T1 (codegen Spec method exists), T2 (flag field), T4 (session-start hook)
**Reuses**: `mutate()` queue, `patchDevice` with `country` key, `JSONObject.NULL` via `toJsonValue(null)`, `dispatch(...)`, the `tokenProvider`/`permissionRequester` injection pattern
**Requirement**: SEGTEL-10, SEGTEL-11, SEGTEL-12, SEGTEL-13, SEGTEL-14, SEGTEL-15

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `NottiCore` constructor gains `hasLocationPermission: () -> Boolean = { false }` and `countryProvider: (callback: (String?) -> Unit) -> Unit = { cb -> cb(null) }` (defaults keep existing tests compiling; a no-op provider returns null → omit)
- [ ] `fun setLocationSharingEnabled(enabled: Boolean)`: persists `deviceStore.setLocationSharingEnabled(enabled)`; if `enabled == false`, enqueues a PATCH `{country: null}` immediately (SEGTEL-13 clear, not just stop-sending); if `true`, no immediate read
- [ ] `NottiModule` overrides the codegen `setLocationSharingEnabled(Boolean)` delegating to `core.setLocationSharingEnabled(...)`
- [ ] In `handleSessionStart`, AFTER session bookkeeping: if `deviceStore.getLocationSharingEnabled() && hasLocationPermission()` → `countryProvider { country -> dispatch { if (deviceStore.getLocationSharingEnabled()) { if (country != null) mutate PATCH {country} } } }` (re-check flag at callback time; null/revoked → omit silently, no prompt, no error — SEGTEL-11/12/14)
- [ ] `NottiModule` provides real providers: `hasLocationPermission` via `ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PERMISSION_GRANTED`; `countryProvider` does last-known-location + `Geocoder` reverse-geocode → ISO 3166-1 alpha-2 `countryCode`, all on a background thread, `null` on any failure
- [ ] Unit test: opt-in `false` + permission granted (mocked) → no `country` ever in a payload
- [ ] Unit test: opt-in `true` + permission granted + provider returns `"BR"` → session-start enqueues PATCH `{country: "BR"}`
- [ ] Unit test: toggle `true` then `false` → a PATCH `{country: null}` is enqueued (explicit clear mutation)
- [ ] Unit test: opt-in `true` but provider returns `null` (permission revoked/read failed) → no country field, no crash
- [ ] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [ ] Test count: 4 new tests pass, all pre-existing tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): add opt-in country reporting with explicit clear`

---

### T6: iOS — `NottiDeviceStore` telemetry fields

**What**: Swift mirror of T2.
**Where**: `ios/NottiDeviceStore.swift` (modify), `ios/Tests/NottiDeviceStoreTests.swift` (modify)
**Depends on**: None
**Reuses**: `DeviceState` struct + key + getter/setter + `UserDefaults` pattern
**Requirement**: SEGTEL-01, SEGTEL-05/06/09, SEGTEL-10/15

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `DeviceState` gains the same 7 fields as T2 (`appVersion: String?`, `firstSessionAtMs/lastSessionAtMs/sessionStartedAtMs: Int64?`, `sessionCount: Int`, `sessionTimeMs: Int64`, `locationSharingEnabled: Bool`)
- [ ] Keys + getters/setters per field, `UserDefaults` style matching existing; `locationSharingEnabled` default `false`; numeric defaults 0/nil
- [ ] `getState()` extended
- [ ] Unit tests mirroring T2's (round-trip, real persistence across a new store instance over the same suite, defaults)
- [ ] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [ ] Test count: new tests pass, all pre-existing `NottiDeviceStoreTests.swift` tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add telemetry fields to NottiDeviceStore`

---

### T7: iOS — P1 app version sync

**What**: Swift mirror of T3 — `versionProvider` closure, `syncAppVersionIfNeeded()` in `registerDevice` success.
**Where**: `ios/NottiCore.swift` (modify), `ios/NottiImpl.swift` (modify: provide real `versionProvider` reading `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`), `ios/Tests/NottiCoreTests.swift` (modify)
**Depends on**: T6
**Reuses**: `performOrQueue`/`flushPendingMutations`, `patchDevice(fields:)`, closure-injection pattern
**Requirement**: SEGTEL-01, SEGTEL-02, SEGTEL-03, SEGTEL-04

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `NottiCore` init gains `versionProvider: () -> String?` (default `{ nil }`)
- [ ] `syncAppVersionIfNeeded()` mirrors Android: nil → no-op; differs from stored `appVersion` → `performOrQueue` PATCH `["app_version": current]`, on success `setAppVersion(current)`
- [ ] Called from the iOS registration-success path (wherever `registerDevice`'s success branch persists the response), right after `flushPendingMutations`
- [ ] `NottiImpl` passes a real `versionProvider` reading `CFBundleShortVersionString` (fails → nil, never crash)
- [ ] Unit tests mirroring T3's 4 cases (diff triggers PATCH, equal no-op, nil no-op, bump re-syncs) using the existing `NottiCoreTests.swift` mocking pattern
- [ ] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [ ] Test count: 4 new tests pass, all pre-existing `NottiCoreTests.swift` tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): sync app version via device PATCH on change`

---

### T8: iOS — P2 session lifecycle

**What**: Swift mirror of T4 — new `didEnterBackgroundNotification` observer, session start/end, snapshot PATCH.
**Where**: `ios/NottiCore.swift` (modify: background observer + `handleSessionStart`/`handleSessionEnd` wired into `handleAppDidBecomeActive`, ISO-8601 helper), `ios/Tests/NottiCoreTests.swift` (modify)
**Depends on**: T6
**Reuses**: `observeAppForeground()`'s `NotificationCenter` observer pattern, `onWorkQueue`, `performOrQueue`, `ISO8601DateFormatter`(UTC)
**Requirement**: SEGTEL-05, SEGTEL-06, SEGTEL-07, SEGTEL-08, SEGTEL-09

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `observeAppBackground()` added on `UIApplication.didEnterBackgroundNotification` → `handleAppDidEnterBackground()` → `handleSessionEnd(now)` on the workQueue (mirrors `observeAppForeground`; removed in `deinit`)
- [ ] `handleAppDidBecomeActive()` calls `handleSessionStart(now)` before its existing flush/retry logic (unclean-kill estimate via stale `sessionStartedAtMs`, set `firstSessionAt` once, open new session)
- [ ] `handleSessionEnd(now)`: no-op if no active session; else aggregate (count+1, time += now − startedAt, lastSessionAt = now, clear startedAt, persist) + enqueue snapshot PATCH of the four fields (captured at enqueue time)
- [ ] ISO-8601 helper matching Android's shape (`yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`, UTC, `en_US_POSIX`); `session_time_seconds = sessionTimeMs / 1000`
- [ ] Unit tests mirroring T4's 4 cases (session lifecycle, unclean-kill estimate, no-active-session no-op, first-session-set-once)
- [ ] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [ ] Test count: 4 new tests pass, all pre-existing `NottiCoreTests.swift` tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): track session lifecycle with persisted aggregate`

---

### T9: iOS — P3 location opt-in country

**What**: Swift mirror of T5 — `setLocationSharingEnabled`, injected `hasLocationPermission`/`countryProvider`, session-start read, clear-on-disable.
**Where**: `ios/Notti.mm` (modify: expose the new method), `ios/NottiImpl.swift` (modify: `setLocationSharingEnabled(_:)` + real providers), `ios/NottiCore.swift` (modify: method + providers + session-start read), `ios/Tests/NottiCoreTests.swift` (modify)
**Depends on**: T1, T6, T8
**Reuses**: `CLLocationManager.authorizationStatus` (check-only, never prompt), `CLGeocoder.reverseGeocodeLocation` → `isoCountryCode`, `NSNull` for JSON null, the `Notti.mm` delegation pattern
**Requirement**: SEGTEL-10, SEGTEL-11, SEGTEL-12, SEGTEL-13, SEGTEL-14, SEGTEL-15

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `Notti.mm` exposes `setLocationSharingEnabled:` delegating to `NottiImpl` (same 1-line delegation as `setSubscription:`)
- [ ] `NottiImpl.setLocationSharingEnabled(_:)` → `NottiCore.setLocationSharingEnabled(_:)`
- [ ] `NottiCore` init gains `hasLocationPermission: () -> Bool = { false }` and `countryProvider: (@escaping (String?) -> Void) -> Void = { $0(nil) }`
- [ ] `NottiCore.setLocationSharingEnabled(_ enabled: Bool)`: persist flag; `false` → immediate `performOrQueue` PATCH `["country": NSNull()]` (clear); `true` → no immediate read
- [ ] In `handleSessionStart`, after bookkeeping: if flag on && `hasLocationPermission()` → `countryProvider { country in onWorkQueue { if flag still on { if let country → PATCH {country} } } }`
- [ ] `NottiImpl` provides real providers: `hasLocationPermission` via `CLLocationManager.authorizationStatus` ∈ {`.authorizedWhenInUse`, `.authorizedAlways`}; `countryProvider` via cached `location` + `CLGeocoder` → `isoCountryCode`, nil on any failure, never prompts
- [ ] Unit tests mirroring T5's 4 cases (off+granted → no country; on+granted+`BR` → PATCH; on→off → `{country: null}` clear; on+provider-nil → omit, no crash)
- [ ] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [ ] Test count: 4 new tests pass, all pre-existing tests in touched files still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add opt-in country reporting with explicit clear`

---

### T10: Cross-platform review + full sanity gate

**What**: No new code — confirm both platforms implement the same contract (payload keys, diff/enqueue, session snapshot, opt-in semantics), and run the repo's full sanity gate.
**Where**: N/A (review + command run only)
**Depends on**: T1, T5, T9
**Reuses**: N/A
**Requirement**: All (traceability closure)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] Side-by-side read confirms identical PATCH payload keys on both platforms: `app_version`, `first_session_at`, `last_session_at`, `session_count`, `session_time_seconds`, `country` (and `country: null` for clear)
- [ ] Both platforms diff-and-enqueue version the same way; session snapshot is captured at enqueue time (not flush) on both
- [ ] Both platforms' opt-in semantics match: default off, clear-on-disable, permission check-only, omit-not-error
- [ ] `git grep -n "session_time_seconds\|setLocationSharingEnabled\|app_version"` across `android/`/`ios/`/`src/` shows consistent key/method names (no typo drift)
- [ ] Full native gate re-run on both platforms + `pnpm typecheck && pnpm lint && pnpm test` (already green from prior tasks; final confirmation after cross-review fixes)
- [ ] Requirement traceability in `spec.md`: SEGTEL-01..15 all → Implemented (Verifier pending)

**Tests**: none (review task)
**Gate**: full (both platforms' commands + JS trio)

**Commit**: none expected (review-only; any fix found becomes its own small commit, not folded silently)

---

## Parallel Execution Map

```
Phase 1 (single shared file):
  T1 ──→ (unblocks native overrides)

Phase 2 (platform-parallel, intra-platform sequential):
  Android: T2 ──→ T3 ──→ T4 ──→ T5
  iOS:     T6 ──→ T7 ──→ T8 ──→ T9

Phase 3 (sequential, needs both platforms done):
  T1..T9 complete, then: T10
```

**Parallelism constraint check**: T2-T5 and T6-T9 touch entirely disjoint files (`android/` vs `ios/`,
different languages, different test runners) — safe to parallelize as two chains after T1. Within each
platform: T3→T2, T4→T2, T5→T2+T4 (store fields, then session-start hook, then the read wired into it);
T7→T6, T8→T6, T9→T6+T8. T1 must land first because the native overrides (T5 Android / T9 iOS) and the
codegen Spec depend on it.

---

## Task Granularity Check

| Task | Scope | Status |
| --- | --- | --- |
| T1: JS Spec + facade | 2 files, same module | ✅ Granular |
| T2/T6: DeviceStore fields | 1 main file + 1 test file | ✅ Granular |
| T3/T7: version sync | 2 main files + 1 test file (core method + provider wiring) | ✅ OK — cohesive |
| T4/T8: session lifecycle | 1-2 main files + 1 test file | ✅ OK — cohesive |
| T5/T9: location opt-in | 3 main files + 1-2 test files (new JS method + core + providers) | ⚠️ Borderline — 4 files, but each edit follows the same one-method pattern (like T4/T8 of `ctr-event-reporting`); split would create no independently-testable units (the JS method without the core method is dead surface, the core method without providers is untestable) |
| T10 | Review + gate run | ✅ Granular (checkpoint) |

---

## Diagram-Definition Cross-Check

| Task | Depends On (task body) | Diagram Shows | Status |
| --- | --- | --- | --- |
| T1 | None | No incoming arrow | ✅ Match |
| T2 | None | No incoming arrow (platform-parallel start) | ✅ Match |
| T3 | T2 | T2 → T3 | ✅ Match |
| T4 | T2 | T2 → T4 | ✅ Match |
| T5 | T1, T2, T4 | T4 → T5 (T1/T2 satisfied earlier in chain) | ✅ Match |
| T6 | None | No incoming arrow | ✅ Match |
| T7 | T6 | T6 → T7 | ✅ Match |
| T8 | T6 | T6 → T8 | ✅ Match |
| T9 | T1, T6, T8 | T8 → T9 (T1/T6 satisfied earlier in chain) | ✅ Match |
| T10 | T1, T5, T9 | Both chains → T10 | ✅ Match |

---

## Test Co-location Validation

| Task | Code Layer Created/Modified | Matrix Requires | Task Says | Status |
| --- | --- | --- | --- | --- |
| T1 | TS facade (`src/`) | Jest | unit (Jest) | ✅ OK |
| T2/T3/T4/T5 | Android native | JVM unit | unit | ✅ OK |
| T6/T7/T8/T9 | iOS native | XCTest | unit | ✅ OK |
| T10 | None | none | none | ✅ OK |

All ✅ — no restructuring needed.

---

## Tools Confirmation Needed

`NONE` assigned throughout — every pattern reused already exists in this repo (cited per task): the
mutation queue, `patchDevice` open-fields, raw-JSON null, store persistence, injection closures, the
existing foreground hooks (which this feature mirrors for the new background hooks). No external
library research needed. **Confirm**: is `NONE` correct for all ten, or is there a specific MCP/Skill
you want used for T10's cross-platform gate run?