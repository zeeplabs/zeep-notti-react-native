# CTR Event Reporting Tasks

**Design**: `.specs/features/ctr-event-reporting/design.md`
**Status**: Complete — all T1-T9 done, commits `cabfb88`→`3f1c938`, gates green (Android 106 JVM tests, iOS 109 XCTest, JS typecheck/lint/test clean, `src/` untouched). Independent Verifier ran: 13/14 ACs first pass, SDKCTR-11 gap fixed in `aed1512` and re-verified — READY. Shipped in v0.4.0.

---

## Test Coverage Convention (no `.specs/codebase/TESTING.md` yet — derived from `CONTRIBUTING.md`)

| Code layer | Test type | Command | Evidence |
| --- | --- | --- | --- |
| Android native (Kotlin, `android/src/main`) | JVM unit test (`android/src/test`) | `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest` | `CONTRIBUTING.md` "Native tests"; `android/src/test/java/com/notti/*Test.kt` (e.g. `NottiApiClientTest.kt`, `NottiCoreTest.kt`) |
| iOS native (Swift, `ios/`) | XCTest (`ios/Tests`) | `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'` | `CONTRIBUTING.md`; `ios/Tests/*.swift` |
| TS facade (`src/`) | Jest | `pnpm test` | Not expected to change in this feature — AD-001, no new JS surface |

This feature touches ONLY the native layers (Android `android/src/main/java/com/notti/`, iOS
`ios/`) — per AD-001 and this design's explicit goal of zero new JS surface, no task here touches
`src/`, and `pnpm test`/`pnpm typecheck` are not part of any task's gate (they'd pass trivially
since nothing there changes; still run once at the end as a sanity check, not per-task).

**Gate check commands**:
- Android `quick`/`full` (same command, JVM tests are fast — no separate tiers on this platform): `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- iOS `quick`/`full` (same reasoning): `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`

Both platforms' tests run independently — a task touching only Android gates on the Android
command; a task touching only iOS gates on the iOS command; a task touching both (there are none —
see Parallel Execution Map) would gate on both.

---

## Execution Plan

### Phase 1: Platform-parallel foundation (Android and iOS never touch the same file — parallel across platforms; within a platform, sequential because later tasks build on earlier ones in the same files)

```
Android: T1 ──→ T2 ──→ T3 ──→ T4
iOS:     T5 ──→ T6 ──→ T7 ──→ T8
```

### Phase 2: Cross-cutting review

```
(T1..T8 complete) ──→ T9
```

---

## Task Breakdown

### T1: Android — `NottiEventStore` [P]

**What**: New `SharedPreferences`-backed disk queue for `PendingEvent` records, with zero dependency on `NottiCore`/`NottiApiClient`/`NottiDeviceStore`.
**Where**: `android/src/main/java/com/notti/NottiEventStore.kt` (new)
**Depends on**: None
**Reuses**: `NottiDeviceStore.kt`'s `SharedPreferences` persistence style
**Requirement**: SDKCTR-10, SDKCTR-11

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `PendingEvent(id, notificationId, deliveryId, type, createdAtMs)` data class defined
- [x] `NottiEventStore(prefs: SharedPreferences)` (constructor-injected, matching `NottiDeviceStore`'s testability pattern) with `enqueue(notificationId, deliveryId, type): PendingEvent`, `all(): List<PendingEvent>`, `remove(id: String)`
- [x] Queue capped at 32 entries (mirrors `NottiCore.MAX_PENDING_MUTATIONS`), oldest dropped first when full
- [x] No import of `NottiCore`, `NottiApiClient`, or `NottiDeviceStore` anywhere in this file (design's hard constraint — verify by inspection, not just tests)
- [x] Unit test: `enqueue` then `all()` returns the record; `remove` then `all()` no longer contains it; enqueue past the cap drops the oldest; a fresh `NottiEventStore` over the same `SharedPreferences` instance sees previously enqueued (unremoved) events (proves actual persistence, not just in-memory state)
- [x] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [x] Test count: 4 new tests pass (no silent deletions)

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): add NottiEventStore for offline event persistence`

---

### T2: Android — `NottiApiClient.reportEvent`

