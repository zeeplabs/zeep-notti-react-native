# In-App Messages Tasks

**Design**: `.specs/features/in-app-messages/design.md`
**Spec**: `.specs/features/in-app-messages/spec.md`
**Status**: Not started (specs written 2026-10-18, amended 2026-10-19). 30 tasks: T1 JS facade, T2-T13 Android, T14-T25 iOS, T26-T30 docs / example / review / device validation. One task = one commit (Conventional Commits, confirm the message with the owner before committing, never `--no-verify`).

Decided by Julio on 2026-10-18 and already folded in: the integrator handles links through a JS click listener (the SDK never opens a link, A9), `trackEvent` names before the `eligible` response are remembered (max 32, A14), a single-attempt pre-`eligible` flush with `eligible` called regardless and `Retry-After` clamp 1..300 s / 60 s default / 3 waits (A15; the `eligible` part is superseded by the 2026-10-19 cap below), `403` keeps the queue with no forced re-registration and logs a fixed "In-App inactive on this device until the next registration" warning (A16), close label from an in-code en/pt-BR table with English fallback (A18), session/selection model aligned with the iOS SDK (A17), default palette = semantic system colors with no luminance derivation (A13), image limit 5 MiB. Decided by Julio on 2026-10-19 and folded in: `margin` is measured from the safe-area edge and `margin: false` touches the safe-area edges on all sides (A12); the `403` warning is logged only on `403`, once per session per route, while a `401` stops the flush and the fetch for the session and logs only the generic line (A16); on Android `center`/`full` consume the system Back and bars do not intercept it (A19, DD-10); `trackEvent` names after `initialize` and before the first session are remembered via an `awaitingFirstSession` flag (A14, [Provável], to validate on device); `eligible` `429` gives up above 60 s, otherwise waits `max(1, Retry-After)` s up to 3 times (A15); a late `eligible` response is discarded (SDKIAM-15); re-`initialize` with a different config resets the engine and queue records carry `app_id` (SDKIAM-70); renderability parity with iOS IAM-16 (SDKIAM-14). Each task states the recommended default for decisions it depends on; the owner can overrule before that task starts without changing the task graph.

---

## Test Coverage Convention (derived from `AGENTS.md` and `CONTRIBUTING.md`)

| Code layer | Test type | Command | Evidence |
| --- | --- | --- | --- |
| Android native (`android/src/main/java/com/notti/`) | JVM unit (JUnit 4) + Robolectric for framework classes + `MockWebServer`; explicit `takeRequest(timeout, unit)` (L-003) | `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest` | `AGENTS.md` Commands; `android/build.gradle:58-67`; 8 existing test classes already use Robolectric |
| iOS native (`ios/*.swift`) | XCTest (`NottiTests` scheme), `StubURLProtocol`, injected ports (no `UIApplication.shared`, no `UNUserNotificationCenter.current()` in testable paths: hostless bundle) | `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'` | `AGENTS.md`; `ios/Tests/*.swift`; `STATE.md` T8 notes |
| TS facade (`src/`) | Jest | `pnpm typecheck && pnpm lint && pnpm test` | `src/__tests__/index.test.tsx` |
| Docs / example / plugin | Build gates only | `pnpm run build:android && pnpm run build:ios` | `AGENTS.md` Definition of done |

L-001: a Jest test only proves forwarding. Every behavioral requirement is tested at the native layer that implements it.

### Test Coverage Matrix

| Code layer created or modified | Required tests | Task(s) |
| --- | --- | --- |
| Parser / color | unit tables (valid, malformed, unknown fields) | T2, T14 |
| Event store | unit (persistence across instances, order, cap, TTL, corruption, UUID stability) | T3, T15 |
| API client (eligible, events) | unit with MockWebServer / StubURLProtocol (request shape, `Retry-After`, per-status classification) | T4, T16 |
| Session state machine + display clock | unit tables | T5, T17 |
| Coordinator | integration of real store + real client + fake presenter/scheduler (ordering, once per session, flush rules, no `PATCH /devices`) | T6, T18 |
| Style / layout metrics | unit tables | T7, T19 |
| Views | Robolectric view tests (Android); UIKit view tests in a plain `UIView(frame:)` (iOS) | T8-T9, T20-T21 |
| Presenter lifecycle | Robolectric `ActivityController` (Android); fake scene provider (iOS); real window = T30 | T10, T22 |
| Image loader | MockWebServer / StubURLProtocol | T11, T23 |
| Click delivery to the JS listener (emit bridge, payload, no-listener rule) | unit (coordinator + module bridge / `Notti.mm` handler) + repository grep gate for URL-opening APIs | T12, T24, T29 |
| Wiring (core hooks, module, observers, shim) | existing suites extended + end-to-end flow test | T13, T25 |
| JS facade | Jest forwarding | T1 |
| Docs, privacy manifest comment, example | build gates + diff review | T26-T28 |
| Cross-platform parity | review checklist + full gates | T29 |
| Real window, gestures, VoiceOver/TalkBack, RN reload, offline kill | manual scenarios | T30 |

### Gate Check Commands

- Android `quick`/`full` (same command): `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest`
- iOS `quick`/`full` (same command): `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'`
- JS `quick`/`full`: `pnpm typecheck && pnpm lint && pnpm test`
- Definition of done (T29 and before opening the PR): `pnpm typecheck && pnpm lint && pnpm test && pnpm run build:android && pnpm run build:ios`, plus both native test commands. If no JDK is on `PATH`, point `JAVA_HOME` at Android Studio's JBR and run `cd example && pnpm run build:android` (`AGENTS.md` Known gotchas).
- After native project edits: `pod install` in `example/ios` if the build says "sandbox is not in sync"; revert `Podfile.lock`/`Info.plist` noise instead of committing it.

---

## Execution Plan

```
Phase 0 (shared prerequisite, makes native compile with the new Spec method):
  T1

Phase 1 (platform-parallel; sequential inside a platform):
  Android: T2 -> T3 -> T4 -> T5 -> T6 -> T7 -> T8 -> T9 -> T10 -> T11 -> T12 -> T13
  iOS:     T14 -> T15 -> T16 -> T17 -> T18 -> T19 -> T20 -> T21 -> T22 -> T23 -> T24 -> T25

Phase 2 (needs both chains):
  T13, T25 -> T26 -> T27
  T13, T25 -> T28
  T26, T27, T28 -> T29 -> T30
```

T1 gates everything because `NativeNottiSpec` (Android codegen) gains an abstract method: native code does not compile against the new Spec without it, hence the explicit no-op stubs in T1 that T13/T25 replace.

---

## Task Breakdown

### T1: JS facade + Codegen spec + native compile stubs

**What**: Add `trackEvent(name: string): void` and the click-listener API (`Notti.InAppMessages.addClickListener`, Codegen emitter `onInAppMessageClicked`) to the Codegen spec and facade; add temporary no-op native implementations so both platforms compile.
**Where**: `src/NativeNotti.ts` (after `getDeviceId`, `:53`), `src/index.tsx` (function + `Notti` export, `:131-190`), `src/__tests__/index.test.tsx` (`NativeNotti` mock, `:21`), `android/src/main/java/com/notti/NottiModule.kt` (`override fun trackEvent(name: String?) = Unit`), `ios/NottiImpl.swift` + `ios/Notti.mm` (`trackEvent:` forwarding to an empty Swift method).
**Depends on**: None
**Reuses**: `getDeviceId` wiring on all four layers
**Requirement**: SDKIAM-58, SDKIAM-59 (partial), SDKIAM-60, SDKIAM-61 (code part), SDKIAM-67 (JS surface)

**Done when**:
- [ ] `Spec.trackEvent(name: string): void` declared with a doc comment stating exact-match, local-only, never sent to the server
- [ ] `Notti.trackEvent` exported and forwards the exact string unchanged (no trimming, no case change)
- [ ] Jest: `trackEvent('checkout_done')` calls `NativeNotti.trackEvent` once with exactly that string
- [ ] `NativeNotti.ts` declares `InAppClickPayload { messageId, buttonId, action?: { type, value } | null }` and `readonly onInAppMessageClicked: CodegenTypes.EventEmitter<InAppClickPayload>`; `Notti.InAppMessages.addClickListener(handler)` returns the `EventSubscription` from `NativeNotti.onInAppMessageClicked(handler)`; `NottiInAppClick`/`NottiInAppAction` types exported
- [ ] Jest: `addClickListener` passes the payload to the handler unchanged and `remove()` stops delivery; the `NativeNotti` mock gains `trackEvent` and `onInAppMessageClicked`
- [ ] Android builds (`NottiModule` overrides the generated abstract method) and iOS builds (`Notti.mm` shim method present); both stubs carry a `TODO(T13)` / `TODO(T25)` comment naming the task that replaces them
- [ ] No other public JS surface added (`git diff src/` shows only `trackEvent` and `InAppMessages.addClickListener` with its types)
- [ ] Gates: `pnpm typecheck && pnpm lint && pnpm test`, `pnpm run build:android`, `pnpm run build:ios`, both native test commands still green (unchanged counts)

**Tests**: unit (Jest) + build
**Gate**: full

**Commit**: `feat: add Notti.trackEvent and the in-app click listener to the JS facade and Codegen spec`

---

## Android chain

### T2: Android - In-App models, tolerant parser and color parsing

**What**: Pure data types and parsing of the `eligible` response; hex color parser. Actions are parsed, never validated or rewritten.
**Where**: `android/src/main/java/com/notti/NottiInAppModels.kt` (new), `android/src/test/java/com/notti/NottiInAppModelsTest.kt` (new)
**Depends on**: T1
**Reuses**: `org.json` (JVM artifact in tests, `android/build.gradle:63`)
**Requirement**: SDKIAM-07, SDKIAM-14, SDKIAM-26 (parse part), SDKIAM-36 (range part)

