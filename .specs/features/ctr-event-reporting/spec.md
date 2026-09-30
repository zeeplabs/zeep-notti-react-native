# CTR Event Reporting Specification

## Problem Statement

The SDK already detects `notificationReceived`/`notificationClicked` locally
(`ios/NottiPushDelegate.swift`, `android/NottiFirebaseMessagingService.kt` +
`NottiNotificationClickRelay.kt`) and hands them to the JS layer as Codegen
events — but never tells the Notti backend about them. The companion backend
spec (`ctr-tracking`, in the `zeep-notti` repo) adds `notification_id`/
`delivery_id` to every push's `data` payload and a
`POST /v1/apps/{app_id}/notifications/{notification_id}/events` endpoint
(Client-key auth, device-token ownership proof, same shape as
`PATCH .../devices/{id}`) specifically so a client can report these events.
This spec covers making the SDK actually call it — automatically, natively,
on both platforms, in every app state a receive/click can happen in
(foreground, background, killed/cold-start).

## Goals

- [ ] Every `notificationReceived`/`notificationClicked` detection that carries a `notification_id`+`delivery_id` (i.e. originated from a push this backend sent after the companion spec ships) is reported to the new endpoint automatically — zero integrator code, per AD-001.
- [ ] A failed report retries with the same policy already used for device registration/PATCH: exponential backoff, 5 attempts, terminal on any 4xx (`NottiApiClient`'s existing `executeWithRetry` classification, `android/NottiApiClient.kt:129-171`).
- [ ] An event that can't be confirmed sent before the process dies (offline, killed mid-backoff, cold-start click before native init completes) is persisted to disk and flushed on the next app launch or next network availability — no event is silently lost to a process death, only to a genuinely terminal outcome (4xx, or exhausted retries after a real delivery attempt).
- [ ] AD-001 is preserved: no new JS-visible API, no TypeScript logic change — everything lives in `NottiCore`/`NottiApiClient` (Kotlin) and their Swift equivalents.

## Out of Scope

| Feature | Reason |
| --- | --- |
| Manual JS API (e.g. `ZeepNotti.reportEvent(...)`) | Decided this session — automatic-only, no concrete use case for a manual/custom event yet. |
| Backend contract itself (endpoint, auth, schema, CTR calculation) | Owned by the companion `ctr-tracking` spec in `zeep-notti`; this spec only consumes it. |
| Any event type beyond `received`/`clicked` | Matches the backend spec's scope — no `dismissed` or other type exists server-side to report. |
| Reporting a push with no `notification_id`/`delivery_id` in `data` | Not this SDK's problem to solve — happens for pushes sent before the backend upgrade, or a non-Notti push sharing the same `UNUserNotificationCenterDelegate`/`FirebaseMessagingService`. Silently skipped (see Edge Cases), not an error. |
| Queue surviving app uninstall/reinstall | A reinstall is a new Device row server-side anyway (new token, new registration) — nothing meaningful to flush across that boundary. |
| Deduplicating a report that both succeeded and got re-queued (crash between success and disk cleanup) | The backend already tolerates duplicate `clicked` rows by design (`ctr-tracking` CTR-08, no unique constraint, CTR counts distinct devices) — an at-least-once queue is sufficient, no idempotency key needed for this endpoint. |

---

## User Stories

### P1: Automatic click reporting ⭐ MVP

**User Story**: As the Notti backend, I want every notification tap — foreground, background, or cold-start (app launched by the tap) — reported automatically, so CTR reflects real user engagement without the integrator writing any code.

**Why P1**: This is the entire reason `ctr-tracking`'s CTR field exists — without click reporting, CTR is always `0`.

**Acceptance Criteria**:

1. WHEN `NottiPushDelegate` detects a tap (`didReceive response:`, `UNNotificationDefaultActionIdentifier`) on iOS, or `NottiNotificationClickRelay.emit`/`parseClickIntentExtras` detects one on Android, AND the parsed payload's `data` contains both `notification_id` and `delivery_id` THEN the SDK SHALL call the events endpoint with `type: "clicked"`, that `delivery_id`, and the device's current token (`NottiDeviceStore.getLastToken()`/its iOS equivalent).
2. WHEN the tap is a cold start (app launched by the notification tap, before `NottiModule`/`NottiImpl` attaches) THEN the report SHALL still fire — it does not wait for or depend on any JS listener attaching, matching how `NottiNotificationClickRelay`/`NottiEventBuffer` already buffer the JS-facing event independently of native-side work.
3. WHEN the tap is a custom action button or the dismiss action (not the default tap-to-open) THEN the SDK SHALL NOT report a `clicked` event — same exclusion `NottiPushDelegate.swift:84` already applies to the JS-facing event.
4. WHEN `data` has no `notification_id`/`delivery_id` (pre-upgrade push, or a non-Notti push sharing the delegate) THEN the SDK SHALL skip reporting silently — no error, no queue entry, no log noise beyond debug level.

**Independent Test**: Send a real notification via the (already-updated) backend, background the app, tap the notification, confirm — via a backend query or test double intercepting the HTTP call — that a `clicked` event was reported with the correct `delivery_id`.

---

### P1: Automatic received reporting ⭐ MVP

**User Story**: As the Notti backend, I want a `received` event reported whenever the SDK detects a notification arriving, so this data exists for future observability even though CTR itself doesn't consume it (`ctr-tracking`'s P2 story).