**What**: New method posting one event to `POST /v1/apps/{appId}/notifications/{notificationId}/events`, reusing the retry/backoff logic (refactored to be generic so all three methods share it).
**Where**: `android/src/main/java/com/notti/NottiApiClient.kt` (modify)
**Depends on**: T1 (uses `PendingEvent`'s field names as its parameter shape, though not the class itself — sequenced to avoid designing the request body twice)
**Reuses**: `executeWithRetry`'s existing loop, `jsonMediaType`, `Request.Builder` pattern from `createOrUpdateDevice`/`patchDevice`
**Requirement**: SDKCTR-07, SDKCTR-08

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `executeWithRetry` generalized to `private fun <T> executeWithRetry(request: Request, parseSuccess: (String) -> T?): EventCallResult<T>` (or equivalent — exact naming at implementation time), with `createOrUpdateDevice`/`patchDevice` updated to use it unchanged in behavior
- [x] `sealed class EventResult { object Success : EventResult(); data class Failure(val message: String) : EventResult() }` added
- [x] `fun reportEvent(notificationId: String, deliveryId: String, type: String, token: String): EventResult` — builds `{delivery_id, type, token}` body, `Authorization: Bearer $clientKey` header, POSTs to `.../notifications/$notificationId/events`, any 2xx → `Success` (body ignored)
- [x] Existing `createOrUpdateDevice`/`patchDevice` tests still pass unmodified (proves the generic refactor didn't change their behavior)
- [x] Unit test: 503 response → 5 attempts with 2s/4s/8s/16s/32s backoff (injectable `sleeper`, same pattern as existing `NottiApiClientTest.kt`), final `Failure`
- [x] Unit test: 403/404/422 → 1 attempt, immediate `Failure`, no retry
- [x] Unit test: 200/201 → `Success`, regardless of body content (even empty body)
- [x] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [x] Test count: 3 new tests pass, all pre-existing `NottiApiClientTest.kt` tests still pass (no silent deletions)

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): add NottiApiClient.reportEvent with shared retry logic`

---

### T3: Android — `NottiCore.flushEventQueue` + wiring into existing triggers

**What**: New private method draining `NottiEventStore`, calling `reportEvent` per entry, removing on success/terminal-4xx; wired into the three trigger points (registration success, `onAppForegrounded`, new network observer — network observer itself is T4).
**Where**: `android/src/main/java/com/notti/NottiCore.kt` (modify: constructor gains `eventStore: NottiEventStore`, add `flushEventQueue()`, call it from `registerDevice`'s success branch and from `onAppForegrounded()`)
**Depends on**: T1, T2
**Reuses**: `dispatch(...)` for crash-safe executor handoff, `deviceStore.getLastToken()` for the current token, existing `logger` for failure visibility
**Requirement**: SDKCTR-09, SDKCTR-12

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `NottiCore`'s constructor accepts a `NottiEventStore` (constructor-injected, same testability pattern as `deviceStore`/`apiClientFactory`)
- [x] `flushEventQueue()`: no-op if `apiClient == null` or `deviceStore.getLastToken() == null`; otherwise iterates `eventStore.all()`, calls `apiClient.reportEvent(...)` per entry, removes on `Success` or a `Failure` classified as terminal (4xx — `reportEvent`'s `EventResult.Failure` does not currently distinguish terminal-vs-retряexhausted; since `reportEvent` itself already exhausts retries internally before returning `Failure`, EVERY `Failure` from `reportEvent` at this layer means "give up for now," so `flushEventQueue` leaves it queued on any `Failure` — it does NOT need to re-distinguish 4xx vs. exhausted-5xx itself, that distinction already collapsed inside `reportEvent`)
- [x] Called from `registerDevice`'s `ApiResult.Success` branch, right after `flushPendingMutations()`
- [x] Called unconditionally at the top of `onAppForegrounded()` (before its existing registration-state guard, since a flush attempt is valid even when already `REGISTERED`)
- [x] Unit test: `flushEventQueue` with `apiClient == null` → no crash, no call to any mock
- [x] Unit test: `flushEventQueue` with a mock `NottiApiClient` returning `Success` for a queued event → `NottiEventStore.remove` called with that event's id
- [x] Unit test: `flushEventQueue` with `Failure` → event NOT removed
- [x] Unit test: `onAppForegrounded()` calls `flushEventQueue()` even when `registrationState == REGISTERED` (proves it runs outside the existing early-return guard)
- [x] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [x] Test count: 4 new tests pass, all pre-existing `NottiCoreTest.kt` tests still pass (constructor signature changed — update their instantiation, not their assertions)

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): add NottiCore.flushEventQueue and wire into foreground/registration triggers`

---

### T4: Android — network observer + detection-site hookups

**What**: New `ConnectivityManager`-based observer (registered from `NottiInitProvider`) calling `flushEventQueue()` on reconnect; `enqueue` calls added at the two existing detection sites (`NottiFirebaseMessagingService.onMessageReceived`, `NottiActivityLifecycleListener`'s click-Intent handling).
**Where**: `android/src/main/java/com/notti/NottiNetworkObserver.kt` (new), `android/src/main/java/com/notti/NottiInitProvider.kt` (modify: register the observer), `android/src/main/java/com/notti/NottiFirebaseMessagingService.kt` (modify), `android/src/main/java/com/notti/NottiActivityLifecycleListener.kt` (modify)
**Depends on**: T3
**Reuses**: `NottiInitProvider.onCreate`'s existing "register listeners, no SDK work" pattern; `ConnectivityManager.registerDefaultNetworkCallback` (API 24+, matches `minSdkVersion`)
**Requirement**: SDKCTR-01, SDKCTR-02, SDKCTR-03, SDKCTR-04, SDKCTR-05, SDKCTR-06, SDKCTR-13

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `NottiNetworkObserver` registers a `ConnectivityManager.NetworkCallback` once from `NottiInitProvider.onCreate`, calling `NottiModule.activeCore?.flushEventQueue()` (needs a small internal accessor since `flushEventQueue` is private — either package-private or an internal wrapper, matching how `onAppForegrounded()`/`onTokenRefreshed()` are already the public-within-module surface `NottiInitProvider`/`NottiFirebaseMessagingService` call)
- [x] `NottiFirebaseMessagingService.onMessageReceived`: after `NottiModule.emitNotificationReceived(remoteMessage)`, parse `remoteMessage.data` for `notification_id`+`delivery_id`; if both present, call a new static helper (e.g. `NottiModule.enqueueEvent(notificationId, deliveryId, "received")`) that writes to a module-level `NottiEventStore` instance and opportunistically calls `activeCore?.flushEventQueue()`
- [x] `NottiActivityLifecycleListener`'s existing `parseClickIntentExtras(intent)` → `NottiNotificationClickRelay.emit(parsed)` call site: same `data`-check + enqueue, with the exclusion already implicit (custom action/dismiss actions never reach this Android code path at all — Android's launch-Intent click detection has no separate action-identifier concept the way iOS's `UNNotificationResponse` does, so SDKCTR-03 is iOS-only, confirmed in Edge Cases below)
- [x] `NottiEventStore` instance is a `NottiModule`-companion-held singleton (constructed once, e.g. lazily on first use, backed by the `Application` context's `SharedPreferences` — same lifetime model as `activeCore`), NOT re-created per call
- [x] Unit/integration test (whichever the existing `NottiFirebaseMessagingServiceTest.kt`/`NottiActivityLifecycleListenerTest.kt` pattern uses): a `RemoteMessage`/`Intent` carrying `notification_id`+`delivery_id` in its data results in a `NottiEventStore.enqueue` call; one without them does not
- [x] Test: `NottiNetworkObserver`'s callback invokes `flushEventQueue` (via a fake `ConnectivityManager`/ Robolectric shadow, matching whatever mocking approach the existing Android test suite already uses for Android framework classes)
- [x] Gate check passes: `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- [x] Test count: 3 new tests pass, all pre-existing tests in the 4 touched files still pass (no silent deletions)

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): wire event detection, enqueue, and network-triggered flush`

---

### T5: iOS — `NottiEventStore` [P]

**What**: Swift equivalent of T1 — `UserDefaults`-backed disk queue, zero dependency on `NottiCore`/`NottiApiClient`/`NottiDeviceStore`.
**Where**: `ios/NottiEventStore.swift` (new)
**Depends on**: None
**Reuses**: `NottiDeviceStore.swift`'s persistence style
**Requirement**: SDKCTR-10, SDKCTR-11

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `PendingEvent: Codable { id, notificationId, deliveryId, type, createdAtMs }` defined (matches design.md's Swift shape)
- [x] `NottiEventStore(defaults: UserDefaults)` (constructor-injected, matching `NottiDeviceStore.swift`'s testability pattern) with `enqueue(notificationId:deliveryId:type:) -> PendingEvent`, `all() -> [PendingEvent]`, `remove(id: String)`
- [x] Queue capped at 32 entries, oldest dropped first
- [x] No import of/reference to `NottiCore`, `NottiApiClient`, or `NottiDeviceStore` in this file
- [x] Unit test (XCTest, mirroring `NottiDeviceStoreTests.swift`'s pattern): same 4 cases as T1 (enqueue+all, remove, cap eviction, persistence across a new store instance over the same `UserDefaults` suite)
- [x] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [x] Test count: 4 new tests pass (no silent deletions)

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add NottiEventStore for offline event persistence`

---

### T6: iOS — `NottiApiClient.reportEvent`

**What**: Swift equivalent of T2.
**Where**: `ios/NottiApiClient.swift` (modify)
**Depends on**: T5
**Reuses**: iOS `NottiApiClient`'s existing `executeWithRetry(_:parseSuccess:)` (per its own doc comment, already mirrors the Kotlin one) — generalized the same way
**Requirement**: SDKCTR-07, SDKCTR-08

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `executeWithRetry` generalized to a generic form, `createOrUpdateDevice`/`patchDevice` updated to use it unchanged in behavior
- [x] `enum EventResult { case success; case failure(String) }` added
- [x] `func reportEvent(notificationId: String, deliveryId: String, type: String, token: String) -> EventResult` — same request shape as Android's
- [x] Existing `createOrUpdateDevice`/`patchDevice` tests (`NottiApiClientTests.swift`) still pass unmodified
- [x] Unit test: 503 → 5 attempts, documented backoff (using `StubURLProtocol.swift`'s existing stubbing pattern), final `.failure`
- [x] Unit test: 403/404/422 → 1 attempt, immediate `.failure`
- [x] Unit test: 200/201 → `.success` regardless of body
- [x] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [x] Test count: 3 new tests pass, all pre-existing `NottiApiClientTests.swift` tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add NottiApiClient.reportEvent with shared retry logic`

---

### T7: iOS — `NottiCore.flushEventQueue` + wiring into existing triggers

**What**: Swift equivalent of T3.
**Where**: `ios/NottiCore.swift` (modify)
**Depends on**: T5, T6
**Reuses**: `NottiCore.swift`'s existing `onWorkQueue`/`performOrQueue` dispatch pattern, `deviceStore`'s token getter
**Requirement**: SDKCTR-09, SDKCTR-12

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `NottiCore`'s initializer accepts a `NottiEventStore`
- [x] `flushEventQueue()` mirrors Android's T3 logic exactly (same no-op conditions, same "any Failure stays queued" reasoning — `reportEvent` already exhausted its own retries)
- [x] Called from the registration-success path (wherever iOS's equivalent of `registerDevice`'s success branch lives) and unconditionally from wherever `onAppForegrounded`'s iOS equivalent is (if one exists yet on iOS — confirm against current `NottiCore.swift`; if iOS has no foreground-resume method yet, this task ALSO adds the minimal equivalent, scoped only to calling `flushEventQueue`, not full registration-retry-on-foreground parity, which is out of scope here)
- [x] Unit tests mirroring T3's 4 cases, adapted to XCTest/the existing `NottiCoreTests.swift` mocking pattern
- [x] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [x] Test count: 4 new tests pass, all pre-existing `NottiCoreTests.swift` tests still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add NottiCore.flushEventQueue and wire into triggers`

**Note for implementer**: this task's "Done when" flags a genuine unknown — whether iOS already has a
foreground-resume hook symmetric to Android's `onAppForegrounded()`. Confirm against current
`ios/NottiCore.swift` before starting; if the method doesn't exist, adding it is in scope for T7
(it's required for SDKCTR-12), but keep it minimal — do not use this task to backport Android's full
foreground registration-retry behavior to iOS if iOS doesn't already have it, that would be
unrequested scope expansion.

---

### T8: iOS — network observer + detection-site hookups

**What**: Swift equivalent of T4 — `NWPathMonitor`-based observer, `enqueue` calls added at `NottiPushDelegate`'s `willPresent`/`didReceive response:`.
**Where**: `ios/NottiNetworkObserver.swift` (new), wherever `NottiPushDelegate`/`NottiBridge` static setup is started (confirm exact file during implementation — likely alongside `NottiPushDelegate.shared`'s own initialization or a new explicit start call the host app's `AppDelegate` forwarding already triggers), `ios/NottiPushDelegate.swift` (modify: `willPresent` and `didReceive response:`)
**Depends on**: T7
**Reuses**: `NottiPushDelegate.swift`'s existing `isRemotePush`/`parseUserInfo` calls — the enqueue check runs on the same already-parsed `data`, no new parsing
**Requirement**: SDKCTR-01, SDKCTR-02, SDKCTR-03, SDKCTR-04, SDKCTR-05, SDKCTR-06, SDKCTR-13

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] `NottiNetworkObserver` wraps `NWPathMonitor`, calling `NottiImpl.activeCore?.flushEventQueue()` (via whatever internal-access equivalent T7 established) on a transition to `.satisfied`
- [x] `NottiPushDelegate.willPresent`: after the existing `NottiEventBuffer.shared.emit(.received, ...)` call, check `parsed`'s underlying data for `notification_id`+`delivery_id`; if present, enqueue + opportunistic flush
- [x] `NottiPushDelegate.didReceive response:`: same check, placed AFTER the existing `actionIdentifier == UNNotificationDefaultActionIdentifier` guard (`NottiPushDelegate.swift:84`) — confirms SDKCTR-03's exclusion is naturally inherited, not reimplemented
- [x] Unit test: `willPresent`/`didReceive` with ids present → enqueue called; without → not called; a non-default action → not called (using the existing `NottiPushDelegate` test setup, if one exists, or a new minimal one following the same fixture style as `NottiNotificationParsingTests.swift`)
- [x] Unit test: `NottiNetworkObserver` transitioning to satisfied triggers a flush call (mock/stub the path monitor per whatever the closest existing pattern in this codebase supports — no framework precedent for this exists yet, so this is the one genuinely new test-infrastructure piece in the whole feature)
- [x] Gate check passes: `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- [x] Test count: 3 new tests pass, all pre-existing tests in touched files still pass

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): wire event detection, enqueue, and network-triggered flush`

---

### T9: Cross-platform review + full sanity gate

**What**: No new code — confirm both platforms actually implement the same contract (same request shape, same terminal/retry classification, same flush triggers), and run the repo's full sanity gate once.
**Where**: N/A (review + command run only)
**Depends on**: T4, T8
**Reuses**: N/A
**Requirement**: All (traceability closure)

**Tools**:
- MCP: NONE
- Skill: NONE

**Done when**:
- [x] Side-by-side read of `NottiApiClient.kt`'s and `NottiApiClient.swift`'s `reportEvent` confirms identical request shape/headers/retry classification
- [x] Side-by-side read of both `NottiCore.flushEventQueue` implementations confirms identical no-op conditions and removal logic
- [x] `git grep -n "notification_id\|delivery_id"` across `android/` and `ios/` shows the same two key names used consistently (no typo drift between platforms)
- [x] `pnpm typecheck && pnpm lint && pnpm test` passes (sanity check that nothing in `src/` was accidentally touched — should be a no-op run)
- [x] Full native gate re-run on both platforms (already green from T4/T8, this is the final confirmation after any cross-review fixes)

**Tests**: none (review task)
**Gate**: full (both platforms' commands + the JS sanity trio)

**Commit**: none expected (review-only; any fix found becomes its own small commit, not folded silently into this task)

---

## Parallel Execution Map

```
Phase 1 (platform-parallel, intra-platform sequential):
  Android:
    T1 [P] ──→ T2 ──→ T3 ──→ T4
  iOS:
    T5 [P] ──→ T6 ──→ T7 ──→ T8

Phase 2 (sequential, needs both platforms done):
  T4, T8 complete, then:
    T9
```

**Parallelism constraint check**: T1 and T5 touch entirely disjoint files (`android/` vs `ios/`,
different languages, different test runners/gate commands) — safe to parallelize as the two
starting points. Within each platform, T2 depends on T1 (shares the request-body field names),
T3 depends on T1+T2 (needs both the store and the API method), T4 depends on T3 (wires the flush
method into triggers) — a strict chain, no further parallelism available within a platform since
each step's code and tests build on the previous step's.

---

## Task Granularity Check

| Task | Scope | Status |
| --- | --- | --- |
| T1: Android NottiEventStore | 1 new file | ✅ Granular |
| T2: Android reportEvent | 1 method + 1 refactor, same file as existing methods it must stay consistent with | ✅ OK — cohesive |
| T3: Android flushEventQueue + wiring | 1 method + 2 call-site edits, same file (`NottiCore.kt`) | ✅ OK — cohesive |
| T4: Android network observer + detection hookups | 1 new file + 3 small edits across 3 files | ⚠️ Borderline — 4 files touched, but each edit is 1-3 lines; kept together because they're the "make it actually fire in the real app" half of the feature and splitting further would create 3-4 tasks with almost no independent test value (a detection hookup with nowhere to flush to isn't independently meaningful) |
| T5-T8 | Mirror T1-T4 on iOS | Same granularity reasoning as above, per task |
| T9 | Review + gate run, no code | ✅ Granular (explicitly a checkpoint, not an implementation task) |

**On T4/T8's ⚠️**: per the Tasks skill's own tip ("2-3 related things in same file = OK if
cohesive" / "Multiple components or files = MUST split"), T4 touches 4 files, which nominally
calls for a split. It is NOT split here because: (a) `NottiNetworkObserver` alone has no caller
without the `NottiInitProvider` registration edit; (b) the two detection-site edits are each
1 `if` + 1 method call, in files this design's Components section explicitly says NOT to factor
into a shared helper (the sites differ in input shape); splitting into 4 tasks would mean 3 of them
produce code with no test able to observe an end-to-end effect until the 4th lands — exactly the
"merge forward" situation `tasks.md`'s own Resolving-Compilation-Dependencies rule tells us to
avoid creating. Flagged here rather than silently accepted.

---

## Diagram-Definition Cross-Check

| Task | Depends On (task body) | Diagram Shows | Status |
| --- | --- | --- | --- |
| T1 | None | No incoming arrow | ✅ Match |
| T2 | T1 | T1 → T2 | ✅ Match |
| T3 | T1, T2 | T2 → T3 (T1 already satisfied earlier in the same chain) | ✅ Match |
| T4 | T3 | T3 → T4 | ✅ Match |
| T5 | None | No incoming arrow | ✅ Match |
| T6 | T5 | T5 → T6 | ✅ Match |
| T7 | T5, T6 | T6 → T7 | ✅ Match |
| T8 | T7 | T7 → T8 | ✅ Match |
| T9 | T4, T8 | Both chains → T9 | ✅ Match |

---

## Test Co-location Validation

| Task | Code Layer Created/Modified | Matrix Requires | Task Says | Status |
| --- | --- | --- | --- | --- |
| T1: Android NottiEventStore | Android native (pure, no framework class) | JVM unit | unit | ✅ OK |
| T2: Android reportEvent | Android native (HTTP client) | JVM unit | unit | ✅ OK |
| T3: Android flushEventQueue | Android native | JVM unit | unit | ✅ OK |
| T4: Android network observer + hookups | Android native (touches framework classes: `ConnectivityManager`, `RemoteMessage`, `Intent`) | JVM unit (existing tests for these classes already use JVM unit + shadows/fakes, not instrumented tests) | unit | ✅ OK |
| T5: iOS NottiEventStore | iOS native | XCTest | unit | ✅ OK |
| T6: iOS reportEvent | iOS native | XCTest | unit | ✅ OK |
| T7: iOS flushEventQueue | iOS native | XCTest | unit | ✅ OK |
| T8: iOS network observer + hookups | iOS native | XCTest | unit | ✅ OK |
| T9: review | None (no code) | none | none | ✅ OK |

All ✅ — no restructuring needed.

---

## Tools Confirmation Needed

`NONE` assigned throughout — same reasoning as the backend feature's tasks.md: every pattern reused
already exists in this repo (cited per task), no external library research needed. **Confirm**: is
`NONE` correct for all nine, or is there a specific MCP/Skill (e.g. an Xcode/Gradle-running MCP) you
want used, particularly for T9's cross-platform gate run?