**Done when**:
- [ ] `parseEligibleResponse(body)` returns messages with: unknown fields ignored; unknown `format` -> `center`; message entries that cannot be parsed skipped without failing the rest; `messages: []` valid; non-object body -> parse failure signal
- [ ] Non-renderable marking (SDKIAM-14): empty id, title and body both blank, unknown trigger type, `event` trigger with empty name; a button is kept only with a non-empty `id` and `label`, then at most the first 2 VALID buttons are kept (an invalid button is dropped without making the message non-renderable); an `image_url` that is not `https` is ignored and an `image_action` without an image is ignored too; an unknown `format` -> `center` with the rest unchanged; an unknown `action.type` keeps the message renderable and yields `action = null`; `action.value` is kept byte for byte
- [ ] Tests for the SDKIAM-14 additions: button with empty/missing `id` or `label` dropped, three buttons with the first invalid keep the next two valid ones, `http://` and relative `image_url` ignored (no image), `image_action` with no image ignored, unknown `format` renders `center` with title, body, buttons and style unchanged
- [ ] `parseHexColor`: `#RRGGBB` upper/lower case valid; `#RGB`, `#RRGGBBAA`, no `#`, non-hex, empty, whitespace -> `null`; never throws
- [ ] `dismiss_after_seconds` outside 1..300, null or absent -> no timer value
- [ ] Fixtures use only synthetic values (`example.invalid`, all-zero UUIDs, `fixture`)
- [ ] Unit tests (tables) for every bullet above
- [ ] Gate: Android command, test count grows, no test removed

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): parse in-app eligible messages tolerantly`

---

### T3: Android - `NottiInAppEventStore`

**What**: Persisted write-ahead queue of In-App events with `event_id`, TTL and cap.
**Where**: `android/src/main/java/com/notti/NottiInAppEventStore.kt` (new), `android/src/test/java/com/notti/NottiInAppEventStoreTest.kt` (new)
**Depends on**: T2 (event/outcome types)
**Reuses**: `NottiEventStore.kt:54-160` persistence style (JSON array under one key, static lock `:77`, corruption self-heal `:111`); fake `SharedPreferences` from `NottiEventStoreTest.kt`
**Requirement**: SDKIAM-41, SDKIAM-44, SDKIAM-45, SDKIAM-46, SDKIAM-51, SDKIAM-70 (record/purge part)

**Done when**:
- [ ] Key `notti_pending_inapp_events` in `notti_prefs`; record `{id, eventId, appId, messageId, type, buttonId?, reason?, occurredAtMs}` (`appId` = the app the event was created for); no token, no device id stored
- [ ] `enqueue(...)` generates a UUID v4 `eventId` and persists immediately; ids are unique and stable across reads and across a new store instance over the same prefs
- [ ] `all()` returns insertion order; `remove(id)`; expired events (> 7 days by `occurredAtMs`) are dropped at enqueue and exposed as dropped by an `expire(now)` call used at flush
- [ ] Cap 100, oldest dropped first; corrupt blob self-heals to empty; process-wide lock
- [ ] `purgeOtherApps(appId)` removes every record whose `appId` differs and keeps the rest in order; `all(forApp)` (or an equivalent filter) never returns another app's records (SDKIAM-45, SDKIAM-70)
- [ ] Independent of `NottiEventStore`: filling one never evicts the other (test with both over the same prefs)
- [ ] Unit tests for each bullet (persistence across instances, order, cap, TTL boundary at exactly 7 days, corruption, independence from CTR store, `appId` round trip, purge of other apps with mixed records)
- [ ] Gate: Android command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): add persisted in-app event queue`

---

### T4: Android - `NottiApiClient` In-App endpoints (single attempt, `Retry-After`)

**What**: `fetchEligibleInAppMessages` and `reportInAppEvent` over a new private `executeOnce`; outcome types per the design table.
**Where**: `android/src/main/java/com/notti/NottiApiClient.kt` (modify; `executeWithRetry` `:267` untouched), `android/src/test/java/com/notti/NottiApiClientTest.kt` (extend)
**Depends on**: T2
**Reuses**: segment-by-segment URL building (`:199`, `:212`), `jsonMediaType`, `Authorization: Bearer` header pattern
**Requirement**: SDKIAM-01 (shape), SDKIAM-05, SDKIAM-06, SDKIAM-47, SDKIAM-48, SDKIAM-49, SDKIAM-54

**Done when**:
- [ ] `eligible`: `POST /v1/apps/{appId}/in-app-messages/eligible`, header `Authorization: Bearer <key>`, body keys exactly `device_id` and `token`
- [ ] `events`: `POST .../in-app-messages/{id}/events`, body `device_id`, `token`, `event_id`, `type`, plus `button_id` only for `click`, `reason` only for `dismiss`, `occurred_at` RFC3339 UTC
- [ ] Classification: 200 -> messages; 201/200 events -> Recorded; 404/422 -> Drop; 429 -> RateLimited(seconds? integer only, else null; the coordinator applies the events clamp 1..300 / 60 s default and the `eligible` give-up above 60 s); 401 -> Unauthorized and 403 -> Forbidden (distinct outcomes on both routes, so the coordinator logs the right line); 408, 5xx, IO error, unparseable 2xx -> Transient on both routes (`408` follows the `5xx`/network policy); other 4xx -> Drop (events) / Terminal (eligible)
- [ ] One request per call (no internal retry or sleep); `executeWithRetry` behavior and its tests unchanged
- [ ] `appId` containing `/`, `?`, `#` cannot rewrite the path (segment encoding)
- [ ] No log line contains token, ids, URL or body
- [ ] MockWebServer tests with `takeRequest(5, TimeUnit.SECONDS)`: request shape, each status class (401 and 403 asserted as different outcomes; events `408` -> Transient), `Retry-After: 2`, absent header, `Retry-After: 0`, `Retry-After: 9999`, `Retry-After: Wed, 21 Oct 2026 07:28:00 GMT` -> null, empty body 201, `200 {"duplicate":true}`
- [ ] Gate: Android command; all pre-existing `NottiApiClientTest` tests pass unmodified

**Tests**: unit (MockWebServer)
**Gate**: quick

**Commit**: `feat(android): add in-app eligible and events requests`

---

### T5: Android - session state machine and display clock (pure)

**What**: The selection logic and visible-time accounting, with no Android classes.
**Where**: `android/src/main/java/com/notti/NottiInAppSession.kt` (new), `android/src/test/java/com/notti/NottiInAppSessionTest.kt` (new)
**Depends on**: T2
**Reuses**: nothing platform-specific (injectable monotonic clock)
**Requirement**: SDKIAM-08..15, SDKIAM-36..39 (clock part), SDKIAM-40 (flag part), SDKIAM-59 (engine part), SDKIAM-70 (engine part)
**Decision implemented**: A14 (remember pending names, max 32, replay once on arrival, including the `awaitingFirstSession` window), SDKIAM-15 late response, SDKIAM-70 reset

