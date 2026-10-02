# Device Profile Fields Tasks

**Design**: `.specs/features/device-profile-fields/design.md`
**Status**: Draft — T1-T10 planned, not yet executed.

---

## Test Coverage Convention (no `.specs/codebase/TESTING.md` yet — derived from `CONTRIBUTING.md`)

| Code layer | Test type | Command | Evidence |
| --- | --- | --- | --- |
| Android native (Kotlin, `android/src/main`) | JVM unit test (`android/src/test`) | `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest` | `CONTRIBUTING.md` "Native tests"; `android/src/test/java/com/notti/*Test.kt` |
| iOS native (Swift, `ios/`) | XCTest (`ios/Tests`) | `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'` | `CONTRIBUTING.md`; `ios/Tests/*.swift` |
| TS facade (`src/`) | Jest | `pnpm test` (+ `pnpm typecheck`, `pnpm lint`) | `src/__tests__/index.test.tsx` |

Unlike `ctr-event-reporting` (which touched only native layers), **this feature DOES touch `src/`** — P1's
`sdk_version` is threaded from JS through `initialize` (a constant-of-version pass-through, not business
logic, per `AD-001` and design.md Tech Decisions), and P4's `User.setEmail/clearEmail/setPhone/clearPhone`
are integrator-supplied identity data with a JS entry point. So the JS gate
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

T1 is the codegen dependency: the Spec's `initialize` signature gains the `sdkVersion` 4th argument and
the four new email/phone methods must exist before `NottiModule.kt`/`Notti.mm` overrides compile against
the regenerated Spec.

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

### T1: JS — `sdk_version` threading + email/phone Spec + facade