**Why P1 here** (though P2 on the backend side): the SDK-side capture is the same code path/infrastructure as `clicked` reporting (same API client method, same retry/queue), so splitting it into a separate SDK priority buys nothing — it's one `type` parameter, not a second feature.

**Acceptance Criteria**:

1. WHEN `NottiPushDelegate`'s `willPresent` fires (iOS foreground) or `NottiFirebaseMessagingService.onMessageReceived` fires (Android foreground) AND the payload's `data` contains `notification_id`+`delivery_id` THEN the SDK SHALL call the events endpoint with `type: "received"`.
2. WHEN the app is backgrounded or killed THEN no `received` report is expected — this mirrors the SDK's own documented limitation (`docs/content/sdks/react-native.mdx:115-119`: `notificationReceived` only fires in the foreground) and is not a gap this spec closes; the backend's `delivered_count` (from `Delivery.status`) remains the source of truth for non-foreground delivery confirmation.

**Independent Test**: Foreground the app, send a notification, confirm a `received` event is reported with the correct `delivery_id` before any user interaction.

---

### P1: Retry parity with device registration ⭐ MVP

**User Story**: As the Notti backend/dashboard, I want a transient network failure during event reporting to be retried the same way a device registration failure is, so a flaky connection at the moment of a tap doesn't silently drop the CTR data point.

**Why P1**: Decided this session — event reporting is not treated as lower-priority than registration; both protect against the same class of transient failure.

**Acceptance Criteria**:

1. WHEN the events endpoint call fails with a network error or a `5xx` THEN the SDK SHALL retry with the same schedule `NottiApiClient.executeWithRetry` already uses for device calls: up to 5 attempts, exponential backoff starting at 2s (2s, 4s, 8s, 16s, 32s).
2. WHEN the events endpoint returns any `4xx` (e.g. `403` from a stale/mismatched token per `ctr-tracking` CTR-05, `404` from a `delivery_id` that doesn't resolve, `422` from an invalid `type`) THEN the SDK SHALL treat it as terminal — no retry, matching `executeWithRetry`'s existing `response.code < 500` branch (`android/NottiApiClient.kt:153-155`).
3. WHEN all 5 attempts are exhausted without a 2xx or a terminal 4xx THEN the event SHALL fall through to the offline-queue behavior (P2 story below), not be silently dropped.

**Independent Test**: Point the SDK at a base URL that returns 503 for the events endpoint, trigger a click, confirm 5 attempts occur with the documented backoff timing (using the same injectable-sleeper test pattern `NottiApiClient`'s own tests already use), then confirm the event lands in the persisted queue.

---

### P2: Offline / process-death queue

**User Story**: As the Notti backend/dashboard, I want a click/receive event that couldn't be reported before the app process died (no network, or killed mid-retry) to still arrive eventually, so CTR isn't systematically undercounted for exactly the users most likely to be offline right when they engage (opening the app from a notification after being offline).

**Why P2**: Decided this session — real scope increase over fire-and-forget, but explicitly chosen over dropping the event.

**Acceptance Criteria**:

1. WHEN an event is about to be reported THEN the SDK SHALL persist it to disk BEFORE the first HTTP attempt (write-ahead), not only after retries are exhausted — so a process kill at any point during the retry sequence (including before attempt 1 completes) still leaves a durable record to flush later.
2. WHEN a report ultimately succeeds (2xx) OR is classified terminal (any 4xx, per the Retry-parity story) THEN its persisted record SHALL be removed.
3. WHEN the app is launched (cold start, any reason — not just a notification tap) THEN the SDK SHALL attempt to flush every persisted, not-yet-resolved event.
4. WHEN network connectivity becomes available after having been unavailable THEN the SDK SHALL also attempt a flush (does not require waiting for the next full app launch).
5. WHEN a flushed event succeeds or hits a terminal 4xx on retry THEN it SHALL be removed from the persisted queue the same way as story 2.
6. WHEN the same event both "succeeds" server-side and remains in the persisted queue due to a crash between the 2xx response and the local cleanup THEN a duplicate flush-triggered report SHALL be allowed to happen — no idempotency mechanism required (see Out of Scope: the backend tolerates this by design).

**Independent Test**: Trigger a click with the device in airplane mode, force-kill the app, disable airplane mode, relaunch the app, confirm the event is reported exactly once more (a benign duplicate on the backend side is acceptable; total silence is not).

---

## Edge Cases

- WHEN both `notificationReceived` and `notificationClicked` fire for the same push (user foregrounds the app, sees the notification, then taps it) THEN the SDK SHALL report both events independently — not deduplicated, matching how the backend's `notification_events` table already expects multiple rows per `delivery_id` (`ctr-tracking` CTR-08).
- WHEN the device's token was refreshed (re-registered with a new token) between the push being delivered and the click being reported THEN the report's `token` field SHALL be the CURRENT token at send time (`NottiDeviceStore.getLastToken()`), which may no longer match what the backend's `Device.Token` was at original send time if the backend hasn't processed the refresh's `PATCH` yet — this SHALL surface as the standard terminal `403` (Retry-parity story, AC2), not a special case the SDK handles differently.
- WHEN a custom (non-Notti) push shares the same `UNUserNotificationCenterDelegate`/`FirebaseMessagingService` (per the SDK's documented single-delegate integration model) THEN it SHALL be excluded the same way it already is for the JS-facing event (`NottiPushDelegate.swift:60`'s `isRemotePush`/`aps` check on iOS; Android has no data-only-push ambiguity here since `notification_id`/`delivery_id` absence alone already excludes it per the Out-of-Scope skip rule).
- WHEN the persisted queue grows large (e.g. the device was offline for days with many notifications) THEN flush attempts SHALL process the backlog without blocking app startup indefinitely — exact backpressure/cap strategy is a Design-phase decision, not specified here (no product requirement yet on a cap).

---

## Requirement Traceability

| Requirement ID | Story | Phase | Status |
| --- | --- | --- | --- |
| SDKCTR-01 | P1: Automatic click reporting (basic report) | Design | Pending |
| SDKCTR-02 | P1: Automatic click reporting (cold start) | Design | Pending |
| SDKCTR-03 | P1: Automatic click reporting (exclude non-default action) | Design | Pending |
| SDKCTR-04 | P1: Automatic click reporting (skip when ids absent) | Design | Pending |
| SDKCTR-05 | P1: Automatic received reporting (foreground) | Design | Pending |
| SDKCTR-06 | P1: Automatic received reporting (no background expectation) | Design | Pending |
| SDKCTR-07 | P1: Retry parity (5x backoff on network/5xx) | Design | Pending |
| SDKCTR-08 | P1: Retry parity (terminal on 4xx) | Design | Pending |
| SDKCTR-09 | P1: Retry parity (exhausted retries → queue) | Design | Pending |
| SDKCTR-10 | P2: Offline queue (write-ahead persistence) | Design | Pending |
| SDKCTR-11 | P2: Offline queue (cleanup on success/terminal) | Design | Pending |
| SDKCTR-12 | P2: Offline queue (flush on launch) | Design | Pending |
| SDKCTR-13 | P2: Offline queue (flush on reconnect) | Design | Pending |
| SDKCTR-14 | P2: Offline queue (tolerate duplicate flush) | Design | Pending |

**Coverage:** 14 total, 0 mapped to tasks, 14 unmapped ⚠️ (expected — Design/Tasks not started yet)

---

## Success Criteria

- [ ] A real device tap (backgrounded and cold-start) results in a `clicked` row reaching the backend's `notification_events` table, verified end-to-end against a running `zeep-notti` instance with the `ctr-tracking` spec deployed.
- [ ] A simulated 503 on the events endpoint produces exactly 5 attempts with the documented backoff timing, verified via the existing injectable-sleeper unit-test pattern on both platforms.
- [ ] An event triggered in airplane mode, surviving a force-kill, is reported after connectivity returns — verified via a real or stubbed offline→online transition test on both platforms.
- [ ] Zero new exports in `src/index.tsx`/`src/NativeNotti.ts` — confirms AD-001 wasn't violated.