**Done when**:
- [ ] `onSessionStarted`/`onSessionEnded` with an incrementing `sessionToken`; stale tokens rejected
- [ ] `onFetched`: first renderable `session_start` shown, others not queued; `event` messages held in order; `Show` dropped when a display exists or the id is already in `shownIds`
- [ ] `trackEvent`: exact case-sensitive match, oldest held, not shown twice, ignored while a display is pending/visible (held untouched), pending names (max 32) replayed once after `onFetched`
- [ ] `awaitingFirstSession` (set by `onInitialized` when no session has opened in the process, cleared by the first `onSessionStarted`): a name reported after `onInitialized` and before the first `onSessionStarted` is remembered (same 32 cap), survives the session start and is replayed once with that first session's held messages; a name reported before `onInitialized`, or with `phase == Closed` after a session already ran, is ignored (no log of the name); `onSessionEnded` with no session open does not clear the awaiting names
- [ ] `fetchGeneration`: an `onFetched` whose generation is stale (session ended, new session started, config changed) is discarded: no `Show`, nothing held, even when a newer session is open; held `event` messages dropped at `onSessionEnded` (SDKIAM-15)
- [ ] `onInitialized`: same config -> state untouched; different config -> `held`, `pendingNames`, `shownIds`, `fetch` (back to `Idle`), pause deadlines and warning flags reset, `fetchGeneration` incremented, display torn down with a decision the coordinator turns into a silent teardown (no terminal outcome, no event)
- [ ] Display states Preparing/Visible/Closed; `markVisible` returns true only once (impression decision); `markClosed` produces exactly one terminal outcome (Click | Dismiss) and never both; no terminal outcome before visible
- [ ] Session end: held and pending names cleared; visible display kept and its id carried into the next session's `shownIds` (DD-8)
- [ ] `DisplayClock`: running only while attached and app foreground; pause/resume preserves remaining time; fires at remaining time; value outside 1..300 -> no clock
- [ ] Table tests for each bullet, including races (stale token after session restart, double `markVisible`, `markClosed` twice, response arriving after session end, `onInitialized` immediately followed by `trackEvent` before any `onSessionStarted`)
- [ ] Gate: Android command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): add in-app selection state machine and display clock`

---

### T6: Android - `NottiInAppCoordinator` (fetch sequence, flush, scheduling)

**What**: The process-wide orchestrator: flush-then-fetch per session, event flush rules, retries via a scheduler, presenter callbacks to events, `trackEvent` entry, `NottiInApp` holder. No wiring into core/module yet.
**Where**: `android/src/main/java/com/notti/NottiInAppCoordinator.kt` (new), `android/src/test/java/com/notti/NottiInAppCoordinatorTest.kt` (new); behavior-preserving extraction of `formatIsoUtc` (`NottiCore.kt:675`) into a top-level internal function used by both
**Depends on**: T2, T3, T4, T5
**Reuses**: `NottiCore.scheduleFlush` single-flight idea (`:503`); `NottiApiClient` outcomes; retry constants (`:82`)
**Requirement**: SDKIAM-01..06, SDKIAM-08, SDKIAM-09, SDKIAM-10..13, SDKIAM-15 (late response), SDKIAM-40..52, SDKIAM-54, SDKIAM-59 (coordinator part), SDKIAM-70
**Decisions implemented**: A15 (single-attempt flush then `eligible` regardless except after `401`; events `Retry-After` clamp; `eligible` `429` cap), A16 (no forced re-registration; `403` warning only; `401` session stop), A14 (`onInitialized` before the first session), DD-14 (re-initialize); no link handling in the SDK (A9)

**Done when**:
- [ ] Own single-thread daemon `ScheduledExecutorService` (`notti-inapp`); state mutated on an injectable "main" poster; no `Thread.sleep`
- [ ] Fetch triggers only when session open + identity available + fetch `Idle`; exactly one successful `eligible` per session; no refetch on `onRegistered` repeats, token refresh or core re-creation
- [ ] A `singleAttempt` flush runs before `eligible` (one attempt per event, strict FIFO, stop at the first failure) and `eligible` is sent **regardless** of the flush outcome, except that a `401` in the flush sets `keyRejected` and skips `eligible`; remaining events stay queued; `GaveUp(transient)` resumes once per `onNetworkAvailable` within the session, never after 401/403/422 or exhausted 429 waits
- [ ] `eligible` 429: a parsed `Retry-After` above 60 s -> give up for the session with no wait and no second request; otherwise no call before `max(1, Retry-After)` s (60 s when absent or invalid), non-blocking wait, retry, at most 3 waits then give up for the session; 401/403/422 stop the fetch; 408/5xx/IO backoff 2/4/8/16 s, 5 attempts; constants (including the 60 s give-up threshold) in one adjustable place
- [ ] `403` on `eligible` or events logs the one fixed warning that In-App is inactive on this device until the next registration, **once per session per route** (events and `eligible` have separate flags, reset at session start), no ids, no values; a `401` on either route sets `keyRejected` (flush and fetch stop for the rest of the session, queue kept, no re-registration) and logs only the generic operation+status line, never the warning text (asserted on captured logger output for both statuses)
- [ ] Event flush: single-flight and coalesced (`full` and `singleAttempt` modes); strict FIFO; Recorded and 404/422 remove the head; 429 pauses on a stored deadline (same clamp, shared by later triggers, independent of the `eligible` pause); transient: `full` retries the same head with the same `event_id` (5 attempts) then stops, `singleAttempt` stops at the first failure; 403 stops and keeps the queue (no re-registration; later triggers retry), 401 stops for the session and keeps the queue; events `408` follows the `5xx`/network policy; expired events dropped before sending; only records whose `appId` equals the current app id are sent
- [ ] Presenter callbacks: `onVisible` -> exactly one `impression` enqueued synchronously, then flush trigger; close -> one `click` (with `button_id`: button id, `image`, or first button id for bar body) or one `dismiss` (with reason); never both
- [ ] Click order (SDKIAM-33): `click` enqueued, then the `ClickSink` port is called with `(messageId, buttonId, action untouched)`, then the display is closed with no `dismiss`; a second tap on a closing display is ignored; with no sink target the click is still reported and closed, and one fixed warning is logged (SDKIAM-68); the coordinator calls no URL-opening API
- [ ] `trackEvent` blank, before `initialize`, or in the background after a session ran -> no-op; between `initialize` and the first session -> remembered (A14); never throws; never sends or logs the name
- [ ] `onInitialized(config)` is called before the first `onSessionStarted` (hook contract); same config -> nothing; different config -> engine reset (T5), in-flight `eligible` response and pending retries/waits discarded, the presenter asked to tear the display down silently (no event), `purgeOtherApps(appId)` on the store, pause deadlines cleared, and the next registration under the new config triggers one `eligible`
- [ ] A response to `eligible` arriving after its session ended (or after a config change) is discarded: no display, no held messages; held `event` messages dropped at session end
- [ ] Identity read at call time; `null` identity defers to the next trigger (no crash)
- [ ] Integration tests (real store, real client over MockWebServer, fake presenter and scheduler, `takeRequest(5, SECONDS)`): request-order assertions (events before `eligible`, and `eligible` still sent when the events route answers 503/429/403; impression before click), `eligible` count == 1 across a simulated RN reload (new core, same coordinator), no `PATCH /devices` in the request log, 429 timing (events: clamp 1..300, 60 s default, pause deadline; `eligible`: `Retry-After: 120` -> no retry and no second request, `Retry-After: 2` -> retry after 2 s, absent -> 60 s, 3 waits then give up), `403` warning once per session per route and `401` generic line with the session stop, events `408` backoff, `200 duplicate`, event_id identical across a retry, 8-day-old event never sent, a late `eligible` response after session end shows nothing and holds nothing, a different-config re-initialize resets state, tears the display down without events, discards the in-flight response and never sends the other app's records (purged), a same-config re-initialize keeps everything, **race test: `initialize` immediately followed by `trackEvent` on the same thread still matches once the first session's held messages arrive**
- [ ] Logs contain no token, device id, ids, URLs, titles or event names (assert on captured logger output)
- [ ] Gate: Android command

**Tests**: unit + integration
**Gate**: quick

**Commit**: `feat(android): add in-app coordinator for session fetch and event flush`

---

### T7: Android - style resolver and layout metrics (pure)

**What**: Semantic default palette (resolved from system theme attributes through an injected provider), margin/align resolution, bounds per layout. No luminance or contrast logic.
**Where**: `android/src/main/java/com/notti/NottiInAppStyle.kt` (new), `android/src/test/java/com/notti/NottiInAppStyleTest.kt` (new)
**Depends on**: T2
**Reuses**: nothing platform-specific
**Requirement**: SDKIAM-16..19, SDKIAM-26..30
**Decision implemented**: A13 (semantic system colors, no derivation), A12 (margin measured from the safe-area edge)

**Done when**:
- [ ] Defaults come from the injected semantic palette (Android theme attributes with the documented fallback; iOS semantic colors) and match the design table; `style: null` -> all defaults
- [ ] Invalid color token -> that token's default, others applied
- [ ] `text_align` absent/unknown -> left; `margin` absent -> true; inset 16 measured **from the safe-area edge** for top/bottom/full (all four sides on `full`), ignored for center; `margin: false` -> the frame equals the safe-area edges on all sides, horizontally too (landscape cutout/navigation insets included), never the raw screen edge; tested with non-zero safe-area insets on all four sides
- [ ] `button_color`/`button_text_color` apply to all buttons; neither set -> first filled, second tinted (design "Default look")
- [ ] With only `background_color` set, `text_color` and the button colors stay at their semantic defaults (explicit test that no color is derived or adjusted)
- [ ] Metrics: bar height <= 40% of container, bar width = safe-area width minus 16 per side when `margin`, card width <= 90% and <= 560, full inside safe area; table-tested at several container sizes (phone, small phone, tablet, landscape)
- [ ] Gate: Android command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): add in-app style resolver and layout metrics`

---

### T8: Android - view factory for the four layouts

**What**: Programmatic Views for `top`, `center`, `bottom`, `full` (static rendering: content, image slot, buttons, close control, insets, scroll, plain text).
**Where**: `android/src/main/java/com/notti/NottiInAppViewFactory.kt` (new), `android/src/test/java/com/notti/NottiInAppViewFactoryTest.kt` (new, Robolectric)
**Depends on**: T7
**Reuses**: T7 metrics and style; Robolectric (`android/build.gradle:67`)
**Requirement**: SDKIAM-16..21, SDKIAM-23, SDKIAM-24, SDKIAM-27..31, SDKIAM-64
**OQ default implemented**: none new; verifies `androidx.core` availability for insets (do not add a dependency for it)

**Done when**:
- [ ] Each layout built per design: bars with leading thumbnail slot, center card over a 50% black backdrop, full inside safe area with buttons pinned bottom; scroll container for title/body
- [ ] Title/body set from the raw string; no `Html.fromHtml`, no `Linkify`/`autoLink`, no spans; newlines preserved
- [ ] Two buttons side by side, wrapping to a column when they do not fit (measured), at default and 2.0 font scale
- [ ] Close control always present, >= 48 dp, never removed by style, timer or content size
- [ ] Insets applied (system bars + cutout) with API-level branching; `margin` adds 16 dp measured from the safe-area edge; `margin: false` touches the safe-area edges on all sides (horizontal insets included) and is never under the status bar, cutout or navigation bar
- [ ] Style applied (colors, align, button tokens), light/dark defaults resolved from the Activity configuration
- [ ] Robolectric tests: each layout at phone/tablet, portrait/landscape, font scale 1.0/2.0, light/dark: bounds respected (bar <= 40%, card <= 90%), `margin` true/false against non-zero insets (16 from the safe-area edge vs touching it, horizontally too), close control present and large enough, plain-text assertions (`HTML` and Markdown literals render verbatim, no `URLSpan`), two-button wrap, alignment and colors
- [ ] Gate: Android command

**Tests**: unit (Robolectric)
**Gate**: quick

**Commit**: `feat(android): render in-app message layouts with native views`

---

### T9: Android - interactions and accessibility

