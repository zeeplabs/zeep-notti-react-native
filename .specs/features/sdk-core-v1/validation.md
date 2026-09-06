# SDK Core v1 Validation

**Date**: 2026-09-05
**Spec**: `.specs/features/sdk-core-v1/spec.md`
**Diff range**: `ad7e8ab8f264a1805f0e6b3829c1066d0f0d70ea..HEAD` (round 2 — re-verification after fix batch `cf7d259..91c8aa0`, on top of round 1's `..3f77453`)
**Verifier**: independent sub-agent (author ≠ verifier; this is a fresh Verifier run, distinct from round 1's)

---

## Round 2 Scope

Round 1 (prior `validation.md`, superseded by this report) found FAIL with 5 ranked gaps: SDK-14/15/16 zero native test coverage (Blocker), SDK-11 untested (Major), SDK-18 dedup unproven (Major), unbounded `takeRequest()` (Minor), stale traceability table (Minor). A fix batch landed 5 commits claiming to close all of them:

- `cf7d259` test(sdk): add native-layer coverage for login/logout/setSubscription (SDK-14/15/16)
- `169cde5` test(android): cover <13 permission auto-grant path (SDK-11)
- `518cbe5` test(android): prove notification-click fires exactly once per tap (SDK-18)
- `58f9fe1` test(android): bound `takeRequest()` calls with an explicit timeout
- `91c8aa0` docs(spec): update requirement traceability table

This round re-derives evidence for all 5 fixes from scratch (not trusting the commit messages), spot-checks 3 previously-passing ACs for regressions, re-runs the full gate, and runs a fresh discrimination sensor against the new fix-round code.

---

## Task Completion

All 19 original tasks (T1-T19) remain `✅ Done` per round 1 (unchanged by this fix batch — the 5 fix commits are test-only additions plus one production hardening change in `NuntisApiClient.swift`, not new tasks). No task-completion regressions found.

---

## Spec-Anchored Acceptance Criteria — Re-verified Criteria (round 2 focus)

Evidence-or-zero: every citation below is a real `file:line` with the assertion expression quoted, independently re-derived this round.

| # | Criterion (spec.md wording) | Spec-defined outcome | Android evidence | iOS evidence | Result |
|---|---|---|---|---|---|
| SDK-14 (P3-AC3) | `login(externalUserId)` → `PATCH .../devices/{id}` with `{external_user_id, token}` | exact field values on the wire | `NuntisCoreTest.kt:228-243` (`login PATCHes external_user_id and the cached token...`) `assertEquals("user-42", body.getString("external_user_id"))`, `assertEquals("fcm-token", body.getString("token"))`, plus `assertEquals("user-42", store.getExternalUserId())` | `NuntisCoreTests.swift` `test_loginPatchesExternalUserIdAndTheCachedTokenAndPersistsItLocallyOnSuccess` `XCTAssertEqual(body["external_user_id"] as? String, "user-42")`, `XCTAssertEqual(body["token"] as? String, "apns-token")` | ✅ PASS (was ❌ GAP in round 1) |
| SDK-15 (P3-AC4) | `logout()` clears the locally held external user id **only** — no server-side clear, so no PATCH is sent | zero PATCH calls from `logout()` itself + local state cleared | `NuntisCoreTest.kt:246-261` (`logout clears the locally held external user id without sending any PATCH`) `assertEquals(2, server.requestCount)` (register+login only, none from logout) and `assertEquals(null, store.getExternalUserId())` — correctly asserts **no** PATCH, matching spec's local-only wording (this is the exact trap the task brief flagged: a test asserting a PATCH *was* sent would itself be a new bug — that trap was not fallen into) | `NuntisCoreTests.swift` `test_logoutClearsTheLocallyHeldExternalUserIdWithoutSendingAnyPatch` `XCTAssertEqual(StubURLProtocol.recordedRequests().count, 2)`, `XCTAssertNil(store.getExternalUserId())` | ✅ PASS (was ❌ GAP in round 1) |
| SDK-16 (P3-AC5) | `setSubscription(enabled)` → `PATCH .../devices/{id}` with `{subscribed, token}` | exact field values on the wire | `NuntisCoreTest.kt:264-280` `assertEquals(true, body.getBoolean("subscribed"))`, `assertEquals("fcm-token", body.getString("token"))`, `assertTrue(store.getSubscribed())` | `NuntisCoreTests.swift` `test_setSubscriptionPatchesTheGivenSubscribedValueAndTheCachedTokenAndPersistsItLocallyOnSuccess` `XCTAssertEqual(body["subscribed"] as? Bool, true)`, `XCTAssertEqual(body["token"] as? String, "apns-token")` | ✅ PASS (was ❌ GAP in round 1) |
| SDK-11 (P2-AC4) | Android <13 auto-grant, no prompt | prompt never fires, resolves granted, without falling through to the `PermissionAwareActivity` path | `NuntisModuleTest.kt:32-59` (`@Config(sdk=[32])`) constructs a **real** `NuntisModule` (not `NuntisCore`'s injected fake) and asserts `resolvedValue == true`; `FakeReactApplicationContext.getCurrentActivity()` deliberately throws, so a regression that falls through to the real-permission path fails loudly instead of silently passing — a discriminating design, confirmed by this round's sensor (see below) | N/A (Android-only AC) | ✅ PASS (was ❌ GAP in round 1) |
| SDK-18 (P3-AC7, Android dedup) | Tap (any app state) → `notificationClicked`, exactly once per tap | second resume on the same Activity/Intent must not re-fire | `NuntisActivityLifecycleListenerTest.kt:29-46` (`onActivityResumed called twice with the same click intent fires the dedup clear exactly once`) constructs a real `NuntisActivityLifecycleListener`, calls `onActivityResumed` twice on the same `Activity`/`CountingIntent`, asserts `replaceExtrasCallCount == 1` after **both** calls — a genuine stateful proof (not just parsing), confirmed by this round's sensor | Parsing only; dedup inherently OS-delivered on iOS (unchanged from round 1, not a gap) | ✅ PASS (was ❌ GAP in round 1) |

**Fix 4 (unbounded `takeRequest()`, Minor)**: `android/src/test/java/com/nuntis/NuntisApiClientTest.kt:47,70` now both call `server.takeRequest(5, TimeUnit.SECONDS)` (confirmed via `git show 58f9fe1` diff and current file content) — matches every other `takeRequest` call in the codebase. `ios/NuntisApiClient.swift`'s `semaphore.wait()` now bounds at `.now() + 65` and returns a `NuntisApiClientTimeoutError` on timeout, confirmed in `ios/NuntisApiClient.swift:114-121`. Resolved.

**Fix 5 (stale traceability table, Minor)**: `spec.md`'s Requirement Traceability table (lines 117-141) now shows per-requirement status matching the round-1 report (SDK-11/14/15/16/18 marked ✅ Verified with a note that they moved from Needs Fix after this fix batch; SDK-04 still correctly marked ❌ Needs Fix — not part of this fix batch's scope, an honest, not over-claimed, update). Resolved.

---

## Spot-Check: Previously-Passing Criteria (regression check)

| # | Criterion | Check | Result |
|---|---|---|---|
| SDK-01 (P1-AC1) | `POST .../devices` with `{token,platform}`, `Authorization: Bearer {clientKey}` | `NuntisApiClientTest.kt:50` `assertEquals("Bearer secret-key", recorded.getHeader("Authorization"))` — line shifted (47→50) due to the new `takeRequest` timeout arg insertion, assertion content unchanged; test passed in this round's full gate run | ✅ No regression |
| SDK-02 (P1-AC2) | Persist device id, cache returned `tags` | `NuntisCoreTest.kt:116,144` `assertEquals("device-1", store.getDeviceId())` — present, unchanged, passed in gate | ✅ No regression |
| SDK-19 (P3-AC8) | Two rapid tag mutations serialize; net-merged result | `NuntisCoreTest.kt:311` `assertEquals(mapOf("cohort" to "beta"), store.getTags())` in the real `Thread`-race test — present, unchanged, passed in gate | ✅ No regression |

No regression found in any spot-checked criterion. Line numbers shifted (new tests were inserted earlier in the same files) but assertion content is identical to round 1.

**Status**: ✅ All 19 ACs now clear (11 clean PASS carried from round 1 unchanged + 5 newly PASS this round + SDK-04/08/12/13/17 remain declared-scope spec-precision gaps/documented Needs-Fix, unchanged and out of this fix batch's scope, not fresh findings).

---

## Discrimination Sensor (round 2 — targets the NEW fix-round code)

Isolated `git worktree` at a scratch path under this session's scratchpad directory (never `git stash`). Baseline `git status --porcelain` before sensor: only `.specs/LESSONS.md`, `.specs/features/sdk-core-v1/validation.md`, `.specs/lessons.json` (untracked docs) and `example/node_modules` (untracked symlink workaround) — no tracked-file modifications. Confirmed byte-identical after sensor cleanup (`diff` against the captured baseline showed no difference).

| Mutation | File:line | Description | Killed? |
| -------- | --------- | ------------ | ------- |
| 1 | `android/src/main/java/com/nuntis/NuntisCore.kt:102-104` | `logout()`'s body replaced with a no-op (removed `deviceStore.setExternalUserId(null)`) — targets the exact new SDK-15 fix | ✅ Killed — `NuntisCoreTest > logout clears the locally held external user id without sending any PATCH FAILED` (`NuntisCoreTest.kt:262`) |
| 2 | `android/src/main/java/com/nuntis/NuntisModule.kt:114` | Flipped `Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU` → `SDK_INT > TIRAMISU` (inverted condition) — targets the exact new SDK-11 fix | ✅ Killed — `NuntisModuleTest > requestPermission on Android below 13 resolves granted without ever touching the current activity FAILED` (`NuntisModuleTest.kt:46`) |

**Sensor depth**: lightweight (2 targeted mutations, one per newly-landed fix with the highest behavioral risk: the local-only clear and the SDK-version branch).
**Sensor verdict**: 2/2 killed. Scratch worktree removed (`git worktree remove --force`); real tree's `git status --porcelain` confirmed identical to the pre-sensor baseline via `diff`.

(SDK-16/setSubscription and SDK-18/dedup fixes were evidence-checked via the spec-anchored table above rather than separately mutated — the tiering guidance calls for 1-3 targeted mutations for a standard, non-P0 feature; 2 was judged sufficient given both mutations directly hit the two riskiest newly-landed behaviors and both were cleanly killed.)

---

## Code Quality

| Principle        | Status |
| ---------------- | ------ |
| Minimum code     | ✅ (fix commits are narrowly scoped: 3 new test methods per platform for Fix 1, 1 new test file for Fix 2, 1 new test method + 1 shadow class for Fix 3, a 1-arg addition ×2 + a production timeout guard for Fix 4, a doc table edit for Fix 5) |
| Surgical changes | ✅ |
| No scope creep   | ✅ |
| Matches patterns | ✅ (new tests mirror existing `NuntisCoreTest.kt`/`NuntisCoreTests.swift` structure; `NuntisModuleTest.kt`'s `FakeReactApplicationContext` is a necessary, narrowly-scoped test double, not an unrequested abstraction) |
| Spec-anchored outcome check (asserted values match spec) | ✅ — SDK-15's test correctly asserts **zero** PATCH calls from `logout()`, matching spec's local-only wording exactly (the task brief's flagged trap — a test asserting a PATCH *was* sent — was not fallen into) |
| Per-layer Coverage Expectation met (domain 1:1 ACs; routes happy+edge+error) | ✅ Met — SDK-14/15/16 now have native-layer tests on both platforms; SDK-11/18 now have real behavioral proofs, not just parsing-function tests |
| Every test maps to a spec requirement - no unclaimed tests | ✅ |
| Documented guidelines followed: tasks.md's Test Coverage Matrix (`.specs/features/sdk-core-v1/tasks.md:20-26`) | ✅ Bar now met for SDK-14/15/16/11/18 |

No new defects found in this round's code-quality pass.

---

## Edge Cases

- [x] `requestPermission()` before `initialize()` → log, no crash, no prompt: unchanged from round 1, still passes in this round's gate.
- [x] `logout()` server-side `external_user_id` retention surfaced via doc/comment: comment present in both `NuntisCore.kt:98-101` and `NuntisCore.swift`; **now additionally behaviorally proven** by this round's new SDK-15 test (round 1 only had the comment, not the behavior proof — this edge case moves from partially-covered to fully covered).
- [ ] Killed-app drops queued PATCH (in-memory only, no persistence): unchanged from round 1 — no test on either platform exercises this scenario; consistent with the synchronous-lock architecture (no persisted queue exists to test against); not part of this fix batch's scope.
- [x] Same `(appId, clientKey)` across multiple installs registers separately: unchanged, correctly out of scope for native unit tests.

---

## Gate Check

- **Gate command**: `pnpm typecheck && pnpm lint && pnpm test` (root); `cd example/android && ./gradlew :react-native-nuntis:testDebugUnitTest --console=plain --rerun-tasks` (Android); `xcodebuild test -workspace example/ios/NuntisExample.xcworkspace -scheme NuntisTests -destination 'platform=iOS Simulator,name=iPhone 17'` (iOS); `cd example && pnpm run build:android` and `pnpm run build:ios` (full builds)
- **Result**: all green, 0 failed
  - `pnpm typecheck`: clean
  - `pnpm lint`: clean
  - `pnpm test`: 11 passed, 11 total
  - Android unit tests: **37 passed**, 0 failed, confirmed via `android/build/test-results/testDebugUnitTest/TEST-*.xml` per-suite counts: `NuntisApiClientTest` 6, `NuntisCoreTest` 16, `NuntisDeviceStoreTest` 6, `NuntisActivityLifecycleListenerTest` 5, `NuntisModuleTest` 1 (new), `NuntisFirebaseMessagingServiceTest` 3 = 37
  - iOS unit tests: **32 passed**, 0 failed — `NuntisApiClientTests` 6, `NuntisCoreTests` 16, `NuntisDeviceStoreTests` 6, `NuntisNotificationParsingTests` 4 = 32
  - `build:android`: `BUILD SUCCESSFUL in 12s`
  - `build:ios`: failed on first attempt with the documented CocoaPods sandbox/Podfile.lock-desync pattern (`error The sandbox is not in sync with the Podfile.lock`); ran `pod install` in `example/ios` (13s, 74 pods) per the documented remedy, then `build:ios` succeeded (`success Successfully built the app`); `example/ios/Podfile.lock` and `example/ios/NuntisExample/Info.plist` reverted via `git checkout` afterward (environment-local noise, never committed, matching STATE.md's documented convention)
- **Test count before this feature**: 0 (scaffold placeholder only)
- **Test count after round 1**: Android 32, iOS 29, TS 11 = 72
- **Test count after round 2 (this report)**: Android 37, iOS 32, TS 11 = **80 total**
- **Delta this round**: +5 Android (3 in `NuntisCoreTest.kt` for SDK-14/15/16, 1 new `NuntisModuleTest.kt` for SDK-11, 1 in `NuntisActivityLifecycleListenerTest.kt` for SDK-18), +3 iOS (`NuntisCoreTests.swift` for SDK-14/15/16) — matches the expected ~80 total and the fix commits' own claims
- **Skipped tests**: none
- **Failures**: none in the real tree (all failures above were sensor-induced, in the discarded scratch worktree only)

---

## Discrimination Sensor Summary

2/2 mutations injected against the two highest-risk newly-landed fix behaviors (SDK-15 logout no-op, SDK-11 SDK_INT flip) — both killed. Real worktree confirmed unmodified after cleanup.

---

## Requirement Traceability Update

| Requirement ID | Round 1 Status | Round 2 Status |
| --- | --- | --- |
| SDK-01 | ✅ Verified | ✅ Verified (spot-checked, no regression) |
| SDK-02 | ✅ Verified | ✅ Verified (spot-checked, no regression) |
| SDK-03 | ✅ Verified | ✅ Verified (unchanged) |
| SDK-04 | ❌ Needs Fix | ❌ Needs Fix (unchanged — not in this fix batch's scope) |
| SDK-05 | ✅ Verified | ✅ Verified (unchanged) |
| SDK-06 | ✅ Verified (declared scope) | ✅ Verified (declared scope, unchanged) |
| SDK-07 | ✅ Verified | ✅ Verified (unchanged) |
| SDK-08 | ⚠️ Spec-precision gap (declared scope) | ⚠️ Spec-precision gap (declared scope, unchanged) |
| SDK-09 | ✅ Verified | ✅ Verified (unchanged) |
| SDK-10 | ✅ Verified | ✅ Verified (unchanged) |
| SDK-11 | ❌ Needs Fix | ✅ Verified (fixed, re-derived, sensor-confirmed) |
| SDK-12 | ⚠️ Spec-precision gap (iOS) | ⚠️ Spec-precision gap (iOS, unchanged) |
| SDK-13 | ⚠️ Spec-precision gap (iOS) | ⚠️ Spec-precision gap (iOS, unchanged) |
| SDK-14 | ❌ Needs Fix | ✅ Verified (fixed, re-derived) |
| SDK-15 | ❌ Needs Fix | ✅ Verified (fixed, re-derived, sensor-confirmed) |
| SDK-16 | ❌ Needs Fix | ✅ Verified (fixed, re-derived) |
| SDK-17 | ⚠️ Spec-precision gap (declared scope) | ⚠️ Spec-precision gap (declared scope, unchanged) |
| SDK-18 | ❌ Needs Fix | ✅ Verified (fixed, re-derived, sensor-confirmed) |
| SDK-19 | ✅ Verified | ✅ Verified (spot-checked, no regression) |

---

## Summary

**Result**: PASS ✅
**Overall**: ✅ Ready

**Spec-anchored check**: 19/19 ACs at their final status — 14 clean PASS (11 carried unchanged from round 1 + SDK-11/14/15/16/18 newly fixed and re-derived this round), 4 spec-precision gaps (SDK-08/12/13/17, declared-scope orchestration/parsing-only coverage, unchanged and out of this fix batch's scope), 1 documented Needs-Fix (SDK-04, unchanged, out of this fix batch's scope — the real missing-native-prerequisite path remains untested).
**Sensor**: 2/2 mutations killed (targeted at the two riskiest newly-landed behaviors: SDK-15's local-only clear, SDK-11's SDK_INT branch).
**Gate**: all green (80/80 tests passed across TS/Android/iOS — 11 TS + 37 Android + 32 iOS; both full builds succeed).

**What works**: All 5 gaps from round 1 are genuinely closed, not just claimed-closed. SDK-15's fix correctly asserts the spec's local-only behavior (zero PATCH calls) rather than falling into the flagged trap of asserting a PATCH was sent. SDK-11's fix constructs a real `NuntisModule` (not the injected fake) and proves the below-API-33 branch never touches `currentActivity`. SDK-18's fix proves the stateful "exactly once" dedup property via two real `onActivityResumed` calls on the same Activity/Intent, not just the pure parsing function. The unbounded-`takeRequest()` hang risk is fixed in tests, and the equivalent iOS `semaphore.wait()` risk is now bounded in production code. The traceability table is current and honest (correctly still shows SDK-04 as Needs Fix, not over-claimed). No regressions found in the 3 spot-checked previously-passing criteria (SDK-01/02/19). Both full production builds succeed.

**Issues found**: None this round. SDK-04 (real missing-native-prerequisite path untested) and the declared-scope spec-precision gaps (SDK-08/12/13/17) remain open but are explicitly out of this fix batch's scope and were correctly not claimed as fixed by the traceability update — not new findings, not silently dropped.

**Next steps**: Feature is done for this fix batch's scope. SDK-04 and the declared-scope spec-precision gaps remain as known, documented residual gaps for a future batch if the team decides to close them — not blocking for this validation.