**What**: The JS-visible surface of this feature: (a) the Spec's `initialize` gains a `sdkVersion` 4th argument that the facade resolves internally from the package manifest (public `initialize(appId, clientKey, options)` signature unchanged for integrators — `AD-001` preserved, the version is a constant, not business logic), and (b) the four P4 methods `setEmail`/`clearEmail`/`setPhone`/`clearPhone` on the Spec and on the `User` object, mirroring the `addTag`/`removeTag` shape.
**Where**: `src/NativeNotti.ts` (modify: `initialize` signature + 4 new `Spec` methods), `src/index.tsx` (modify: `initialize` resolves+forwards `sdkVersion`; `User` gains the 4 wrappers), `src/__tests__/index.test.tsx` (modify)
**Depends on**: None
**Reuses**: The `Spec`→facade→export chain (`setSubscription`/`setLocationSharingEnabled` mould), the `User` object's one-line delegation pattern, the package's existing `./package.json` export for the runtime version read
**Requirement**: DPF-17, DPF-18, DPF-01 (partial — `sdk_version` threading)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `Spec.initialize(appId: string, clientKey: string, baseUrl: string, sdkVersion: string): void` in `src/NativeNotti.ts` (the codegen signature the native overrides compile against)
- [ ] `Spec.setEmail(email: string): void`, `clearEmail(): void`, `setPhone(phone: string): void`, `clearPhone(): void` declared in `src/NativeNotti.ts` (positioned with the other setters, after `setLocationSharingEnabled`)
- [ ] `initialize` in `src/index.tsx` resolves the package version once at module load (`require('react-native-notti/package.json').version` via the package's `exports`; on resolution failure passes `''`) and forwards it as the 4th native arg — native treats empty as `null` → field omitted; public `initialize(appId, clientKey, options)` unchanged
- [ ] `User.setEmail(email: string)`, `User.clearEmail()`, `User.setPhone(phone: string)`, `User.clearPhone()` added to the `User` object, each delegating one line to `NativeNotti` (AD-001: thin pass-through, no business logic in TS)
- [ ] Unit tests in `src/__tests__/index.test.tsx`: `initialize` forwards the resolved `sdkVersion` as the 4th arg; empty-string fallback path; the four email/phone methods delegate to `NativeNotti` with the passed args (mock `NativeNotti` per the file's existing pattern)
- [ ] Gate check passes: `pnpm typecheck && pnpm lint && pnpm test`
- [ ] Test count: at least 5 new tests pass, all pre-existing `index.test.tsx` tests still pass

**Tests**: unit (Jest)
**Gate**: quick (JS trio)

**Commit**: `feat(js): add email/phone setters and thread sdk_version through initialize`

---

### T2: Android — `NottiDeviceStore` device-profile fields

**What**: Extend `NottiDeviceStore`/`DeviceState` with the persisted fields all four stories need: the P1/P2 last-synced profile strings (`lastSyncedDeviceOs`, `lastSyncedDeviceModel`, `lastSyncedSdkVersion`, `lastSyncedTimezoneId`, `lastSyncedLanguage`), the P3 state (`lastSyncedPermissionStatus`, `lastUnsubscribedAtMs`), and the P4 held values (`email`, `phone`). Single cohesive change because `DeviceState` is one data class — adding fields incrementally would churn the constructor nine times.
**Where**: `android/src/main/java/com/notti/NottiDeviceStore.kt` (modify), `android/src/test/java/com/notti/NottiDeviceStoreTest.kt` (modify)
**Depends on**: None
**Reuses**: Existing key + getter/setter + `prefs.edit().apply()` pattern; the `-1L` sentinel pattern of the existing `Long?` fields; `DeviceState` data class
**Requirement**: DPF-01, DPF-06, DPF-10, DPF-14, DPF-17 (persistence partial)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `DeviceState` gains: `lastSyncedDeviceOs: String?`, `lastSyncedDeviceModel: String?`, `lastSyncedSdkVersion: String?`, `lastSyncedTimezoneId: String?`, `lastSyncedLanguage: String?`, `lastSyncedPermissionStatus: String?`, `lastUnsubscribedAtMs: Long?`, `email: String?`, `phone: String?`
- [ ] Keys added following the existing `notti_*` convention (`notti_last_synced_device_os`, `notti_last_synced_device_model`, `notti_last_synced_sdk_version`, `notti_last_synced_timezone_id`, `notti_last_synced_language`, `notti_last_synced_permission_status`, `notti_last_unsubscribed_at_ms`, `notti_email`, `notti_phone`) + getter/setter per field, all `prefs.edit().putX(...).apply()` style; `lastUnsubscribedAtMs` uses the `getLong(KEY, -1L).takeIf { it >= 0 }` sentinel of the other `Long?` fields
- [ ] `getState()` returns the extended `DeviceState` with all nine new fields populated
- [ ] Unit tests: round-trip each new field (set → get); a fresh `NottiDeviceStore` over the same `SharedPreferences` sees persisted values (proves real persistence); absent fields default to `null`
- [ ] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [ ] Test count: new tests pass, all pre-existing `NottiDeviceStoreTest.kt` tests still pass (constructor/getState call sites across the suite may need updating — that's expected, assertions unchanged)

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): add device-profile fields to NottiDeviceStore`

---

### T3: Android — profile field sync (`syncProfileFieldsIfNeeded`)

**What**: Generalize `syncAppVersionIfNeeded()` (828-849) into `syncProfileFieldsIfNeeded()` — a loop over the six read-once fields (`device_os`, `device_model`, `sdk_version`, `timezone_id`, `language` + the existing `app_version`), each diffed against its own `deviceStore` last-synced value and enqueued independently on change — plus the five new injected providers and the `sdkVersion` param on `initialize`. `NottiModule` wires the real OS reads.
**Where**: `android/src/main/java/com/notti/NottiCore.kt` (modify: constructor providers + `initialize(appId, clientKey, baseUrl, sdkVersion)` + generalize 828-849 + call site at registerDevice success 568), `android/src/main/java/com/notti/NottiModule.kt` (modify: override `initialize` 187-189 to forward `sdkVersion`; provide real `deviceOsProvider`/`deviceModelProvider`/`sdkVersionProvider`/`timezoneProvider`/`languageProvider`), `android/src/test/java/com/notti/NottiCoreTest.kt` (modify)
**Depends on**: T2 (last-synced store fields)
**Reuses**: `mutate()`/`runOrQueue` (780-817), `patchDevice`, the `syncAppVersionIfNeeded` template, `tokenProvider`-style constructor injection with `{ null }` defaults
**Requirement**: DPF-01, DPF-02, DPF-03, DPF-04, DPF-05, DPF-06, DPF-07, DPF-08, DPF-09

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `NottiCore` constructor gains `deviceOsProvider: () -> String?`, `deviceModelProvider: () -> String?`, `sdkVersionProvider: () -> String?`, `timezoneProvider: () -> String?`, `languageProvider: () -> String?` (defaults `{ null }` so existing tests instantiate unchanged — a null provider makes that field's sync a no-op, DPF-04/09)
- [ ] `syncProfileFieldsIfNeeded()` replaces `syncAppVersionIfNeeded()`: for each of the six fields, `provider()?.let { cur -> if (cur != store.getLastSynced<Field>()) mutate("<field>", coalesceKey) { patchDevice(mapOf("<field>" to cur)); on Success -> store.setLastSynced<Field>(cur) } }`; opaque strings, no semver/locale parsing; `app_version` folds into the loop with unchanged behavior (DPF-05)
- [ ] `initialize(appId: String, clientKey: String, baseUrl: String, sdkVersion: String?)` accepts and stores the version (empty/blank → `null`), feeding `sdkVersionProvider`
- [ ] `syncProfileFieldsIfNeeded()` called from `registerDevice`'s Success branch right after `flushPendingMutations()` (replacing the `syncAppVersionIfNeeded()` call, 568) — covers DPF-02 (registration payload) and DPF-07
- [ ] `NottiModule` override `initialize(appId, clientKey, baseUrl, sdkVersion)` forwards the version to core; real providers wired in the `core` lazy (97-127): `Build.VERSION.RELEASE`, `Build.MODEL`, `TimeZone.getDefault().id`, `Locale.getDefault().language`, each wrapped in try/catch → `null` on failure (SDK must never crash here, DPF-04/09)
- [ ] Unit tests (`NottiCoreTest.kt`): a fresh registration payload carries `device_os`/`device_model`/`sdk_version`/`timezone_id`/`language`/`app_version`; mutating one mocked value between two flows re-sends ONLY that field (diff, not the whole set — DPF-03/08); a `null` provider → that field omitted, no crash; `sdk_version` passed via `initialize` reaches the payload; `app_version` still syncs on change
- [ ] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [ ] Test count: at least 5 new tests pass, all pre-existing `NottiCoreTest.kt` tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): sync device profile fields via generalized PATCH`

---

### T4: Android — `permission_status` + `last_unsubscribed_at`

**What**: Async `permissionStatusProvider` injected into `NottiCore`, funneling three triggers (registration success, `requestPermission` result, session start) into one `syncPermissionStatusIfNeeded()` helper, plus `last_unsubscribed_at` on both unsubscribe paths. `NottiModule` provides the real OS-status read.
**Where**: `android/src/main/java/com/notti/NottiCore.kt` (modify: `permissionStatusProvider` param + `syncPermissionStatusIfNeeded()` + hooks in `requestPermission` 597-628, `setSubscription` 655-663, `handleSessionStart` 420-434), `android/src/main/java/com/notti/NottiModule.kt` (modify: provide real provider), `android/src/test/java/com/notti/NottiCoreTest.kt` (modify)
**Depends on**: T2 (store `lastSyncedPermissionStatus`/`lastUnsubscribedAtMs`)
**Reuses**: `readCountryIfOptedIn`'s async-provider callback shape (455-473), `mutate()`/`runOrQueue`, `formatIsoUtc` (536-539), the `countryProvider`-style constructor injection
**Requirement**: DPF-10, DPF-11, DPF-12, DPF-13, DPF-14, DPF-15, DPF-16

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `NottiCore` constructor gains `permissionStatusProvider: (callback: (String?) -> Unit) -> Unit` (async, default `{ cb -> cb(null) }` — keeps existing tests compiling; null → omit)
- [ ] `syncPermissionStatusIfNeeded()`: fires the provider; if `status != deviceStore.getLastSyncedPermissionStatus()`, enqueues a coalesced PATCH `permission_status` and persists the value on Success; `null`/unknown status → omit, never fabricate (DPF edge case)
- [ ] Trigger 1 — `registerDevice` Success: `syncPermissionStatusIfNeeded()` called alongside `syncProfileFieldsIfNeeded()` (DPF-11)
- [ ] Trigger 2 — `requestPermission` result: in the existing `mutate("requestPermission")` work (616-625), after the `subscribed` PATCH, fire the provider and enqueue the current `permission_status` in its callback (DPF-12 — reads OS state, not the dialog bool)
- [ ] Trigger 3 — `handleSessionStart`: after session bookkeeping, fire the provider and diff-and-enqueue (DPF-13 — catches permission changed in OS Settings while the app wasn't running)
- [ ] `setSubscription(false)`: if stored `subscribed` was `true` (a real true→false transition), persist `lastUnsubscribedAtMs = now` and enqueue `{last_unsubscribed_at: formatIsoUtc(now)}` coalesced key `lastUnsubscribed` (DPF-14 app-driven path); `setSubscription(true)` never clears it (DPF-15)
- [ ] In `syncPermissionStatusIfNeeded`: freshly-read status `denied` AND previous synced status `granted` → persist `lastUnsubscribedAtMs = now` and carry `last_unsubscribed_at` in the same PATCH (DPF-14 permission-driven path — atomic single request)
- [ ] Two-axis independence: `permission_status` and `subscribed` updated independently, no cross-field inference (DPF-16)
- [ ] `NottiModule` provides the real provider: `NotificationManagerCompat.areNotificationsEnabled(context)` + API 33 `checkSelfPermission(POST_NOTIFICATIONS)`; `<33` maps enabled→`granted`/disabled→`denied` (no runtime permission exists below 33); unknown/transitional → `null`
- [ ] Unit tests (`NottiCoreTest.kt`): registration success syncs `permission_status`; `requestPermission` result syncs it; a simulated granted→denied Settings change at the next session start enqueues `permission_status` + `last_unsubscribed_at`; `setSubscription(false)` on a subscribed device sets `last_unsubscribed_at` while `permission_status` stays `granted`; re-subscribe does NOT clear `last_unsubscribed_at`; unknown status → omitted, no crash
- [ ] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [ ] Test count: at least 5 new tests pass, all pre-existing tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): sync permission status and last-unsubscribe timestamp`

---

### T5: Android — first-class `email`/`phone` (set/clear)

**What**: `NottiCore.setEmail/clearEmail/setPhone/clearPhone` persisting into the store, diffing against the held value, and enqueueing coalesced set/clear PATCHes through the existing mutation queue (clear via raw-JSON `null`), plus an unconditional registration re-sync of non-null held values. `NottiModule` overrides the four codegen methods.
**Where**: `android/src/main/java/com/notti/NottiCore.kt` (modify: 4 methods + `KEY_EMAIL`/`KEY_PHONE` coalesce keys in the companion ~137-139 + registration re-sync in `registerDevice` success 568-569), `android/src/main/java/com/notti/NottiModule.kt` (modify: override the 4 codegen methods), `android/src/test/java/com/notti/NottiCoreTest.kt` (modify)
**Depends on**: T1 (Spec methods exist for codegen), T2 (store `email`/`phone`)
**Reuses**: `mutate()`/`runOrQueue` coalesce handling (780-817), raw-JSON null via `org.json.JSONObject.NULL` (the `countryClearMutation` three-state path, 733-760), the `registerDevice` success hook
**Requirement**: DPF-17, DPF-18, DPF-19, DPF-20, DPF-21

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `NottiCore.setEmail(email: String)`/`setPhone(phone: String)`: persist the value; if equal to the currently-held value → no-op (DPF-20); else `mutate("setEmail", KEY_EMAIL)` enqueue `patchDevice({email: value})`, on Success no-op (held == synced)
- [ ] `NottiCore.clearEmail()`/`clearPhone()`: persist `null`; enqueue `{email: JSONObject.NULL}`/`{phone: JSONObject.NULL}` via the raw-JSON null path (DPF-18); coalesce key so a queued set is superseded by the clear
- [ ] Coalesce keys `KEY_EMAIL`/`KEY_PHONE` added to the companion, treated like the telemetry keys (replace queued, not against the 32-cap — design Tech Decisions)
- [ ] `registerDevice` Success: after the profile/permission syncs, if held `email`/`phone` is non-null, enqueue a set unconditionally (DPF-19 — fresh backend row after reinstall/backup-restore converges); null held → nothing sent
- [ ] `NottiModule` overrides the 4 codegen methods (`setEmail(email: String?)`, `clearEmail()`, `setPhone(phone: String?)`, `clearPhone()`) delegating one line to core
- [ ] Unit tests (`NottiCoreTest.kt`): `setEmail` enqueues PATCH `{email}` and NO `tags` field (DPF-21); `clearEmail` enqueues `{email: null}`; `setEmail` twice with the same value → a single mutation (DPF-20 idempotence); registration success re-sends a held email/phone; null held → nothing sent
- [ ] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [ ] Test count: at least 5 new tests pass, all pre-existing tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): add first-class email/phone set and clear`

---

### T6: iOS — `NottiDeviceStore` device-profile fields

**What**: Swift mirror of T2.
**Where**: `ios/NottiDeviceStore.swift` (modify), `ios/Tests/NottiDeviceStoreTests.swift` (modify)
**Depends on**: None
**Reuses**: `DeviceState` struct + key + getter/setter + `UserDefaults` pattern; the `NSNumber` handling of the existing `Int64?` `*AtMs` fields
**Requirement**: DPF-01, DPF-06, DPF-10, DPF-14, DPF-17 (persistence partial)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `DeviceState` gains the same 9 fields as T2 (`lastSyncedDeviceOs`/`lastSyncedDeviceModel`/`lastSyncedSdkVersion`/`lastSyncedTimezoneId`/`lastSyncedLanguage`/`lastSyncedPermissionStatus: String?`, `lastUnsubscribedAtMs: Int64?`, `email: String?`, `phone: String?`), with matching `init` defaults
- [ ] Keys + getters/setters per field, `UserDefaults` style matching existing (`notti_last_synced_*`, `notti_last_unsubscribed_at_ms`, `notti_email`, `notti_phone`); `Int64?` via the `(defaults.object(...) as? NSNumber)?.int64Value` pattern; absent → nil
- [ ] `getState()` extended with all nine fields
- [ ] Unit tests mirroring T2's (round-trip, real persistence across a new store instance over the same suite, nil defaults)
- [ ] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [ ] Test count: new tests pass, all pre-existing `NottiDeviceStoreTests.swift` tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add device-profile fields to NottiDeviceStore`

---

### T7: iOS — profile field sync (`syncProfileFieldsIfNeeded`)

**What**: Swift mirror of T3 — generalize `syncAppVersionIfNeeded` (589-602) into `syncProfileFieldsIfNeeded`, add the five providers and the `sdkVersion` param on `initialize`, and wire the real OS reads in `NottiImpl`.
**Where**: `ios/NottiCore.swift` (modify: init providers + `initialize(appId:clientKey:baseUrl:sdkVersion:)` + generalize 589-602 + call site at `registerDevice` 562), `ios/NottiImpl.swift` (modify: `initialize` override 264-267 + provide real providers), `ios/Notti.mm` (modify: `initialize:` gains `sdkVersion`, 32-37), `ios/Tests/NottiCoreTests.swift` (modify)
**Depends on**: T6
**Reuses**: `performOrQueue`/`flushPendingMutations`, `patchDevice(fields:)`, closure-injection pattern, the `TelemetryKey` coalesce scheme
**Requirement**: DPF-01, DPF-02, DPF-03, DPF-04, DPF-05, DPF-06, DPF-07, DPF-08, DPF-09

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `NottiCore` init gains `deviceOsProvider`/`deviceModelProvider`/`sdkVersionProvider`/`timezoneProvider`/`languageProvider` (`() -> String?`, defaults `{ nil }`)
- [ ] `syncProfileFieldsIfNeeded(_ client:)` replaces `syncAppVersionIfNeeded`: six-field loop, per-field diff against the store's last-synced value, coalesced `performOrQueue` PATCH, persist on Success; nil provider → skip that field only (DPF-04/09); `app_version` unchanged (DPF-05)
- [ ] `initialize(appId:clientKey:baseUrl:sdkVersion:)` accepts and stores `sdkVersion` (empty → nil), feeding `sdkVersionProvider`; `Notti.mm`'s `initialize:` forwards the new 4th param (32-37); `NottiImpl` override matches
- [ ] `syncProfileFieldsIfNeeded` called from `registerDevice`'s success branch after `flushPendingMutations` (replacing the `syncAppVersionIfNeeded` call, 562)
- [ ] `NottiImpl` provides real providers: `UIDevice.current.systemVersion`, `utsname.machine`, `TimeZone.current.identifier`, `Locale.current.languageCode` (each fails → nil, never crash)
- [ ] Unit tests mirroring T3's 5 cases (fresh registration carries all six fields; one field changed between flushes re-sends only it; nil provider omits; `sdk_version` from `initialize` reaches the payload; `app_version` still syncs) using the existing `NottiCoreTests.swift` mocking pattern
- [ ] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [ ] Test count: at least 5 new tests pass, all pre-existing `NottiCoreTests.swift` tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): sync device profile fields via generalized PATCH`

---

### T8: iOS — `permission_status` + `last_unsubscribed_at`

**What**: Swift mirror of T4 — async `permissionStatusProvider` via `UNUserNotificationCenter.getNotificationSettings`, three triggers into `syncPermissionStatusIfNeeded`, and `last_unsubscribed_at` on both unsubscribe paths.
**Where**: `ios/NottiCore.swift` (modify: `permissionStatusProvider` param + `syncPermissionStatusIfNeeded(client)` + hooks in `requestPermission` 310-342, `setSubscription` 371-378, `handleSessionStartOnQueue` 768-779), `ios/NottiImpl.swift` (modify: provide real provider), `ios/Tests/NottiCoreTests.swift` (modify)
**Depends on**: T6
**Reuses**: `readCountryIfEnabled`'s async-provider shape (859-872), `performOrQueue`, `onWorkQueue`, `formatIsoUtc` (969-973), the `countryProvider` callback injection
**Requirement**: DPF-10, DPF-11, DPF-12, DPF-13, DPF-14, DPF-15, DPF-16

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `NottiCore` init gains `permissionStatusProvider: (@escaping (String?) -> Void) -> Void` (default `{ $0(nil) }`)
- [ ] `syncPermissionStatusIfNeeded(_ client:)` mirrors T4: diff against `lastSyncedPermissionStatus`, coalesced PATCH, persist on Success; nil/unknown → omit, never fabricate
- [ ] Trigger 1 — `registerDevice` success: called alongside `syncProfileFieldsIfNeeded` (DPF-11)
- [ ] Trigger 2 — `requestPermission` result (310-342): after the `subscribed` PATCH, fire the provider and enqueue `permission_status` in its callback (DPF-12)
- [ ] Trigger 3 — `handleSessionStartOnQueue` (768-779): after session bookkeeping, fire the provider and diff-and-enqueue (DPF-13)
- [ ] `setSubscription(false)`: true→false transition → persist `lastUnsubscribedAtMs` and enqueue `{last_unsubscribed_at}` coalesced `lastUnsubscribed` (DPF-14); `setSubscription(true)` never clears (DPF-15)
- [ ] Granted→denied in `syncPermissionStatusIfNeeded` → persist timestamp + same-request PATCH carries both fields (DPF-14)
- [ ] Two-axis independence (DPF-16)
- [ ] `NottiImpl` provides the real provider: `UNUserNotificationCenter.current().getNotificationSettings` → `authorizationStatus` → `granted`/`denied`/`notDetermined`/`provisional` (provisional auth), unknown → nil
- [ ] Unit tests mirroring T4's cases (registration sync, requestPermission sync, Settings granted→denied at session start, app-driven unsubscribe keeps `permission_status` granted, re-subscribe not clearing, unknown omitted)
- [ ] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [ ] Test count: at least 5 new tests pass, all pre-existing tests in touched files still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): sync permission status and last-unsubscribe timestamp`

---

### T9: iOS — first-class `email`/`phone` (set/clear)

**What**: Swift mirror of T5 — `NottiCore.setEmail/clearEmail/setPhone/clearPhone` with `NSNull` clears and coalesce keys, unconditional registration re-sync of non-nil held values, and the `NottiImpl`/`Notti.mm` overrides.
**Where**: `ios/NottiCore.swift` (modify: 4 methods + coalesce keys + registration re-sync in `registerDevice` 561-563), `ios/NottiImpl.swift` (modify: 4 `@objc` methods), `ios/Notti.mm` (modify: expose the 4 selectors, same 1-line delegation as `setSubscription:` 67-70), `ios/Tests/NottiCoreTests.swift` (modify)
**Depends on**: T1 (Spec methods exist for codegen), T6 (store `email`/`phone`)
**Reuses**: `performOrQueue`, coalesce keys (extend the `TelemetryKey` scheme), `NSNull()` for JSON null, the `Notti.mm` delegation pattern
**Requirement**: DPF-17, DPF-18, DPF-19, DPF-20, DPF-21

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] `NottiCore.setEmail(_ email: String)`/`setPhone(_ phone: String)`: persist; equal to held value → no-op (DPF-20); else `performOrQueue` PATCH `["email": email]` with a coalesce key (DPF-17)
- [ ] `NottiCore.clearEmail()`/`clearPhone()`: persist nil; enqueue `["email": NSNull()]`/`["phone": NSNull()]` (DPF-18), coalesce so a queued set is superseded
- [ ] Coalesce keys `email`/`phone` added alongside the `TelemetryKey` constants (120-124)
- [ ] `registerDevice` success: unconditional set of held non-nil `email`/`phone` after `flushPendingMutations` (DPF-19); nil held → nothing
- [ ] `NottiImpl` adds `@objc(setEmail:)`/`@objc(clearEmail)`/`@objc(setPhone:)`/`@objc(clearPhone)` delegating to core; `Notti.mm` exposes the same selectors mirroring `setSubscription:`
- [ ] Never merged into tags (DPF-21)
- [ ] Unit tests mirroring T5's cases (set enqueues `email` with no `tags` change; clear enqueues `{email: null}`; same-value set → single mutation; registration re-syncs held values; nil held → nothing)
- [ ] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [ ] Test count: at least 5 new tests pass, all pre-existing tests in touched files still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add first-class email/phone set and clear`

---

### T10: Cross-platform review + full sanity gate

**What**: No new code — confirm both platforms implement the same contract (PATCH payload keys, coalesce semantics, permission triggers, unsubscribe transitions, email/phone clear), and run the repo's full sanity gate.
**Where**: N/A (review + command run only)
**Depends on**: T1, T5, T9 (both chains and JS complete)
**Reuses**: N/A
**Requirement**: All (traceability closure)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [ ] Side-by-side read confirms identical PATCH payload keys on both platforms: `device_os`, `device_model`, `sdk_version`, `timezone_id`, `language`, `permission_status`, `last_unsubscribed_at`, `email`, `phone` (and `email: null`/`phone: null` for clear)
- [ ] Both platforms diff-and-enqueue profile fields the same way (six-field loop incl. `app_version`); coalesce semantics match (`lastUnsubscribed`/`permissionStatus`/`email`/`phone` replace queued, no eviction)
- [ ] Both platforms' `permission_status` triggers match (registration / requestPermission / session start); granted→denied sets `last_unsubscribed_at`; re-subscribe never clears it; `subscribed` and `permission_status` stay independent
- [ ] `git grep -n "device_os\|device_model\|sdk_version\|timezone_id\|permission_status\|last_unsubscribed_at\|setEmail\|clearEmail"` across `android/`/`ios/`/`src/` shows consistent key/method names (no typo drift)
- [ ] Full native gate re-run on both platforms + `pnpm typecheck && pnpm lint && pnpm test` (already green from prior tasks; final confirmation after cross-review fixes)
- [ ] Requirement traceability in `spec.md`: DPF-01..21 all → Implemented (Verifier pending)

**Tests**: none (review task)
**Gate**: full (both platforms' commands + JS trio)

**Commit**: none expected (review-only; any fix found becomes its own small commit, not folded silently)

---

## Parallel Execution Map

```
Phase 1 (single shared file):
  T1 ──→ (unblocks native overrides/codegen)

Phase 2 (platform-parallel, intra-platform sequential):
  Android: T2 ──→ T3 ──→ T4 ──→ T5
  iOS:     T6 ──→ T7 ──→ T8 ──→ T9

Phase 3 (sequential, needs both platforms done):
  T1..T9 complete, then: T10
```

**Parallelism constraint check**: T2-T5 and T6-T9 touch entirely disjoint files (`android/` vs `ios/`,
different languages, different test runners) — safe to parallelize as two chains after T1. Within each
platform: T3→T2, T4→T2 (store fields, then the sync helpers), T5→T2+T1 (store fields + codegen Spec);
T7→T6, T8→T6, T9→T6+T1. T1 must land first because the native overrides (T5 Android / T9 iOS), the iOS
`Notti.mm` `initialize:`/email-phone selectors, and the codegen Spec all depend on its surface.

---

## Task Granularity Check

| Task | Scope | Status |
| --- | --- | --- |
| T1: JS Spec + facade | 2 files + 1 test file, same module | ✅ Granular |
| T2/T6: DeviceStore fields | 1 main file + 1 test file | ✅ Granular |
| T3/T7: profile sync | 2-3 main files + 1 test file (core generalization + provider wiring) | ✅ OK — cohesive |
| T4/T8: permission + last_unsubscribed | 2 main files + 1 test file | ✅ OK — cohesive |
| T5/T9: email/phone | 2-3 main files + 1 test file (core methods + module/impl + bridge overrides) | ✅ OK — cohesive (each edit follows the same one-method pattern; splitting would create no independently-testable units) |
| T10 | Review + gate run | ✅ Granular (checkpoint) |

---

## Diagram-Definition Cross-Check

| Task | Depends On (task body) | Diagram Shows | Status |
| --- | --- | --- | --- |
| T1 | None | No incoming arrow | ✅ Match |
| T2 | None | No incoming arrow (platform-parallel start) | ✅ Match |
| T3 | T2 | T2 → T3 | ✅ Match |
| T4 | T2 | T2 → T4 | ✅ Match |
| T5 | T1, T2 | T4 → T5 (T1/T2 satisfied earlier in chain) | ✅ Match |
| T6 | None | No incoming arrow | ✅ Match |
| T7 | T6 | T6 → T7 | ✅ Match |
| T8 | T6 | T6 → T8 | ✅ Match |
| T9 | T1, T6 | T8 → T9 (T1/T6 satisfied earlier in chain) | ✅ Match |
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
mutation queue (`mutate`/`performOrQueue`), `patchDevice` open-fields, raw-JSON null
(`JSONObject.NULL`/`NSNull`), store persistence, injection closures (sync `versionProvider` and async
`countryProvider` shapes), and the existing `syncAppVersionIfNeeded`/session-start hooks this feature
generalizes or extends. No external library research needed. **Confirm**: is `NONE` correct for all ten,
or is there a specific MCP/Skill you want used for T10's cross-platform gate run?