**What**: Gestures and taps with callbacks (`onClose(reason)`, `onAction(buttonId|image|first)`), accessibility semantics.
**Where**: `android/src/main/java/com/notti/NottiInAppViewFactory.kt` (modify) + `NottiInAppAccessibility` helpers in the same file or a new `NottiInAppAccessibility.kt`, tests in `NottiInAppViewFactoryTest.kt` (extend)
**Depends on**: T8
**Reuses**: touch slop/velocity from `ViewConfiguration`
**Requirement**: SDKIAM-21, SDKIAM-22, SDKIAM-33..35, SDKIAM-39, SDKIAM-63
**Decision implemented**: A18 (in-code en/pt-BR table for the close label, English fallback for any other language)

**Done when**:
- [ ] Close control -> `close_button`; `top` swipe up and `bottom` swipe down beyond the threshold -> `swipe` (and a short drag does not dismiss); `center` backdrop tap -> `outside_tap`, tap inside the card does nothing; `full` has no other dismiss gesture; the view itself does not handle the back key (the presenter owns the Back consumption on `center`/`full`, T10)
- [ ] Button tap -> action callback with the button id; image tap (only with `image_action` and a loaded image) -> `image`; bar body tap with >= 1 button -> first button id; no buttons -> body not tappable; center/full body not tappable
- [ ] Touches outside a `top`/`bottom` bar are not consumed (dispatch test)
- [ ] Accessibility: close `contentDescription` from the table (en, pt-BR, fallback en), buttons announce their label and the Button role, title is a heading where the API allows, `center`/`full` hide siblings from accessibility while shown and restore the previous values exactly on removal, bars announce without taking focus
- [ ] Robolectric tests with synthetic `MotionEvent`s for every gesture/tap above and for the save/restore of sibling accessibility flags
- [ ] Gate: Android command

**Tests**: unit (Robolectric)
**Gate**: quick

**Commit**: `feat(android): add in-app gestures, taps and accessibility`

---

### T10: Android - overlay presenter, Activity tracker, impression and auto-dismiss lifecycle

**What**: Attach the overlay to the resumed Activity, survive recreation/Activity changes, raise `onVisible` once, drive the display clock and `auto` dismiss.
**Where**: `android/src/main/java/com/notti/NottiInAppPresenter.kt` (new: `Presenter` port impl + `NottiInAppActivityTracker`), `android/src/test/java/com/notti/NottiInAppPresenterTest.kt` (new, Robolectric `ActivityController`)
**Depends on**: T5, T9
**Reuses**: `Application.ActivityLifecycleCallbacks` registration pattern (`NottiActivityLifecycleListener.kt:77-91`)
**Requirement**: SDKIAM-15, SDKIAM-17, SDKIAM-22 (Back), SDKIAM-25, SDKIAM-33, SDKIAM-36..40, SDKIAM-70 (silent teardown)
**Decision implemented**: A19 / DD-10 (Back consumed on `center`/`full`)

**Done when**:
- [ ] Overlay added to `android.R.id.content` of the resumed Activity; removed on pause/destroy; re-attached (new views, same `Display`) on the next resume of the same or another Activity
- [ ] `onVisible` raised once after the first layout while the process is started; repeated attaches (recreation, Activity A -> B) never raise a second impression (coordinator flag and presenter both asserted)
- [ ] No resumed Activity -> display stays Preparing, no impression; session end while Preparing -> dropped, no events
- [ ] Display clock runs only while attached and in the foreground; backgrounding or detaching pauses it; the remaining time survives recreation; at zero the display closes with `auto`; a manual close cancels it
- [ ] Click/dismiss closes the overlay and restores host accessibility flags; `teardownSilently()` (config-change re-initialize) removes the overlay, stops the clock, restores the flags and enqueues no event
- [ ] Back (DD-10, A19): while a `center`/`full` display is attached the presenter holds an enabled no-op `OnBackPressedCallback` on the Activity's `onBackPressedDispatcher` (plus the API 33+ `OnBackInvokedCallback` path and the pre-33 key-listener fallback when the Activity is not a `ComponentActivity`); it is removed on pause/destroy, Activity change, close and silent teardown and re-registered on the new Activity's attach; `top`/`bottom` register nothing; verified that `androidx.activity` is on the compile classpath transitively without adding a dependency [Incerto]; the mechanism is validated on a real device in T30 scenario 26
- [ ] Robolectric tests: Back on a `center` and on a `full` display leaves it visible, enqueues no `impression`/`click`/`dismiss`, and does not reach a host `OnBackPressedCallback` registered before the display; Back on `top`/`bottom` reaches the host callback; the callback is gone after close, Activity detach and silent teardown; `ActivityController.recreate()` keeps the same display and exactly one `impression`; A -> B transition moves the overlay; pause/resume math with a fake clock; `auto` dismiss; no-Activity wait; `ShadowLooper` for posted work
- [ ] Gate: Android command

**Tests**: unit (Robolectric)
**Gate**: quick

**Commit**: `feat(android): present in-app messages over the resumed activity`

---

### T11: Android - image loader and presenter integration

**What**: Bounded `https` image download with a credential-free client, in-memory cache, 3 s wait, failure -> no image.
**Where**: `android/src/main/java/com/notti/NottiInAppImageLoader.kt` (new), `android/src/main/java/com/notti/NottiInAppPresenter.kt` (modify: prepare step), `android/src/test/java/com/notti/NottiInAppImageLoaderTest.kt` (new)
**Depends on**: T10
**Reuses**: OkHttp (already a transitive dependency of `NottiApiClient`), `MockWebServer`
**Requirement**: SDKIAM-20, SDKIAM-35 (image tappable only when loaded), SDKIAM-57
**Tunables**: A11 (3 s wait, 10 s timeout, 5 MiB, downsample)

**Done when**:
- [ ] Non-`https` URL rejected before any connection; separate client with no `Authorization`, no cookies, `followSslRedirects(false)`; a redirect to `http` is refused
- [ ] Download aborted past 5 MiB; decode downsampled to the layout slot; undecodable body -> no image
- [ ] LRU cache (5 entries, memory only, no disk)
- [ ] The message waits at most 3 s for the image, then shows without it; a late image is not inserted into a visible message
- [ ] Image failure leaves a valid message; `image_action` without a loaded image is not tappable
- [ ] Tests (MockWebServer, `takeRequest(5, SECONDS)`): request has no `Authorization` or `Cookie` header; oversize abort; redirect refusal; timeout path; cache hit makes no second request; presenter shows without image on failure
- [ ] Gate: Android command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): load in-app images with bounded credential-free requests`

---

### T12: Android - click delivery to the JS listener (no link opening)

**What**: Bridge the coordinator's click to the live module's generated `emitOnInAppMessageClicked`; implement the no-listener rule. The SDK opens nothing.
**Where**: `android/src/main/java/com/notti/NottiModule.kt` (companion `emitInAppClick(...)` + instance `emitInAppClick` using the generated emitter, same shape as `emitNotificationReceived`, `:531`), `android/src/main/java/com/notti/NottiInAppCoordinator.kt` (production `ClickSink`), tests in `NottiModuleTest.kt` and `NottiInAppCoordinatorTest.kt` (extend)
**Depends on**: T6, T10, T1
**Reuses**: `NottiModule.activeInstance` bridge pattern; `NottiNotificationClickRelay` is NOT used (no cold-start buffer, A9)
**Requirement**: SDKIAM-32, SDKIAM-33..35, SDKIAM-67, SDKIAM-68
**Decision implemented**: A9 (integrator handles links; no buffer)

**Done when**:
- [ ] Payload keys exactly `messageId`, `buttonId`, `action` (`{type, value}` or `null`; `null`, never absent, for an unknown type); `value` byte for byte; no validation, no rewriting, no logging of any of them
- [ ] No live module (`activeInstance == null`, e.g. between RN reloads): the click is still reported and the display closed, nothing is buffered or replayed to a later listener, one fixed warning is logged without values
- [ ] Emit happens on the thread RN requires, after the `click` is enqueued and before the display closes (order asserted)
- [ ] No URL-opening API anywhere in the In-App sources: `git grep -nE "ACTION_VIEW|startActivity|Uri\.parse|Intent\(" android/src/main/java/com/notti/NottiInApp*` returns nothing (also run in T29)
- [ ] `git diff android/src/main/AndroidManifest.xml` empty
- [ ] Tests: button, image and bar-body clicks produce the expected `buttonId` and action; unknown action type -> `action = null`; no module -> reported + closed + warning once + not replayed when a module appears later
- [ ] Gate: Android command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(android): deliver in-app clicks to the JS listener without opening links`

---

### T13: Android - wiring (core hooks, module, observers) and end-to-end flow

**What**: Connect the coordinator to the session gate, registration, network observer, foreground/background, and replace the `trackEvent` stub.
**Where**: `NottiCore.kt` (`inApp` hooks at `:436`, `:491`, `:503`, `:710`), `NottiModule.kt` (real `trackEvent`, core factory `:106`), `NottiInitProvider.kt` (`install` + tracker at `:41-46`; `handleProcessBackground` `:140`; `onStart` `:121`), `NottiNetworkObserver.kt` (`:32`); tests in `NottiCoreTest.kt`, `NottiModuleTest.kt`, `NottiForegroundObserverTest.kt`, `NottiNetworkObserverTest.kt`, new `NottiInAppEndToEndTest.kt`
**Depends on**: T1, T6, T10, T11, T12
**Reuses**: injection style of `NottiCore` providers (`NottiCore.kt:44-132`)
**Requirement**: SDKIAM-02, SDKIAM-10, SDKIAM-13, SDKIAM-15, SDKIAM-50, SDKIAM-53, SDKIAM-54, SDKIAM-58, SDKIAM-59, SDKIAM-67, SDKIAM-68, SDKIAM-70

**Done when**:
- [ ] `onInitialized(appId, clientKey, baseUrl)` is called from the `initialize` path **before** the core is created (so the replayed missed foreground reaches `onSessionStarted()` after it), posted through the same main-thread queue as `trackEvent`; exact call site confirmed in code [Incerto until read]
- [ ] `onSessionStarted()` only when `sessionGate.tryOpen()` succeeds; `onRegistered()` after a successful registration; `onNetworkAvailable()` from the core and the observer; `onSessionEnded()` and the display-clock pause in `handleProcessBackground` (works with no core); display-clock resume in `onStart`
- [ ] RN reload (new core, same process, same config) neither refetches nor drops the held messages or the visible display; a re-initialize with a different app id resets the engine (SDKIAM-70)
- [ ] `NottiModule.trackEvent` forwards to the coordinator on the main thread; `invalidate()` does not shut the coordinator down; `T1`'s `TODO(T13)` stub removed
- [ ] Existing suites updated only for new constructor parameters, assertions unchanged
- [ ] End-to-end test (MockWebServer + real parser/store/coordinator + fake presenter): session start -> registration -> events flushed -> `eligible` once -> `session_start` shown -> `impression` -> `click` in that order with distinct `event_id`s -> `trackEvent` shows the held message after close; **cold-start race**: `initialize` immediately followed by `trackEvent(name)` on the same thread, before the first session opens, still shows the matching held message once the first fetch completes (a name called before `initialize` does not); request log contains no `PATCH /devices` caused by In-App (SDKIAM-53) and no sensitive logs (SDKIAM-54)
- [ ] `git diff plugin/ android/src/main/AndroidManifest.xml` empty
- [ ] Gates: Android command; `pnpm run build:android`

**Tests**: unit + integration
**Gate**: full (Android)

**Commit**: `feat(android): wire in-app messages into session, registration and trackEvent`

---

## iOS chain (mirrors Android; same acceptance criteria)

### T14: iOS - In-App models, tolerant parser and color parsing

**What**: Swift mirror of T2.
**Where**: `ios/NottiInAppModels.swift`, `ios/Tests/NottiInAppModelsTests.swift` (all new)
**Depends on**: T1
**Reuses**: `JSONSerialization` style of `NottiApiClient.swift:379+` (`parseDeviceResponse`)
**Requirement**: SDKIAM-07, SDKIAM-14, SDKIAM-26 (parse), SDKIAM-36 (range)

**Done when**:
- [ ] Same bullets as T2, expressed in Swift, with identical table inputs (shared fixtures copied, not shared files) so parity can be diffed, including the SDKIAM-14 additions (buttons kept only with non-empty `id` and `label` then the first two valid ones, non-`https` `image_url` ignored, `image_action` without an image ignored, unknown `format` -> `center` unchanged; parity with iOS IAM-16)
- [ ] No force-unwraps on server input; parse never traps
- [ ] XCTest tables for every bullet
- [ ] Gate: iOS command, test count grows

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): parse in-app eligible messages tolerantly`

---

### T15: iOS - `NottiInAppEventStore`

**What**: Swift mirror of T3.
**Where**: `ios/NottiInAppEventStore.swift`, `ios/Tests/NottiInAppEventStoreTests.swift`
**Depends on**: T14
**Reuses**: `NottiEventStore.swift:58-138` (`UserDefaults` suite, `NSLock`), `NottiEventStoreTests.swift` suite setup
**Requirement**: SDKIAM-41, SDKIAM-44, SDKIAM-45, SDKIAM-46, SDKIAM-51, SDKIAM-70 (record/purge part)

**Done when**:
- [ ] Same bullets as T3 (key `notti_pending_inapp_events` in the `notti_prefs` suite, record with `appId`, `purgeOtherApps`, cap 100, TTL 7 days, UUID stability, corruption self-heal, independence from the CTR store)
- [ ] XCTest for each bullet
- [ ] Gate: iOS command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add persisted in-app event queue`

---

### T16: iOS - `NottiApiClient` In-App endpoints (single attempt, `Retry-After`)

**What**: Swift mirror of T4 over a new `performOnce` that reuses `syncDataTask`.
**Where**: `ios/NottiApiClient.swift` (modify; `executeWithRetry` `:242` untouched), `ios/Tests/NottiApiClientTests.swift` (extend)
**Depends on**: T14
**Reuses**: `percentEncodedPathComponent` (`:137`), `syncDataTask` (`:319`), `requestTimeoutSeconds` (`:77`), `StubURLProtocol.swift`
**Requirement**: SDKIAM-01 (shape), SDKIAM-05, SDKIAM-06, SDKIAM-47, SDKIAM-48, SDKIAM-49, SDKIAM-54

**Done when**:
- [ ] Same bullets as T4 (request shape, classification table incl. `Retry-After` integer-only parsing, 401 and 403 as distinct outcomes, `408` transient on both routes, one request per call, path-injection safe, no sensitive logs)
- [ ] Pre-existing `NottiApiClientTests` pass unmodified
- [ ] XCTests with `StubURLProtocol` for each status class and header case
- [ ] Gate: iOS command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add in-app eligible and events requests`

---

### T17: iOS - session state machine and display clock (pure)

**What**: Swift mirror of T5.
**Where**: `ios/NottiInAppSession.swift`, `ios/Tests/NottiInAppSessionTests.swift`
**Depends on**: T14
**Reuses**: nothing platform-specific
**Requirement**: SDKIAM-08..15, SDKIAM-36..39 (clock), SDKIAM-40 (flag), SDKIAM-59 (engine part), SDKIAM-70 (engine part)
**Decision implemented**: A14 (max 32 names, same as Android, with the `awaitingFirstSession` window: on iOS the first session opens at `didBecomeActive`), SDKIAM-15 late response, SDKIAM-70 reset

**Done when**:
- [ ] Same bullets as T5 with the same table cases (session token staleness, pending-name replay, carry-over, once-only impression decision, single terminal outcome, clock pause/resume, `awaitingFirstSession` set/clear/replay and the ignore cases, `fetchGeneration` late-response discard, held dropped at session end, `onInitialized` same vs different config)
- [ ] Gate: iOS command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add in-app selection state machine and display clock`

---

### T18: iOS - `NottiInAppCoordinator` (fetch sequence, flush, scheduling)

**What**: Swift mirror of T6 on a serial `DispatchQueue` with `asyncAfter` retries; state on main.
**Where**: `ios/NottiInAppCoordinator.swift`, `ios/Tests/NottiInAppCoordinatorTests.swift`; behavior-preserving extraction of `NottiCore.formatIsoUtc` (`NottiCore.swift:1304`) into an internal helper
**Depends on**: T14, T15, T16, T17
**Reuses**: `NottiCore.onNetworkAvailable` single-flight pattern (`NottiCore.swift:611-628`), `StubURLProtocol`, injected clock/scheduler
**Requirement**: SDKIAM-01..06, SDKIAM-08, SDKIAM-09, SDKIAM-10..13, SDKIAM-15 (late response), SDKIAM-40..52, SDKIAM-54, SDKIAM-59 (coordinator part), SDKIAM-70
**Decisions implemented**: A15 and A16 (as amended 2026-10-19), A14 (`onInitialized` before the first session), DD-14; no link handling in the SDK (A9)

**Done when**:
- [ ] Same bullets as T6 (own queue, one `eligible` per session, single-attempt flush then `eligible` regardless except after `401`, events 429 clamp/default/pause deadline, `eligible` 429 give-up above 60 s else wait `max(1, Retry-After)` up to 3 waits, `403` warning once per session per route vs `401` generic line and session stop, 422 handling, events `408` as `5xx`, single-flight flush, impression-then-terminal, no `PATCH /devices`, identity read at call time, no sensitive logs, `onInitialized` before the first session with same-config keep / different-config reset and silent display teardown, `app_id` filter and purge, late `eligible` response discarded)
- [ ] Cold-start race tests on iOS: `initialize` immediately followed by `trackEvent` on the same thread, with the application still `.inactive` (no session yet), matches once the first session (at `didBecomeActive`) delivers the held messages; a name before `initialize` does not
- [ ] Tests assert the stubbed request log order and counts (events before `eligible`; one `eligible` across a simulated reload; no device PATCH), with injected scheduler so no real sleeps
- [ ] Gate: iOS command

**Tests**: unit + integration
**Gate**: quick

**Commit**: `feat(ios): add in-app coordinator for session fetch and event flush`

---

### T19: iOS - style resolver and layout metrics (pure)

**What**: Swift mirror of T7.
**Where**: `ios/NottiInAppStyle.swift`, `ios/Tests/NottiInAppStyleTests.swift`
**Depends on**: T14
**Reuses**: nothing platform-specific
**Requirement**: SDKIAM-16..19, SDKIAM-26..30
**Decision implemented**: A13 (semantic `UIColor`s, no derivation), A12 (margin measured from the safe-area edge)

**Done when**:
- [ ] Same bullets and table cases as T7 (semantic defaults, invalid colors, align, margin 16 measured from the safe-area edge and `margin: false` touching the safe-area edges on all sides horizontally too, never under the notch/Dynamic Island/home indicator, button tokens, no derivation, bounds at phone/tablet/landscape sizes)
- [ ] Gate: iOS command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add in-app style resolver and layout metrics`

---

### T20: iOS - UIKit views for the four layouts

**What**: Swift mirror of T8 with Auto Layout against `safeAreaLayoutGuide`.
**Where**: `ios/NottiInAppViews.swift`, `ios/Tests/NottiInAppViewsTests.swift`
**Depends on**: T19
**Reuses**: T19 metrics; plain `UIView(frame:)` layout in the hostless bundle
**Requirement**: SDKIAM-16..21, SDKIAM-23, SDKIAM-24, SDKIAM-27..31, SDKIAM-64

**Done when**:
- [ ] Each layout built per design; text via `UILabel`/`UITextView` with `dataDetectorTypes = []`, never an HTML/Markdown attributed string, never `WKWebView`
- [ ] Two buttons side by side, wrapping to a column at the largest Dynamic Type category (`traitCollection` override in tests); text in a `UIScrollView`; close control >= 44 pt always present
- [ ] Dynamic colors for defaults (light/dark via `UITraitCollection` override in tests); author colors fixed
- [ ] XCTest: each layout laid out at phone/tablet/landscape sizes and content size categories: bounds respected, close control present, plain-text literals verbatim, wrap logic, alignment/colors
- [ ] If layout tests cannot run in the hostless bundle [Incerto], the metrics tests (T19) still cover bounds and the gap is recorded in T30; do not weaken assertions to make them pass
- [ ] Gate: iOS command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): render in-app message layouts with UIKit`

---

### T21: iOS - interactions and accessibility

**What**: Swift mirror of T9.
**Where**: `ios/NottiInAppViews.swift` (modify), `ios/Tests/NottiInAppViewsTests.swift` (extend)
**Depends on**: T20
**Reuses**: gesture recognizers, `UIAccessibility`
**Requirement**: SDKIAM-21, SDKIAM-22, SDKIAM-33..35, SDKIAM-39, SDKIAM-63
**Decision implemented**: A18

**Done when**:
- [ ] Close -> `close_button`; `top` pan up / `bottom` pan down past threshold -> `swipe`; `center` backdrop tap -> `outside_tap`; `full` none; same tap rules for buttons, image (`image`) and bar body (first button)
- [ ] Accessibility: close label table (en, pt-BR, fallback en), `.button` / `.header` traits, `accessibilityViewIsModal` on `center`/`full`, `screenChanged`/`announcement` notifications, `accessibilityPerformEscape` acts as `close_button` on `center`/`full`
- [ ] Reduce Motion respected for transitions
- [ ] XCTest invoking recognizers/handlers and asserting callbacks and accessibility properties
- [ ] Gate: iOS command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): add in-app gestures, taps and accessibility`

---

### T22: iOS - window presenter, scene and lifecycle, impression and auto-dismiss

**What**: Swift mirror of T10 using a dedicated `UIWindow`.
**Where**: `ios/NottiInAppPresenter.swift`, `ios/Tests/NottiInAppPresenterTests.swift`
**Depends on**: T17, T21
**Reuses**: `NottiImpl.beginBackgroundTask` pattern is NOT needed (no background work); lifecycle notifications as in `NottiCore.observeAppForeground` (`NottiCore.swift:940-969`)
**Requirement**: SDKIAM-15, SDKIAM-17, SDKIAM-25, SDKIAM-33, SDKIAM-36..40, SDKIAM-70 (silent teardown)

**Done when**:
- [ ] `NottiInAppWindow` with `.alert` level, shown but never key; `hitTest` passes through outside the bar on `top`/`bottom`; scene resolved through an injected `SceneProviding` (first `.foregroundActive` scene; scene-less fallback)
- [ ] `onVisible` raised once after the first layout with the app active; rotation/size changes and repeated layout passes never raise a second impression; no active scene -> Preparing, presents on `didBecomeActive`
- [ ] Display clock runs only while presented and between `willEnterForeground` and `didEnterBackground`; `willResignActive` alone does not pause; `auto` dismiss at zero; manual close cancels
- [ ] Silent teardown (config-change re-initialize): the window is hidden and released, the clock stops, and no event is produced
- [ ] XCTest with fake scene provider and injected clock for the lifecycle logic; repeated `viewDidLayoutSubviews` asserts exactly one `impression`; real window behavior is in T30
- [ ] Gate: iOS command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): present in-app messages in a dedicated window`

---

### T23: iOS - image loader and presenter integration

**What**: Swift mirror of T11.
**Where**: `ios/NottiInAppImageLoader.swift`, `ios/NottiInAppPresenter.swift` (modify), `ios/Tests/NottiInAppImageLoaderTests.swift`
**Depends on**: T22
**Reuses**: `StubURLProtocol`; an ephemeral `URLSession` with `httpShouldSetCookies = false` and a redirect delegate
**Requirement**: SDKIAM-20, SDKIAM-35, SDKIAM-57

**Done when**:
- [ ] Same bullets as T11: https-only, no `Authorization`/cookies, non-https redirect refused, 5 MiB abort, downsampled decode (`ImageIO` thumbnail API), 5-entry memory cache, 3 s wait then no image, failure leaves a valid message, image tappable only when loaded
- [ ] XCTests via `StubURLProtocol` (header absence, oversize, redirect, timeout, cache hit)
- [ ] Gate: iOS command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): load in-app images with bounded credential-free requests`

---

### T24: iOS - click delivery to the JS listener (no link opening)

**What**: Swift mirror of T12: `NottiImpl.emitInAppClickHandler`, the `Notti.mm` handler wiring and the no-listener rule.
**Where**: `ios/NottiImpl.swift` (`@objc public var emitInAppClickHandler`, next to `emitReceivedHandler` `:77`, with no `NottiEventBuffer` involvement), `ios/Notti.mm` (handler in `-init` next to `:13-21` calling `emitOnInAppMessageClicked:`), `ios/NottiInAppCoordinator.swift` (production `ClickSink`), tests in `ios/Tests/NottiInAppCoordinatorTests.swift` (extend)
**Depends on**: T18, T22, T1
**Reuses**: the emit-handler pattern of `NottiImpl` (`:77-102`)
**Requirement**: SDKIAM-32, SDKIAM-33..35, SDKIAM-67, SDKIAM-68
**Decision implemented**: A9

**Done when**:
- [ ] Same bullets as T12: payload keys `messageId`, `buttonId`, `action` (dictionary or `NSNull`), value untouched, order click-enqueued -> emit -> close, no handler (module invalidated: `invalidate()` sets the handler to `nil`, `NottiImpl.swift:266`) -> reported + closed + one fixed warning + no buffering
- [ ] `git grep -nE "UIApplication|openURL|canOpenURL|\.open\(" ios/NottiInApp*` returns nothing (also run in T29)
- [ ] `Notti.mm` change limited to the handler wiring (AD-002); the stub from T1 for `trackEvent` stays until T25
- [ ] XCTest with a fake click sink and a handler spy for each bullet
- [ ] Gate: iOS command

**Tests**: unit
**Gate**: quick

**Commit**: `feat(ios): deliver in-app clicks to the JS listener without opening links`

---

### T25: iOS - wiring (core hooks, impl, shim, observers) and end-to-end flow

**What**: Connect the coordinator to the session gate, registration, network observer, foreground/background, and replace the `trackEvent` stub.
**Where**: `ios/NottiCore.swift` (`inApp` hooks at `:994`, `:611-628`, `:712`, `:1009`), `ios/NottiImpl.swift` (`trackEvent`; `processBackgroundObserver` `:47-55`; coordinator touch next to `:109`), `ios/Notti.mm` (shim `trackEvent:` replaces the stub), `ios/NottiNetworkObserver.swift` (`:59`); tests in `ios/Tests/NottiCoreTests.swift`, `NottiNetworkObserverTests.swift`, new `NottiInAppEndToEndTests.swift`
**Depends on**: T1, T18, T22, T23, T24
**Reuses**: `sessionGate` injection (`NottiCore.swift:262-283`)
**Requirement**: SDKIAM-02, SDKIAM-10, SDKIAM-13, SDKIAM-15, SDKIAM-50, SDKIAM-53, SDKIAM-54, SDKIAM-58, SDKIAM-59, SDKIAM-67, SDKIAM-68, SDKIAM-70

**Done when**:
- [ ] `onInitialized(appId, clientKey, baseUrl)` is called from the `initialize` path before the core is created, through the same main queue as `trackEvent` (on iOS the first session opens only at `didBecomeActive`); exact call site confirmed in code [Incerto until read]
- [ ] Hooks fire exactly as in T13 (gate open, registration success, network, background even without a core); `NottiImpl.invalidate` (`:259`) does not tear the coordinator down; the `TODO(T25)` stub is gone
- [ ] JS reload scenario keeps held messages and the visible display and sends no second `eligible`
- [ ] Existing suites updated only for new initializer parameters
- [ ] End-to-end XCTest equivalent to T13's flow (stubbed server, request-log order, distinct `event_id`s, no device PATCH, no sensitive logs) including the cold-start race (`initialize` immediately followed by `trackEvent` before the first session still matches) and the different-config re-initialize reset
- [ ] `git diff plugin/` empty; `Notti.mm` change limited to the shim method (AD-002)
- [ ] Gates: iOS command; `pnpm run build:ios`

**Tests**: unit + integration
**Gate**: full (iOS)

**Commit**: `feat(ios): wire in-app messages into session, registration and trackEvent`

---

## Docs, example, review, validation

### T26: README and CHANGELOG

**What**: Document the feature and the new public method; update privacy and storage sections.
**Where**: `README.md` (API reference table near `:142-162`; new "In-App messages" section; "Data collected by the SDK" `:300-322`; "Privacy, App Store labels and LGPD" `:398-404`; "Known limitations" `:406-413`; "Locally persisted data" table `:532-555`; "Retry policy" note `:362-370`), `CHANGELOG.md` (`## [Unreleased]` at `:106`)
**Depends on**: T13, T25
**Reuses**: wording style of the CTR sections
**Requirement**: SDKIAM-55, SDKIAM-56, SDKIAM-61, SDKIAM-69

**Done when**:
- [ ] API reference rows for `Notti.trackEvent(name)` (exact, case-sensitive, local-only, never sent, dashboard names are lower-case `[a-z0-9_.-]` up to 64 chars, A7; a name reported after `initialize` and before the first session opens is remembered and replayed with that session, a name before `initialize` or in the background after a session ran is ignored, A14) and `Notti.InAppMessages.addClickListener(handler)` (payload `NottiInAppClick { messageId, buttonId, action: { type: 'url' | 'deeplink', value } | null }`); the listener row starts with the warning below
- [ ] A highlighted callout (blockquote with a bold lead) at the top of the In-App section and repeated in the listener's API row: **"Links are yours to handle. The SDK never opens a `url` or `deeplink`. Without a registered click listener, tapping a button reports the click, closes the message and does nothing else."** With a listener example: `deeplink` values go through the app's navigation, `url` values through `Linking.openURL`; register the listener at app start (a click with no listener is not buffered or replayed)
- [ ] "In-App messages" section: one fetch per session (session definition), one visible at a time, once per session, layouts, plain text, click always reported and closes the message (no `dismiss`), auto dismiss, offline queue and 7-day drop, no persistent "shown" state
- [ ] Data collected table: fetch body (`device_id`, `token`), per-display events, new storage key `notti_pending_inapp_events`, and the image request to the author-chosen host (not Notti; no identifiers)
- [ ] Privacy section: In-App events listed with the Product Interaction nature; the pending owner decision on labels referenced, not resolved; LGPD note unchanged in tone
- [ ] Known limitations: overlay hidden under RN `<Modal>` on Android; queue/`eligible` give-up behavior (including the `Retry-After` above 60 s give-up); on Android `center`/`full` consume the system Back button (no dismiss, no host navigation) while bars do not intercept it; `margin` measured from the safe-area edge; hostless-test gaps are NOT user docs
- [ ] CHANGELOG `[Unreleased]` also states the deliberate divergence from the contract: on `403` the SDK does not re-register and logs the fixed warning once per session per route; In-App stays inactive on the device until the next registration (cold start or token refresh); a `401` stops In-App for the session without re-registering and logs only the generic line
- [ ] CHANGELOG `[Unreleased]`: additive note ("New: `Notti.trackEvent`, In-App messages; requires a Notti backend with In-App rich messages")
- [ ] All examples use synthetic values (`example.invalid`)
- [ ] Gate: `pnpm lint` (prettier on markdown if configured) and `pnpm typecheck`

**Tests**: none (docs); review against the spec checklist
**Gate**: quick

**Commit**: `docs: document in-app messages and trackEvent`

---

### T27: iOS privacy manifest comment

**What**: Name In-App events in the pending-decision comment of `PrivacyInfo.xcprivacy`; no data type change.
**Where**: `ios/PrivacyInfo.xcprivacy` (comment block, `:14-32`)
**Depends on**: T26
**Reuses**: the existing comment
**Requirement**: SDKIAM-56

**Done when**:
- [ ] The comment lists "In-App message events (impression, click, dismiss)" next to CTR events and session aggregates as pending the owner's decision; no `NSPrivacyCollectedDataType` added or removed
- [ ] `plutil -lint ios/PrivacyInfo.xcprivacy` passes
- [ ] Gate: `pnpm run build:ios`

**Tests**: none (lint + build)
**Gate**: quick

**Commit**: `docs(ios): note in-app events in the privacy manifest comment`

---

### T28: Example app - `trackEvent` button, click listener and test-message recipe

**What**: A button calling `Notti.trackEvent('checkout_done')`, a registered `Notti.InAppMessages.addClickListener` and a smoke-test recipe for creating the test messages in the dashboard.
**Where**: `example/src/App.tsx` (buttons list near `:64-91`), `README.md` "Manual smoke testing" (`:504-511`)
**Depends on**: T13, T25, T1
**Reuses**: existing placeholder-credentials pattern in the example
**Requirement**: SDKIAM-55, SDKIAM-58, SDKIAM-67, SDKIAM-69

**Done when**:
- [ ] A click listener registered at app start (`useEffect`, removed on unmount) that logs only the `buttonId`, routes a `url` with `Linking.openURL` and a `deeplink` with the example's own handling (demonstrates the README callout)
- [ ] Button "Track event: checkout_done" calling `Notti.trackEvent('checkout_done')` (no credentials added)
- [ ] Smoke-test recipe (synthetic): create a `session_start` message (layout `center`, two buttons, one `deeplink` with the example app's scheme, `dismiss_after_seconds` 8) and an `event` message named `checkout_done` (layout `bottom`, image + `image_action`), activate both, launch, tap the button; where to read the metrics in the dashboard
- [ ] No real credentials, URLs or ids committed
- [ ] Gates: `pnpm typecheck && pnpm lint`; `pnpm run build:android && pnpm run build:ios`

**Tests**: build
**Gate**: full

**Commit**: `feat(example): add a trackEvent button and click listener for in-app message testing`

---

### T29: Cross-platform review and full gate

**What**: No new behavior. Verify parity and run the full definition of done.
**Where**: N/A
**Depends on**: T26, T27, T28
**Requirement**: SDKIAM-53, SDKIAM-54, SDKIAM-60, SDKIAM-62, SDKIAM-65, SDKIAM-66

**Done when**:
- [ ] Side-by-side read of both coordinators, stores, clients, session machines and style tables: identical request shapes, classification, constants, flush/fetch rules, and Spec criteria; any deliberate difference is already in `design.md` "Platform differences"
- [ ] `git grep -nE "Log\.|NSLog|logger\(" android/src/main/java/com/notti/NottiInApp* ios/NottiInApp*` reviewed: no token, device id, ids, URLs, titles, event names or bodies in any message
- [ ] `git diff main -- src/` shows only `trackEvent` and `Notti.InAppMessages.addClickListener` (with `InAppClickPayload` and the `onInAppMessageClicked` emitter and the exported types) as public additions (SDKIAM-60)
- [ ] `git diff main -- plugin/ android/src/main/AndroidManifest.xml` empty (SDKIAM-62)
- [ ] `git grep -nE "PATCH|patchDevice" ` inside In-App files finds none (SDKIAM-53)
- [ ] `git grep -nE "ACTION_VIEW|startActivity|Uri\.parse|UIApplication|openURL|canOpenURL" android/src/main/java/com/notti/NottiInApp* ios/NottiInApp*` finds none: the SDK opens no link (SDKIAM-32)
- [ ] Click payload and no-listener rule identical on both platforms (SDKIAM-67, SDKIAM-68)
- [ ] Parity of the 2026-10-19 rules on both platforms: margin from the safe-area edge, `403`-only warning and `401` session stop, `eligible` 429 cap, `awaitingFirstSession`, late-response discard, config-change reset with `app_id` records, renderability; the only platform difference is the Android Back handling (listed in `design.md` "Platform differences")
- [ ] Every SDKIAM requirement has a test (traceability) or a T30 scenario
- [ ] Full gate green with real output pasted into the PR description: `pnpm typecheck && pnpm lint && pnpm test && pnpm run build:android && pnpm run build:ios`, Android `testDebugUnitTest`, iOS `xcodebuild test`
- [ ] `STATE.md`: AD-004 status updated (2026-10-19 decisions included), feature handoff entry added

**Tests**: none (review) + full gates
**Gate**: full (all)

**Commit**: none expected (any fix becomes its own small commit)

---

### T30: Manual device validation (real devices) and `validation.md`

**What**: Run the scenarios below on at least one physical Android device and one physical iPhone against a running `zeep-notti` with In-App rich messages; record evidence in `.specs/features/in-app-messages/validation.md` (created then, not now). Anything that fails becomes a fix task before release.
**Where**: example app (T28), a real Notti instance, dashboard metrics
**Depends on**: T29
**Requirement**: SDKIAM-13, SDKIAM-17, SDKIAM-21, SDKIAM-22, SDKIAM-25, SDKIAM-28, SDKIAM-37, SDKIAM-40, SDKIAM-45, SDKIAM-63, SDKIAM-64, SDKIAM-66, SDKIAM-70 (everything not unit-testable)

**Scenarios** (each on both platforms unless stated; record device, OS, SDK version, result):

1. Cold start: `session_start` message appears once, after registration; exactly one `eligible` request in the server log.
2. Each layout (`top`, `center`, `bottom`, `full`) renders inside its bounds on a small phone and a large phone/tablet, portrait and landscape.
3. Dark mode and light mode with default style; then with only `background_color` set: text stays readable.
4. Full style set: colors, `text_align` left/center/right, `margin` true/false (true: 16 from the safe-area edge; false: touches the safe-area edges on all sides, horizontally too, never under the notch/cutout/status bar/home indicator, also in landscape), button tokens apply to all buttons.
5. Largest system font size / Dynamic Type: nothing unreachable; text scrolls; buttons and close control reachable.
6. Gestures: `top` swipe up, `bottom` swipe down, `center` backdrop tap, `full` no gesture, close button on all; verify the reported `reason` in the dashboard/server. Android Back: see scenario 26.
7. Taps: each button, image with `image_action` (`image`), bar body (first button); each closes the message and reports only the click.
8. Links: with the example's listener, a button with an `https` `url` and one with a `deeplink` each deliver the untouched action to JS (the example opens it) and the SDK itself opens nothing; with the listener removed, tapping reports the click (dashboard), closes the message and nothing opens; a tap before any listener exists is not replayed when one registers later; unknown action type delivers `action: null`.
9. Auto dismiss: closes after N s with `auto`; backgrounding mid-countdown pauses it; manual close earlier reports `close_button`.
10. Rotation during a visible message (both orientations, repeatedly): same message continues, no second `impression` in the dashboard.
11. Android only: navigate between two Activities (or screens that recreate the Activity) while a message is visible; open an RN `<Modal>` while a message is visible (record behavior, R2).
12. iOS only: iPad multi-scene or Stage Manager window if available; app with and without scene manifest; keyboard visible while a message appears.
13. RN reload (dev menu) while a message is visible and while only held: no second `eligible`, no duplicate message, `trackEvent` still works.
14. Background/foreground cycle: a new session fetches once; the previously shown `once` message is not re-offered by the server; a message visible across the background continues.
15. `trackEvent` matching: exact name shows the held message only when none is visible; wrong case does nothing; called before the fetch completes (A14: remembered and evaluated on arrival); called in a tight loop causes no network traffic.
16. Offline: airplane mode at launch (fetch fails, resumes on reconnect); airplane mode during a display then close, force-kill, relaunch: events delivered with the same `event_id`, no duplicates in metrics.
17. Server `429` with `Retry-After` (throttle via a test proxy): no early retry; server `5xx` on events: backoff, queue kept; `403` (revoke token): flush stops and keeps the queue, resumes after the normal registration; `eligible` still goes out after a failed pre-fetch flush; `429` on `eligible`: `Retry-After` of 60 s or less waits that time (at least 1 s, at most 3 waits), above 60 s gives up for the session with no retry; `401` (invalid client key): flush and fetch stop for the session, queue kept, only the generic log line; `403`: the fixed inactive warning appears once per session per route.
18. Event older than 7 days (clock-shifted test device or edited queue): never sent.
19. No sensitive data: capture device logs (`logcat`, Console) during a full run with synthetic token/title/event name: zero occurrences; capture the image request (proxy): no `Authorization`, no cookies.
20. MAU: after a full run, the device's `last_seen_at` in the backend did not change because of In-App traffic alone.
21. Accessibility: VoiceOver and TalkBack: close label announced, title heading, buttons activatable, `center`/`full` modal (focus trapped, background unreachable), bars announced without stealing focus; Reduce Motion; record the Android sibling-hiding behavior with real TalkBack (R3).
22. Insets: devices with a notch/cutout, gesture navigation and 3-button navigation, Android 15+ edge-to-edge, iOS Dynamic Island: message never under system UI, with `margin` true and false, portrait and landscape.
23. Memory/perf: show and dismiss 20 messages with images in one session: no leak growth, no ANR/hitch.
24. Compare each layout with the dashboard preview (`InAppPreview`) side by side and record deviations for the owner's eyes (A13; the `margin` rule, A12, is decided: report any preview difference).
25. Cold-start ordering (A14, [Provável], the point the owner asked to validate; both platforms): with an `event` message named `checkout_done` active and no `session_start` message, call `Notti.trackEvent('checkout_done')` immediately after `Notti.initialize(...)` in the app entry (before any foreground-dependent code), over repeated cold starts: the held message shows once, as part of the first session, after the first `eligible`; record the order of the `initialize`, `trackEvent`, session open and `eligible` events from native debug logs (no names logged: use temporary local instrumentation, not committed). A `trackEvent` before `initialize` and one while the app is in the background after a session ran must do nothing. iOS: confirm the session opens at `didBecomeActive` and not earlier. Android: confirm the asynchronous store work behind the session start does not reorder the flag.
26. Android Back (A19, DD-10, [Incerto]): on `center` and `full` the Back button and the Back gesture do nothing (message stays, no dismiss in the dashboard, the host screen behind does not navigate and the JS `BackHandler` is not triggered); on `top` and `bottom` Back reaches the app as usual; check 3-button navigation, gesture navigation with predictive back, API 33/34/35 with and without `android:enableOnBackInvokedCallback`, a `ReactActivity` host, rotation and Activity change while the message is visible, and that Back works normally again after the message closes. The close control remains the only way out of `full`.
27. Re-initialize (SDKIAM-70): same config (RN reload) keeps the visible message, held messages and queue; a re-initialize with a different app id (test build with a second app) resets the engine, removes the visible message without a dismiss in the dashboard, discards the old app's queued events (never sent to the new app) and triggers one `eligible` for the new config.

**Done when**:
- [ ] Every scenario has a recorded result and evidence (screenshot/screen recording and server/dashboard readout, no real user data)
- [ ] Failures are filed as tasks; hostless-test gaps noted in T20/T22 are explicitly closed here
- [ ] `validation.md` created with a requirement-by-requirement evidence table (Test / Device run / Not verified)

**Tests**: manual
**Gate**: manual sign-off by the owner

**Commit**: `docs(inapp): record device validation of in-app messages`

---

## Parallel Execution Map

```
Phase 0:   T1
Phase 1:   Android  T2 -> T3 -> T4 -> T5 -> T6 -> T7 -> T8 -> T9 -> T10 -> T11 -> T12 -> T13
           iOS      T14 -> T15 -> T16 -> T17 -> T18 -> T19 -> T20 -> T21 -> T22 -> T23 -> T24 -> T25
           (the two chains touch disjoint files and run in parallel after T1)
Phase 2:   T13 + T25 -> T26 -> T27
           T13 + T25 -> T28
           T26 + T27 + T28 -> T29 -> T30
```

Within a chain the order is strict for review simplicity, but these are genuinely independent and may be reordered or parallelized across people: T7 (needs only T2) can move ahead of T3-T6; T11 and T12 (need T10) are independent of each other.

---

## Task Granularity Check

| Task | Scope | Status |
| --- | --- | --- |
| T1 | JS spec + facade + two stubs (one concern: the new Spec method must compile everywhere) | OK, cohesive |
| T2, T14 | 2 new files (models, validator) + 1 test file | OK |
| T3, T15 | 1 file + tests | Granular |
| T4, T16 | 1 existing file + tests | OK |
| T5, T17 | 1 file + tests | Granular |
| T6, T18 | 1 large file + tests + one behavior-preserving helper extraction | Borderline: kept as one task because fetch sequence, flush and callbacks share state; splitting leaves untestable halves |
| T7, T19 | 1 file + tests | Granular |
| T8, T20 | views static rendering | OK |
| T9, T21 | interactions on top of T8/T20 | OK |
| T10, T22 | presenter + lifecycle | Borderline (tracker + overlay + clock wiring); kept together because the impression-once guarantee spans all three |
| T11, T23 | image loader | Granular |
| T12, T24 | click emit bridge + no-listener rule | Granular |
| T13, T25 | wiring into 4 existing files + e2e test | Borderline: each edit is a few lines; merged because no hook is observable without the e2e flow |
| T26 | README + CHANGELOG | OK |
| T27 | 1 comment edit | Granular |
| T28 | 1 button + README recipe | OK |
| T29, T30 | review and manual validation | Checkpoints, not implementation |

---

## Diagram-Definition Cross-Check

| Task | Depends On (task body) | Diagram shows | Status |
| --- | --- | --- | --- |
| T1 | None | first | Match |
| T2 | T1 | after T1 | Match |
| T3 | T2 | T2 -> T3 | Match |
| T4 | T2 | after T2 (sequenced after T3 for review order) | Match (chain order, dependency satisfied) |
| T5 | T2 | after T2 | Match |
| T6 | T2, T3, T4, T5 | T5 -> T6 | Match |
| T7 | T2 | after T2 | Match |
| T8 | T7 | T7 -> T8 | Match |
| T9 | T8 | T8 -> T9 | Match |
| T10 | T5, T9 | T9 -> T10 | Match |
| T11 | T10 | T10 -> T11 | Match |
| T12 | T6, T10, T1 | T11 -> T12 | Match (dependencies satisfied earlier) |
| T13 | T1, T6, T10, T11, T12 | T12 -> T13 | Match |
| T14 | T1 | after T1 | Match |
| T15-T25 | mirror T3-T13 | mirror | Match |
| T26 | T13, T25 | both chains -> T26 | Match |
| T27 | T26 | T26 -> T27 | Match |
| T28 | T13, T25, T1 | both chains -> T28 | Match |
| T29 | T26, T27, T28 | -> T29 | Match |
| T30 | T29 | T29 -> T30 | Match |

---

## Test Co-location Validation

| Task | Code layer created/modified | Matrix requires | Task says | Status |
| --- | --- | --- | --- | --- |
| T1 | TS facade + native stubs | Jest + build | unit + build | OK |
| T2-T7 | Android pure/logic/client | JVM unit (+ MockWebServer) | unit | OK |
| T8-T12 | Android views/presenter/loader/click bridge (framework classes) | JVM + Robolectric (existing practice) | unit (Robolectric) | OK |
| T13 | Android wiring | existing suites + e2e | unit + integration | OK |
| T14-T19 | iOS pure/logic/client | XCTest | unit | OK |
| T20-T24 | iOS views/presenter/loader/click bridge | XCTest (hostless limits noted) | unit | OK, gap recorded for T30 |
| T25 | iOS wiring | existing suites + e2e | unit + integration | OK |
| T26-T28 | Docs, plist comment, example | build gates | none/build | OK |
| T29 | Review | none + full gates | none | OK |
| T30 | Real devices | manual | manual | OK |

---

## Tools Confirmation Needed

`NONE` (no MCP, no extra skill) is assumed for every task. Skills from `AGENTS.md` that apply when executing: `notti-commit` (every commit), `swift-concurrency` (T17-T25), `react-native-best-practices` (T6/T18 threading), `expo-module` is **not** needed (SDKIAM-62: no plugin change). Confirm `NONE` is right, or name the Xcode/Gradle runner you prefer for the gates.
