# In-App Messages Specification

## Problem Statement

The Notti backend (`zeep-notti`, feature `in-app-rich-messages`, implemented and
verified on the backend and dashboard side on 2026-10-18) can author In-App
messages (four layouts, style tokens, image, image action, auto dismiss, event
triggers) and exposes the two device routes that serve and measure them:

- `POST /v1/apps/{app_id}/in-app-messages/eligible` (what may be shown now)
- `POST /v1/apps/{app_id}/in-app-messages/{id}/events` (`impression`, `click`, `dismiss`)

No SDK reads them yet. `react-native-notti` today only handles push: it never
asks the server what to show inside the app, renders nothing, and has no way for
the host app to say "the user reached moment X". This spec makes the SDK
**fetch, render natively, and report** In-App messages on Android and iOS, with
two public JS additions as the only integrator surface: `Notti.trackEvent(name)`
and `Notti.InAppMessages.addClickListener(handler)` (AD-001: everything else is
native, implemented twice). **The SDK never opens a link**: a tap on a button,
the image or a bar body is always reported as a `click`, closes the message, and
hands the untouched `url`/`deeplink` action to the app through the click
listener; the integrator decides what to do with it (decided by Julio,
2026-10-18, same model as the iOS SDK).

The server contract is frozen and is the source of truth:
`zeep-notti/docs/content/sdks/in-app-messages.mdx` (referred to below as "the
contract"). Where this spec restates a rule it cites the contract section; where
the contract is silent the spec says so and records the choice as an Assumption
or an Open Question instead of inventing server behavior.

## Backend contract (source of truth, `zeep-notti`, not changed here)

| Item | Contract section | Behavior the SDK must honor |
| --- | --- | --- |
| Auth | Overview | `Authorization: Bearer <client key>` (the key already used for device registration) plus device ownership proof (`device_id` + `token`) in the body. REST key: `403`; missing/invalid key: `401`. |
| Fetch | Session flow, Fetching eligible messages | `eligible` once per session, after the device is registered. Body `{device_id, token}` only (unknown fields are `422`). Returns up to 5 `session_start` and 10 `event` messages, oldest first within each. `messages` is always an array. |
| Selection | Session flow, Triggers | First renderable `session_start` message shown right away; `event` messages held in memory and shown on `trackEvent(name)`; one visible at a time; each message at most once per session. |
| Layouts | Layouts | Four formats (`top`, `center`, `bottom`, `full`) with bounds, not pixels; close control always shown; gestures per layout. Unknown format renders `center`. |
| Style | Style | Closed token set; absent token or `style: null` means SDK default; unparsable color is ignored. |
| Text and links | Plain text and links | Plain text only. The contract says the SDK "should only open links it expects"; this SDK goes further and opens none: the action is delivered to the app untouched (SDKIAM-32, SDKIAM-67). |
| Auto dismiss | Auto dismiss | `dismiss_after_seconds` 1-300; pauses in background; reports `dismiss` with `reason: "auto"`. |
| Events | Reporting events | `event_id` UUID generated once per event and reused on retry; `impression` before any `click`/`dismiss` of that display; `occurred_at` RFC3339; deduplicated by `(message, device, event_id)`: `201` new, `200` duplicate, both success. |
| Offline | Offline behavior | Queue with `event_id` + `occurred_at`, oldest first; drop events older than 7 days; flush before calling `eligible` when possible. |
| Errors | Errors and limits | `401` no retry; `403` re-register, do not retry as is; `404` (events) drop; `422` (`invalid_body`, `invalid_content`) do not retry/drop; `429` wait `Retry-After` seconds and retry with the same `event_id` (this SDK caps the wait on `eligible`, SDKIAM-05); `5xx` backoff; `408` is a transient failure on both routes. Limits per device per minute: 30 on `eligible`, 120 on `events`. |
| Authority | Frequency | The server is the authority on frequency; the SDK must not keep a persistent "already shown" state, and must report impressions reliably (a lost impression makes a `once` message eligible again). |
| MAU | MAU | In-App events do not count as MAU. Verified in code: `zeep-notti/internal/inapp/events.go:41` (`RecordEvent` "deliberately leaves devices.last_seen_at alone"). [Certo] |
| Compatibility | Compatibility | Ignore unknown payload fields; unknown `format` renders `center`; payload changes are additive only. |

## Goals

- [ ] An app integrated with the SDK shows the right In-App message at session start, and shows event-triggered messages when it calls `Notti.trackEvent(name)`, with one call (`trackEvent`) for event triggers and, for links, a click listener the app registers (without one, no link does anything).
- [ ] The four layouts render natively on both platforms inside the contract's bounds, with a close control that is always reachable, on any screen size, font scale, orientation and theme.
- [ ] Every display reports exactly one `impression` (before any `click`/`dismiss`) and at most one terminal event, reliably: persisted before sending, never regenerated `event_id`, retried per the contract, surviving process death and offline periods.
- [ ] The server stays the authority: the SDK keeps no persistent "already shown" state and calls `eligible` once per session.
- [ ] AD-001 is preserved: all behavior is native (Kotlin + Swift), the TS layer only forwards `trackEvent` and the click listener subscription; Android and iOS meet identical acceptance criteria.
- [ ] No PII, token, device id, message text, URL or event name is logged; no new data category is collected beyond what the README already declares for CTR-style engagement events (confirmed in Privacy, below).

## Out of Scope

| Feature | Reason |
| --- | --- |
| Targeting evaluation (segments, schedule, frequency, platform) | Server-side at fetch time (contract, Eligibility rules). The SDK never evaluates it. |
| Persistent "already shown" suppression | Forbidden by the contract (Frequency). Only per-session in-memory state. |
| Per-screen or per-event fetches | Contract: one `eligible` per session. |
| JS-side rendering, web view, HTML or Markdown | Contract (Plain text and links); AD-001. |
| JS callbacks for message lifecycle (`willDisplay`, `didDismiss`, impression) | Not required by the contract; every extra public API is a long-lived commitment. The only host-facing callback is the click listener (SDKIAM-67). |
| Opening `url`/`deeplink` actions inside the SDK (browser, `Intent`, `UIApplication.open`), validating or rewriting their values | Decided 2026-10-18: the integrator handles links. The SDK delivers the action untouched and stays free of URL-opening APIs. |
| Buffering an unhandled click for a listener registered later | See A9: an In-App click happens inside a live process on a visible message, unlike a cold-start push tap; replaying it later would navigate the app at a surprising moment. |
| Test send / device preview channel | Backend Phase 3 (`in-app-rich-messages` spec, Out of Scope). |
| Rich media beyond one `https` image (video, animations, carousels) | Not in the payload. |
| Message templates, localization of message content | Content comes from the server as authored. |
| Live Activities, banners outside the app, push-driven in-app | Different features. |
| Re-registering the device on `403`/`401` from In-App routes | The registration state machine owns re-registration. Decided in A16. |
| Dismissing a message with the Android system Back button (a "back" reason does not exist in the contract) | Back is consumed (no-op) on `center`/`full`, so it neither dismisses nor navigates the host app behind the message, and is not intercepted on `top`/`bottom` (A19, SDKIAM-22). |
| Android `Dialog`/`PopupWindow` presentation | Discarded alternative; see `design.md`. |
| An SDK-owned localized string table beyond the close-control label | Only the close label is SDK text (table in code, en and pt-BR, A18). |

---

## Assumptions & Open Questions

Confirmed = `y (owner, date)`; otherwise `n` (recommended default, needs the owner).

| ID | Assumption / decision | Chosen default | Rationale | Confirmed? |
| --- | --- | --- | --- | --- |
| A1 | `text_align` absent | `left` | Contract Style table; dashboard validation record lists it among the defaults needing owner approval. | y (Julio, 2026-10-18) |
| A2 | `margin` absent | `true`: 16 pt/dp inset from the safe-area edge on `top`, `bottom`, `full` (A12); `center` ignores it | Same. | y (Julio, 2026-10-18) |
| A3 | `button_color` / `button_text_color` set | Applies to **every** button; the absent token keeps the SDK default | Same. | y (Julio, 2026-10-18) |
| A4 | `style: null` | All SDK defaults | Same. | y (Julio, 2026-10-18) |
| A5 | What "session" means | The SDK's existing foreground session: opened by the process-wide `SessionGate` (Android `NottiCore.SessionGate`, `NottiCore.kt:136`; iOS `NottiCore.SessionGate`, `NottiCore.swift:88`) on app foreground, closed on app background. A JS reload while foregrounded stays in the same session, and so does a re-`initialize` with the same app id, client key and base URL; a re-`initialize` with a **different** one resets the In-App engine (SDKIAM-70). **Every foreground (new session) produces one `eligible`; there is no background-duration threshold** (a threshold is a future evolution in both SDKs). [Certo: verified in code] | Reuses the SEGTEL concept instead of a second definition; the gate is already process-wide and survives RN reload. | y (Julio, 2026-10-19) |
| A6 | "Device is registered" | Registered **in this process** (registration succeeded since launch, so `device_id` and the current `token` are both fresh), not merely a cached `device_id` from a previous launch | A cached id with a rotated token would `403`. Costs at most one registration round trip of delay. | n |
| A7 | Event-name matching | Exact, case-sensitive, no trimming/normalization. The dashboard restricts names to 1-64 chars of `[a-z0-9_.-]` (`in-app-rich-messages` spec, Story P2 AC1), so `trackEvent('Checkout_Done')` will not match `checkout_done`. README must say so. | Contract: "exact name". Normalizing silently would diverge from the contract and hide integrator mistakes. | n |
| A8 | JS host-facing API | Exactly two additions: `trackEvent(name)` and `Notti.InAppMessages.addClickListener(handler)`; no other callbacks | Contract needs no more; the click listener replaces SDK-side link opening. | y (Julio, 2026-10-18) |
| A9 | Link handling | The integrator handles `url`/`deeplink`. The SDK **always** reports `click`, closes the display (no `dismiss`) and emits the click to the listener; with **no listener registered** the click is reported and nothing opens; the SDK logs one fixed warning and does not buffer the click. Continues the precedent that deep-link routing is the integrator's job (`sdk-core-v1/design.md:176`). Mirrors the iOS SDK (`zeep-notti-ios-sdk/.specs/features/in-app-messages/spec.md` IAM-24..26). | Owner decision; no cold-start gap exists for an In-App click (the process is alive and the display is on screen), so the `NottiEventBuffer`/`getInitialNotificationClick` mechanism is not needed. | y (Julio, 2026-10-18) |
| A10 | Image fetch | The device downloads `image_url` itself (https only), with no Notti credentials and no identifiers. This is a request to a host chosen by the message author, not by Notti; README must say so. | Needed to render the image; privacy hygiene in SDKIAM-57. | n |
| A11 | Tunable constants (queue cap 100 events, 7-day TTL, image wait 3 s, image size 5 MiB, events `429` clamp 1..300 s with 60 s default; `eligible` `429` gives up without waiting above 60 s, otherwise waits `max(1, Retry-After)` s (60 s default) up to 3 waits; backoff 2/4/8/16 s with 5 attempts, swipe threshold) | See `design.md` "Tunable constants"; the retry constants equal the iOS SDK's | Not in the contract; chosen to match the iOS SDK and listed so they can change without a spec change. | n |
| A12 | Safe areas vs `margin` | Placement always stays inside the safe areas (never under the notch, status bar, cutout or home indicator). `margin: true` or absent: 16 pt/dp inset **measured from the safe-area edge** (top, bottom, and all four sides on `full`). `margin: false`: the bar/card touches the safe-area edges on all sides, horizontally too (never the raw screen edges). `center` ignores `margin`. Same rule on both platforms. | The contract ("insets the card 16 points from the screen edges") does not say how safe areas combine with the inset; owner decision. Compare with the dashboard preview in T30 (scenario 24) and report deviations. | y (Julio, 2026-10-19) |
| A13 | Default look | Semantic system colors that follow the system theme: Android theme attributes/colors, iOS semantic `UIColor`s. **No luminance derivation**: with only `background_color` set the text keeps its semantic default; contrast is the author's responsibility (server/dashboard only warn). | Owner decision (closes former OQ-6). | y (Julio, 2026-10-18) |
| A14 | `trackEvent` before the `eligible` response, including the cold-start window | The SDK remembers the names tracked in this session (memory only, at most 32 distinct) and evaluates them once when the held messages arrive. Names reported **after `initialize` and before the first session of this process opens** are remembered too and belong to that first session. Names reported **before `initialize`**, or while **no session is open because the app went to background after a session had already run**, are ignored (no-op, no log of the name). Modeled as an engine flag `awaitingFirstSession`, set by `initialize` and cleared when the first session opens. [Provável] | Owner decision (closes former OQ-2); 32 on both SDKs. The 2026-10-19 amendment closes a window verified in code: the core is created lazily on `initialize`, replays the missed foreground, and the store work behind the session start is dispatched asynchronously (Android); on iOS `didFinishLaunching` runs with `applicationState == .inactive`, so the session opens only at `didBecomeActive`. Without the flag a name called right after `initialize` was dropped. The ordering is validated on device (T30 scenario 25). | y (Julio, 2026-10-19) |
| A15 | Flush before `eligible` and `429` handling | The pre-`eligible` flush is a single attempt per event (stop at the first failure) and `eligible` is called regardless; the queue is strict FIFO (cap 100, TTL 7 days), `404`/`422` drop the head. `eligible` is called regardless of the flush outcome, except after a `401` (A16). `429` on `events`: `Retry-After` clamped to 1..300 s, 60 s when absent or invalid, pause on a stored deadline. `429` on `eligible` (amended 2026-10-19): a parsed `Retry-After` above 60 s means the SDK gives up on `eligible` for the session without waiting; otherwise it waits `max(1, Retry-After)` s (60 s when absent or invalid) and retries, at most 3 waits. | Owner decision (closes former OQ-4), same model as the iOS SDK (IAM-03/04/31). Trade-off accepted: a message whose impression is still queued can be offered again by the server. | y (Julio, 2026-10-19) |
| A16 | `403` and `401` on the In-App routes | `403` (device/token pair rejected): no retry, no forced re-registration in this feature; `eligible`: stop for the session; events: stop the flush and keep the queue (a later registration can fix the token pair, and the next trigger tries again). The SDK logs one fixed warning, **only on `403`**, once per session per route (`eligible`, events), stating that In-App is inactive on this device until the next registration (no ids, no values). `401` (client key rejected): stops the flush and the fetch for the rest of the session on both routes, keeps the queue (cap 100, TTL 7 days), forces no re-registration (a registration does not fix a bad client key) and logs only the generic fixed operation+status line, never the registration text. The divergence from the contract's "re-register the device" is recorded in the CHANGELOG `[Unreleased]` (SDKIAM-61, T26). | Owner decision (closes former OQ-5; amended 2026-10-19 to attach the warning to `403` only); the registration paths already run at launch and on token refresh. | y (Julio, 2026-10-19) |
| A17 | Session and selection model (aligned with the iOS SDK) | Session = the existing foreground session; every foreground produces one `eligible`. Only the first renderable `session_start` message is shown; the others are neither queued nor re-fetched and stay eligible next session. `Notti.trackEvent(name)` is top level (not under `InAppMessages`). A visible message survives the background at a session turn; the next session's fetch skips that message id and drops the `session_start` candidates it would stack (held `event` messages of the old session are discarded). A response to `eligible` that arrives after its session ended is discarded (nothing shown, nothing held; amended 2026-10-19, parity with iOS IAM-06). | Owner decision; matches `zeep-notti-ios-sdk` IAM spec (session, extra `session_start`, visible-at-session-end rows). Specified in SDKIAM-02, 08, 09, 15 and the Edge Cases. | y (Julio, 2026-10-19) |
| A18 | Close-control accessibility label | A small in-code table (`en`, `pt-BR`), no resource bundle; any other language falls back to English (closes former OQ-3). | Owner decision; avoids podspec `resource_bundles` and Android `res/` changes. Note: the iOS SDK design plans resource bundles for the same label; the iOS SDK is the one that differs. | y (Julio, 2026-10-18) |
| A19 | Android system Back button during a display (replaces the former DD-10) | On `center` and `full` the Back is **consumed** (no-op: no dismiss, no event, no navigation of the host app behind the message). On `top`/`bottom` Back is not intercepted (no backdrop, the app stays interactive). Back never dismisses (SDKIAM-22); the accessibility close control stays the only way out. Mechanism in `design.md` (DD-10), [Incerto] until validated on a real device, including predictive back and gesture navigation. | The contract's `reason` enum has no "back", so Back cannot dismiss; letting it navigate the host app under a modal message is the surprising behavior this avoids. | y (Julio, 2026-10-19) |

### Open Questions

Remaining unconfirmed assumptions (`n`, the recommended defaults apply until the owner confirms): **A6** (registered in this process), **A7** (exact, case-sensitive event-name match), **A10** (device downloads `image_url` itself) and **A11** (tunable constants). All former questions (OQ-1 to OQ-6) were closed by the owner on 2026-10-18; the owner decisions of 2026-10-19 are A5, A12, A14 to A17 and A19, and SDKIAM-70. One decided rule is still to be validated on a device: the A14 ordering between `initialize` and the first session (T30 scenario 25), and the Android Back mechanism (A19, T30 scenario 26).

---

## User Stories

### P1: Fetch once per session ⭐ MVP

**User Story**: As the Notti backend, I want each foreground session to ask for eligible messages exactly once, after the device is registered and after queued In-App events were delivered, so frequency is computed on complete data and rate limits are never approached.

**Why P1**: Nothing else works without it.

**Acceptance Criteria**:

1. SDKIAM-01: WHEN a session is open AND the device is registered in this process (A5, A6) AND the SDK is initialized THEN the SDK SHALL call `POST /v1/apps/{app_id}/in-app-messages/eligible` with `Authorization: Bearer <client key>` and a JSON body of exactly `device_id` and `token` (the current persisted token).
2. SDKIAM-02: WHEN a screen changes, a view re-renders, a message closes, the JS bundle reloads while the app stays in the foreground, or `trackEvent` is called THEN the SDK SHALL NOT call `eligible` again. A new call happens only after a session boundary (background, then foreground again) or after a config change of `initialize` (SDKIAM-70).
3. SDKIAM-03: WHEN the in-app event queue is not empty at the moment a session wants to fetch THEN the SDK SHALL first try to flush it (strict FIFO, oldest first, single attempt per event) and then call `eligible` (SDKIAM-04).
4. SDKIAM-04: WHEN that flush fails (any non-success: network, `5xx`, `408`, `429`, `401`, `403`) THEN the SDK SHALL stop it at the first failure (one attempt per event, no backoff, strict FIFO) and SHALL call `eligible` regardless of the flush outcome, with one exception: a `401` (client key rejected) ends all In-App requests of the rest of the session (SDKIAM-49), so `eligible` is not called after it. A `403` in the flush logs the fixed inactive warning (SDKIAM-49) and `eligible` is still called. The remaining events stay queued (cap 100, 7 days) and are retried by the normal flush triggers (SDKIAM-50), except after a `401`, which waits for the next session. (Decided, A15, A16; same as the iOS SDK, IAM-03.)
5. SDKIAM-05: WHEN `eligible` answers `429` THEN the SDK SHALL parse `Retry-After` as an integer number of seconds (absent or not an integer number of seconds counts as 60 s). IF the parsed value is greater than 60 s THEN the SDK SHALL give up on `eligible` for this session without waiting and without a second request; OTHERWISE it SHALL NOT call again before `max(1, Retry-After)` seconds elapse (60 s when absent or invalid) and SHALL retry after the wait, at most 3 waits per fetch, then give up for this session. Waits are non-blocking. This cap applies to `eligible` only; the events route keeps the 1..300 s clamp and the stored pause deadline (SDKIAM-49). (Decided, A15; constants adjustable.)
6. SDKIAM-06: WHEN `eligible` fails with a network error, `408` or `5xx` THEN the SDK SHALL retry with exponential backoff (waits of 2 s, 4 s, 8 s, 16 s), at most 5 attempts in total, then give up for this session. A `401`, `403` or `422` SHALL NOT be retried and stops the fetch for this session. A `403` logs the one fixed warning that In-App is inactive on this device until the next registration (once per session per route, A16); a `401` forces no re-registration, also ends the flush for this session (SDKIAM-49) and logs only the generic fixed operation+status line, never the registration text; a `422` logs only the generic line.
7. SDKIAM-07: WHEN the response is `200` THEN the SDK SHALL parse it tolerantly: unknown fields ignored, a message entry that cannot be parsed skipped without failing the others, an empty `messages` array a normal outcome (nothing to show), and a body that is not a JSON object treated as a transient failure.
8. SDKIAM-70: WHEN `initialize` is called again with the **same** app id, client key and base URL (an RN reload) THEN the SDK SHALL preserve everything (held messages, remembered names, the visible display, the fetch state and the pause deadlines; state is process-wide, A5). WHEN it is called with a **different** app id, client key or base URL THEN the SDK SHALL reset the session state of the In-App engine (held messages, remembered names, the current fetch and any backoff or `429` pause deadlines), SHALL invalidate any in-flight `eligible` response (discarded on arrival, as in SDKIAM-15) and SHALL tear down a visible display WITHOUT sending any event; the next registration under the new config triggers one `eligible`. Persisted in-app queue records carry the `app_id` they were created for (SDKIAM-44): the flush SHALL send only records whose `app_id` equals the current one, and a config change SHALL purge the records of other apps (they would answer `404` against the new app; SDKIAM-45). (Decided, A5.)

**Independent Test**: With a stubbed server, foreground the app, register, and observe exactly one `eligible` request (with the documented body and header); background and foreground again and observe a second one; reload JS while foregrounded and observe none; re-initialize with the same config and observe none, with another app id and observe the engine reset and the other app's queued records purged.

---

### P1: Selection and triggers ⭐ MVP

**User Story**: As a product owner, I want a message to show at session start or when my app reports a moment, never two at once and never twice in a session, so the experience stays predictable.

**Why P1**: Defines what the user actually sees.

**Acceptance Criteria**:

1. SDKIAM-08: WHEN the `eligible` response is processed THEN the SDK SHALL show, right away, the first renderable message (SDKIAM-14) whose `trigger.type` is `session_start`, in the order the server returned them (oldest first).
2. SDKIAM-09: WHEN the response contains messages with `trigger.type: "event"` THEN the SDK SHALL keep them in memory only (never persisted) and SHALL discard them when the session ends; a held message never outlives its session, and a response that arrives after its session ended adds none (SDKIAM-15).
3. SDKIAM-10: WHEN the host calls `Notti.trackEvent(name)` THEN the SDK SHALL match `name` against held messages' `trigger.name` locally, exactly and case-sensitively (A7), and, if no message is currently pending or visible, SHALL show the **oldest** held, not-yet-shown message that matches. The name SHALL NOT be sent to the server, persisted, or logged. A match that finds a message currently visible SHALL leave the held messages untouched for a later call.
4. SDKIAM-11: WHEN selecting messages THEN the SDK SHALL ensure at most one message is pending or visible at a time and that no message id is shown more than once per session.
5. SDKIAM-12: THE SDK SHALL NOT persist any "already shown" or "dismissed" state across sessions (the server decides through frequency); the only memory is per-session, in-process.
6. SDKIAM-13: WHEN `trackEvent(name)` is called after `initialize` and either the `eligible` response of the current session has not been processed yet, or the FIRST session of this process has not opened yet, THEN the SDK SHALL remember the name (in memory only, at most 32 distinct names) and evaluate it as if it had just been called once the held messages arrive, then forget it. A name remembered before the first session opens belongs to that first session and is replayed once when its held messages arrive. Names are discarded at session end. Names reported before `initialize`, or while no session is open because the app went to background after a session had already run, are ignored (SDKIAM-59). The engine models the window with a flag `awaitingFirstSession`, set by `initialize` and cleared when the first session opens. [Provável; the ordering is validated on device, T30 scenario 25] (Decided, A14.)
7. SDKIAM-14: WHEN a message is evaluated for display THEN the SDK SHALL treat it as **not renderable** and skip it (no impression, no event) if any of these holds: `id` is not a non-empty string; both `title` and `body` are empty after trimming; `trigger.type` is unknown or an `event` trigger has an empty `name`; (an unknown `action.type` does NOT make a message non-renderable: the click is reported and the listener receives `action: null`). Fields it does not know are ignored; an unknown `format` renders `center` unchanged. A button is kept only with a non-empty `id` and a non-empty `label` (then at most the first two VALID buttons are kept); an invalid button is dropped without making the message non-renderable. An `image_url` that is not `https` is ignored (the message renders without an image) and an `image_action` without an image (absent or ignored `image_url`) is ignored too. (Parity with iOS IAM-16.)
8. SDKIAM-15: WHEN a session ends while a message is visible THEN the SDK SHALL keep that display (its timer paused in the background, SDKIAM-37) and SHALL treat its message id as already shown in the next session; a `session_start` candidate selected while a display is still visible SHALL be dropped for that session (never queued behind it). Held `event` messages of the ended session are discarded. A response to `eligible` that arrives after the session it was requested for has ended SHALL be discarded: nothing is displayed and nothing is held, even if a newer session is already open (parity with iOS IAM-06).

**Independent Test**: Stub a response with two `session_start` and two `event` messages: exactly the first `session_start` shows; `trackEvent` of an unknown name does nothing; `trackEvent` of the event name shows the oldest matching one only after the visible one is closed; a closed message is never shown again in the session.

---

### P1: Native layouts ⭐ MVP

**User Story**: As an end user, I want the message to look native, fit my screen and never trap me.

**Why P1**: The visible product.

**Acceptance Criteria**:

1. SDKIAM-16: THE SDK SHALL render the four formats `top`, `center`, `bottom`, `full` natively (Android Views, iOS UIKit) per the contract's Layouts table; an unknown `format` SHALL render as `center`.
2. SDKIAM-17: WHEN `format` is `top` or `bottom` THEN the SDK SHALL render a bar below the top safe area / above the bottom safe area, at most 40% of the screen height, with no backdrop, and touches outside the bar SHALL reach the app underneath.
3. SDKIAM-18: WHEN `format` is `center` THEN the SDK SHALL render a card centered on screen, at most 90% of the width, over a 50% black backdrop; the backdrop SHALL block touches to the app underneath.
4. SDKIAM-19: WHEN `format` is `full` THEN the SDK SHALL render the message edge to edge inside the safe areas with the buttons pinned to the bottom; there is no backdrop.
5. SDKIAM-20: WHEN the message has an image THEN the SDK SHALL show it as a small leading thumbnail in `top`/`bottom`, and above the text in `center`/`full`.
6. SDKIAM-21: THE SDK SHALL always show a close control, whatever the layout, the timer, the style or the content size, with a touch target of at least 44 pt (iOS) / 48 dp (Android), and with a contrast-safe glyph against its background (text color, or white over an image).
7. SDKIAM-22: THE SDK SHALL accept exactly these dismiss gestures: `top` swipe up (`swipe`); `bottom` swipe down (`swipe`); `center` tap on the backdrop (`outside_tap`); `full` none; all layouts the close control (`close_button`). No other gesture, including Android's Back button or an iOS tap outside a `top`/`bottom` bar, dismisses. On Android, WHILE a `center` or `full` display is attached, the system Back button SHALL be consumed (no-op: no dismiss, no event, no navigation of the host app behind the message); on `top`/`bottom` Back SHALL NOT be intercepted (no backdrop, the app stays interactive). On `full` the close control is the only way out (A19).
8. SDKIAM-23: WHEN a `top`/`bottom` message has two buttons THEN the SDK SHALL place them side by side and wrap them to a column when they do not fit the available width.
9. SDKIAM-24: WHEN the text, the image and the buttons together exceed the layout's bound (large font scale, long body, small screen, landscape) THEN the text area SHALL scroll while the buttons and the close control stay reachable; nothing SHALL be clipped without a way to reach it.
10. SDKIAM-25: WHEN the device rotates, the window resizes, or (Android) the Activity is recreated or replaced during a display THEN the same display SHALL continue (same message, same remaining auto-dismiss time) and SHALL NOT send another `impression`.

**Independent Test**: Render each layout on a small phone, a large phone and a tablet, in portrait and landscape, at the default and the largest font scale, in light and dark: the message stays inside the bounds, the close control and the buttons are reachable, rotation keeps the display and sends no second impression.

---

### P1: Style tokens ⭐ MVP

**User Story**: As a product owner, I want my brand colors and alignment to apply, and bad input to never break a message.

**Why P1**: The visual identity; closed token set keeps the dashboard preview and the SDKs aligned.

**Acceptance Criteria**:

1. SDKIAM-26: WHEN `background_color`, `text_color`, `button_color` or `button_text_color` is `#RRGGBB` THEN the SDK SHALL apply it to, respectively, the card/bar background, the title and body, the button background, and the button label. A value that does not parse (wrong length, no `#`, non-hex, alpha form) SHALL be ignored and that token SHALL use the SDK default; parsing SHALL never throw and never prevent the message from showing. Lower-case hex is accepted.
2. SDKIAM-27: WHEN `text_align` is `left`, `center` or `right` THEN the SDK SHALL align title and body accordingly; absent or any other value means `left` (A1).
3. SDKIAM-28: WHEN `margin` is `true` or absent THEN the SDK SHALL inset the bar/card 16 pt (dp) **measured from the safe-area edge**: `top` below the safe-area top, `bottom` above the safe-area bottom, `full` on all four sides, and the bars' width is the safe-area width minus 16 on each side; WHEN `false` the bar/card/message SHALL touch the safe-area edges on all sides, horizontally too, and SHALL never be placed under the notch, status bar, cutout or home indicator; `center` ignores `margin`. Same rule on both platforms (A2, A12).
4. SDKIAM-29: WHEN `button_color` or `button_text_color` is set THEN the SDK SHALL apply it to **all** buttons (the absent one keeps the default), so no button keeps a different style (A3). With neither set, the first button is filled and the second is outlined.
5. SDKIAM-30: WHEN `style` is `null` or a token is absent THEN the SDK SHALL use its defaults, which SHALL be semantic system colors following the light/dark system theme (A13). WHEN only `background_color` is set THEN the text keeps its semantic default; the SDK SHALL NOT derive or adjust colors for contrast (the author's responsibility).

**Independent Test**: Table-driven tests over color strings, alignments and margin values asserting the resolved style; a rendered message with `background_color` set and no `text_color` has readable text in both themes.

---

### P1: Plain text and click delivery ⭐ MVP

**User Story**: As the host app owner, I want server-supplied text rendered inert, and every link action handed to my code untouched, so only my app decides what opens.

**Why P1**: Security and stability; links are the integrator's job (A9).

**Acceptance Criteria**:

1. SDKIAM-31: THE SDK SHALL render `title` and `body` as plain text (Android `TextView.setText(CharSequence)` of the raw string, never `Html.fromHtml`, never `Linkify`/`autoLink`; iOS `UILabel.text`/`UITextView` with `dataDetectorTypes = []`, never `NSAttributedString` from HTML/Markdown, never `WKWebView`). Newlines in `body` SHALL be preserved.
2. SDKIAM-32: THE SDK SHALL NOT open, resolve, validate, rewrite or log any `url` or `deeplink` value, and SHALL NOT call any URL-opening API (Android `startActivity`/`ACTION_VIEW`, iOS `UIApplication.open`/`openURL`). An action is delivered exactly as received (SDKIAM-67). A repository check (T29) greps the In-App sources for these APIs.
3. SDKIAM-33: WHEN the user taps a button THEN the SDK SHALL, in this order: have the `impression` already persisted, enqueue `click` with that button's `id` (SDKIAM-42), deliver the click to the listener (SDKIAM-67), and close the display. The close SHALL NOT report a `dismiss`. A second tap on the same display in the same turn SHALL be ignored.
4. SDKIAM-34: WHEN the user taps the body of a `top` or `bottom` message that has at least one button THEN the SDK SHALL behave exactly as if the **first** button was tapped (`click` with that button's id, listener call with that button, close); with no buttons the body is not tappable. In `center`/`full` the body is not tappable.
5. SDKIAM-35: WHEN the message has an `image_action` and the user taps the image THEN the SDK SHALL report `click` with `button_id: "image"`, deliver the click (with the image action) to the listener, and close the message. Without `image_action`, or when the image failed to load, there is no tappable image.

**Independent Test**: A body containing `<b>x</b>`, `**x**` and `https://example.invalid` renders literally and is not tappable; tapping a `deeplink` button queues one `click`, calls a recording listener with the untouched value, closes without `dismiss`, and a grep of the In-App sources finds no URL-opening API.

---

### P2: Auto dismiss

**User Story**: As a product owner, I want a message to leave on its own after a time, without making it impossible to close it earlier.

**Acceptance Criteria**:

1. SDKIAM-36: WHEN `dismiss_after_seconds` is an integer from 1 to 300 THEN the SDK SHALL start a timer when the message becomes visible; a value outside that range, `null` or absent SHALL mean no timer.
2. SDKIAM-37: WHILE the app is in the background, or the display is detached between two Android Activities, the countdown SHALL be paused and SHALL continue with the remaining time when the display is visible again.
3. SDKIAM-38: WHEN the timer fires THEN the SDK SHALL close the message and report `dismiss` with `reason: "auto"`.
4. SDKIAM-39: THE close control SHALL stay available during the countdown; a manual close reports the gesture's own reason and cancels the timer.

**Independent Test**: `dismiss_after_seconds: 8`: closes after 8 s of foreground time, reports `auto`; backgrounding for 20 s in the middle does not consume time; tapping close at 3 s reports `close_button`.

---

### P1: Reliable event reporting ⭐ MVP

**User Story**: As the Notti backend, I want impressions, clicks and dismissals to arrive exactly once each and in a sane order, even offline, so frequency and metrics are right.

**Why P1**: A lost impression makes a `once` message eligible again; a click without an impression inflates CTR (contract, Notes for SDK authors).

**Acceptance Criteria**:

1. SDKIAM-40: WHEN a display becomes visible (attached to a window and laid out, app in the foreground) THEN the SDK SHALL enqueue exactly one `impression` for that display. A re-render, rotation, re-layout, Activity recreation or window resize of the same display SHALL NOT enqueue another one.
2. SDKIAM-41: THE `impression` of a display SHALL be persisted in the queue before any `click` or `dismiss` of that display can be enqueued, and the queue SHALL send in insertion order, so the server always sees the impression first.
3. SDKIAM-42: WHEN the user taps a button, the image (with `image_action`), or the body of a `top`/`bottom` message THEN the SDK SHALL enqueue a `click` carrying `button_id` = the button's `id`, `image`, or the first button's `id` respectively, and no `reason`.
4. SDKIAM-43: WHEN a message closes by the close control, a swipe, a backdrop tap or the timer without a click THEN the SDK SHALL enqueue a `dismiss` with `reason` `close_button`, `swipe`, `outside_tap` or `auto` respectively and no `button_id`. A display SHALL produce at most one terminal event (`click` or `dismiss`), never both, and never a terminal event without its `impression`.
5. SDKIAM-44: WHEN an event is created THEN the SDK SHALL generate its `event_id` (UUID v4) at that moment, persist it with the event together with the `app_id` it was created for, and send the same value on every retry.
6. SDKIAM-45: THE SDK SHALL persist each event to disk before the first send attempt, with the real `occurred_at` (RFC3339 UTC, captured when the event happened), survive process death and offline periods, and send events oldest first, one at a time. The flush SHALL send only records whose `app_id` equals the current app id (a record of another app is never sent), and a config change SHALL purge the records of other apps (SDKIAM-70).
7. SDKIAM-46: WHEN an event is older than 7 days (by `occurred_at`) at flush time THEN the SDK SHALL drop it without sending.
8. SDKIAM-47: WHEN the server answers `201` or `200` (`duplicate: true`) THEN the SDK SHALL remove the event from the queue.
9. SDKIAM-48: WHEN the server answers `404` or `422` THEN the SDK SHALL remove the event without retrying.
10. SDKIAM-49: WHEN the server answers an event `429` THEN the SDK SHALL pause the flush until `Retry-After` elapses (clamp 1..300 s and 60 s default when absent or invalid; unlike `eligible`, SDKIAM-05, events have no give-up threshold; the pause is an in-memory deadline shared by later triggers, separate from the `eligible` pause) and keep the queue with the same `event_id`s; WHEN it answers `5xx` or `408`, or the network fails (`408` is a transient failure on both routes, same policy as `5xx` and network errors) THEN the SDK SHALL retry the same head event with the SDKIAM-06 backoff (5 attempts) and then stop the flush keeping the queue (in the pre-`eligible` single-attempt flush it stops at the first failure); WHEN it answers `403` THEN the SDK SHALL stop the flush, keep the queue (bounded by the cap of 100 and the 7-day TTL), force no re-registration (A16) and log one fixed warning, without identifiers, saying that In-App is inactive on this device until the next registration, once per session per route (events and `eligible` are separate routes); WHEN it answers `401` (client key rejected) THEN the SDK SHALL stop the flush and the `eligible` fetch for the rest of the session, keep the queue, force no re-registration and log only the generic fixed operation+status line, never the registration text. `404`/`422` drop the head (SDKIAM-48).
11. SDKIAM-50: THE SDK SHALL attempt a flush when: an event is enqueued; the device registration succeeds; the app comes to the foreground; the network becomes available; and before every `eligible` call (SDKIAM-03). Flushes SHALL be single-flight (no concurrent flushes).
12. SDKIAM-51: THE in-app event queue SHALL be separate from the CTR event queue (`NottiEventStore`): a CTR event stuck on `5xx`/`429` SHALL NOT delay In-App events, and In-App events SHALL NOT evict CTR events.
13. SDKIAM-52: THE SDK SHALL stay under the per-device limits by construction: one `eligible` per session, one in-app event request in flight at a time, no parallel flushes, and a `429` stops the queue until its `Retry-After`.

**Independent Test**: With a stubbed server: a display produces `impression` then `click` in that order with distinct `event_id` UUIDs; going offline, closing the message, killing the process and relaunching delivers the same `event_id`s; a `200 duplicate` clears the queue; an 8-day-old event is never sent; a `429` with `Retry-After: 2` delays the next send by at least 2 s.

---

### P1: MAU, privacy and logging ⭐ MVP

**User Story**: As Notti and the integrator's compliance owner, I want In-App to add no MAU effect, no sensitive logs, and an honest data-collection disclosure.

**Acceptance Criteria**:

1. SDKIAM-53: WHEN In-App events or fetches happen THEN the SDK SHALL NOT trigger any device `PATCH`, heartbeat or other call whose purpose is to update the device's `last_seen_at`; the SDK relies on the server guarantee that In-App events do not count as MAU (`zeep-notti/internal/inapp/events.go:41`, contract MAU section). [Certo for the server; the SDK's side is "do not add one".]
2. SDKIAM-54: THE SDK SHALL NOT log, in any build, the push token, `device_id`, client key, message `title`/`body`/`image_url`/action values, `button_id`, event names passed to `trackEvent`, or a request/response body. Log lines carry only an operation label and an HTTP status or error class.
3. SDKIAM-55: TEST fixtures, example payloads and docs SHALL use only synthetic values (`example.invalid`, `fixture`, all-zero UUIDs).
4. SDKIAM-56: `README.md` SHALL list, in "Data collected by the SDK", the In-App data: `device_id` and `token` in the fetch body; per display `event_id`, `type`, `button_id`, `reason`, `occurred_at` (linked to the device, product-interaction nature like CTR events), the new local queue key, and the **image request to the message author's host** (A10). The iOS `PrivacyInfo.xcprivacy` declares no new data type (same data already covered by the pending nutrition-label decision recorded in that file); the decision is re-flagged for the owner, not silently resolved. [Provável]
5. SDKIAM-57: WHEN the SDK downloads `image_url` THEN it SHALL require `https`, send no `Authorization` header, cookie, device id or token, refuse redirects to a non-`https` URL, bound the download size and time (A11), decode to a size bounded by the screen, keep at most a small in-memory cache (no disk cache), and treat any failure as "no image" without blocking or failing the message.

**Independent Test**: Capture the `eligible` and `events` requests: no `PATCH /devices` follows; capture the image request: no `Authorization`, no cookies; grep the production logs of a full run for the synthetic token/title/event name: zero hits.

---

### P1: Public API (`trackEvent`, click listener), docs, Expo ⭐ MVP

**Acceptance Criteria**:

1. SDKIAM-58: THE SDK SHALL expose `Notti.trackEvent(name: string): void`, forwarded to the Turbo Module (`NativeNotti.ts`), implemented natively on both platforms (AD-001), returning immediately.
2. SDKIAM-59: WHEN `trackEvent` is called with an empty or whitespace-only name, before `initialize`, while no session is open and none is awaited (the app went to background after a session had already run), or on a torn-down module THEN it SHALL be a safe no-op: no throw, no crash, no network call, no log of the name. Between `initialize` and the opening of the first session of the process the name is remembered, not dropped (SDKIAM-13, A14). It never returns a value or a promise.
3. SDKIAM-60: THE SDK SHALL add no public JS API in this feature other than `trackEvent` (SDKIAM-58) and `Notti.InAppMessages.addClickListener` (SDKIAM-67): no lifecycle callbacks, no other events, no getters.
4. SDKIAM-61: THE change SHALL be additive (no existing signature changes; minor version bump) and SHALL update the Codegen spec `src/NativeNotti.ts` (method + event emitter), `src/index.tsx`, `README.md` (API reference, a highlighted "links are yours to handle" warning, data collected, privacy, local storage keys, known limitations, smoke test) and `CHANGELOG.md` under `[Unreleased]`, including a note that on `403` the SDK deliberately does not re-register (the contract says "re-register") and In-App stays inactive on the device until the next registration.
5. SDKIAM-62: THE Expo config plugin (`plugin/src/withNotti.ts`) and the library `AndroidManifest.xml` SHALL need no change: the UI is programmatic, no new permission or `<queries>` entry is used, and iOS needs no `Info.plist` key.
6. SDKIAM-67: THE SDK SHALL expose `Notti.InAppMessages.addClickListener(handler: (click: NottiInAppClick) => void): EventSubscription`, delivered through a Codegen event emitter `onInAppMessageClicked` (same mechanism as `onNotificationClicked`, `NativeNotti.ts:70`). `NottiInAppClick` is `{ messageId: string; buttonId: string; action: { type: 'url' | 'deeplink'; value: string } | null }`, mirroring the iOS SDK's `NottiInAppClick` (`messageId`, `buttonId`, `action`). `buttonId` is the button's id, `image` for the image, or the first button's id for a bar body tap; `action` is `null` (never `undefined`) for an action type the SDK does not know and `value` is untouched. Multiple listeners are supported; removing the subscription stops delivery.
7. SDKIAM-68: WHEN a click happens and no listener is subscribed (or the module was torn down) THEN the SDK SHALL still report the `click` and close the display, SHALL open nothing, SHALL NOT buffer the click for a later listener, and SHALL log one fixed warning containing no values (no ids, URLs or names).
8. SDKIAM-69: THE `README.md` SHALL state, prominently (a callout at the top of the In-App section and in the API reference row), that without a registered click listener no link action does anything, and SHOULD show a listener example that routes `deeplink` values through the app's own navigation and `url` values through `Linking`. The example app SHALL register one (T28).

**Independent Test**: `git diff` of `plugin/` and `android/src/main/AndroidManifest.xml` is empty; Jest asserts `trackEvent` forwards the exact string and `addClickListener` subscribes to the emitter and passes the payload unchanged; native tests assert the no-op cases.

---

### P2: Accessibility

**Acceptance Criteria**:

1. SDKIAM-63: THE close control SHALL have an accessible label ("Close", from an in-code table: en, pt-BR, any other language falls back to English, A18), buttons SHALL use their `label` as accessible name, the title SHALL be an accessibility heading, a `center`/`full` message SHALL be modal for VoiceOver/TalkBack (content behind it not reachable) and focus SHALL move to the message when it appears; `top`/`bottom` SHALL be announced without taking focus away from the app. An iOS accessibility escape gesture on a `center`/`full` message SHALL act as the close control (`close_button`).
2. SDKIAM-64: THE text SHALL scale with the system font setting (Android `sp`, iOS Dynamic Type via text styles with `adjustsFontForContentSizeCategory`); contrast is not validated by the SDK (contract).

---

### P1: Platform parity and tests ⭐ MVP

**Acceptance Criteria**:

1. SDKIAM-65: EVERY acceptance criterion above SHALL hold identically on Android and iOS; a deliberate platform difference SHALL be listed in `design.md` with its reason.
2. SDKIAM-66: EVERY behavioral criterion SHALL be verified by a native test at the layer that implements it (Kotlin JUnit + Robolectric + `MockWebServer`; Swift XCTest + `StubURLProtocol`), not only by the mocked Jest facade (lesson L-001), with an explicit timeout on every `MockWebServer.takeRequest` (lesson L-003). Criteria that cannot be verified in a unit test (real window presentation, VoiceOver/TalkBack, real gestures) SHALL be listed in the device-validation task.

---

## Edge Cases

- WHEN the response lists the same message `id` twice THEN the SDK SHALL show it at most once (SDKIAM-11 covers it by id).
- WHEN the response contains several renderable `session_start` messages THEN only the first is shown this session; the others are not queued behind it (contract: "show the first ... right away"). They were never impressed, so the server offers them again next session (decided, A17).
- WHEN the app is backgrounded between "selected" and "visible" (waiting for an image or for an Activity/scene to be active) THEN the SDK SHALL NOT send an impression; the pending display is dropped if the session ends before it became visible, and the message will be offered again by the server because no impression was recorded.
- WHEN no Activity (Android) or active scene (iOS) is available when a message is ready (cold start, transition, host showing a full-screen OS UI) THEN the SDK SHALL wait for the next resumed Activity / active scene within the same session and SHALL NOT send an impression until then.
- WHEN the process dies while a message is visible THEN the display is gone; the persisted `impression` is delivered at the next flush; no `dismiss` is invented. The next session fetches again and the server's frequency rules decide.
- WHEN the network is offline at session start THEN `eligible` fails with the SDKIAM-06 schedule; on reconnect (network observer) the SDK SHALL resume the fetch of the **same** session if it gave up because of a network/`5xx`/`408` failure (not after `401`/`403`/`422`, nor after exhausting the `429` waits or giving up on a `Retry-After` above 60 s), at most once per reconnect, still without a second successful fetch in one session.
- WHEN the image fails to load, times out, or is too large THEN the message SHALL show without the image (and without a tappable image area).
- WHEN `trackEvent` is called in a tight loop THEN the cost SHALL stay O(held messages) per call, with no network and no disk I/O.
- WHEN the host app is replaced mid-session by an RN reload, or `initialize` is called again with the same app id, client key and base URL, THEN the visible display, the held messages, the remembered names, the pause deadlines and the per-session shown set SHALL survive (state is process-wide, A5), and no second `eligible` is sent.
- WHEN `initialize` is called again with a DIFFERENT app id, client key or base URL THEN the engine resets its session state (held messages, remembered names, the current fetch, backoff and `429` pause deadlines), a response to the old config's in-flight `eligible` is discarded on arrival, a visible display is torn down WITHOUT any event, and the queued records of other apps are purged and never sent (SDKIAM-70); the next registration under the new config triggers one `eligible`.
- WHEN the response to `eligible` arrives after its session ended (background in the meantime, even if a new session is already open) THEN it SHALL be discarded: nothing is displayed and nothing is held; held `event` messages of the ended session were dropped at the session end (SDKIAM-15).
- WHEN `trackEvent` is called right after `initialize` and the first session of the process has not opened yet (Android: the core replays the missed foreground and the session start is dispatched asynchronously; iOS: `didFinishLaunching` runs with the application `.inactive`, so the session opens at `didBecomeActive`) THEN the name SHALL be remembered (memory only, same 32-distinct cap) and replayed once, as part of the first session, when its held messages arrive; a name reported before `initialize`, or while no session is open after a session already ran (app in background), is ignored without logging it (SDKIAM-13, SDKIAM-59, A14).
- WHEN `eligible` answers `429` with `Retry-After` above 60 s THEN the SDK gives up on `eligible` for this session with no wait and no second request; with `Retry-After` of 60 s or less (or absent or invalid, counted as 60 s) it waits `max(1, Retry-After)` s and retries, at most 3 waits (SDKIAM-05).
- WHEN a `401` or a `403` answers an In-App request THEN `403` logs the one fixed "In-App is inactive on this device until the next registration" warning (once per session per route) and `401` logs only the generic operation+status line and ends the flush and the fetch for the session; neither forces a re-registration (SDKIAM-49, A16).
- WHEN the Android system Back button is pressed while a `center` or `full` message is attached THEN nothing happens (no dismiss, no event, no host navigation); on `top`/`bottom` the press reaches the host app as usual (SDKIAM-22, A19).
- WHEN a message has a button with an empty `id` or `label`, an `image_url` that is not `https`, or an `image_action` without a usable image THEN the invalid part is dropped and the message still shows (SDKIAM-14).
- WHEN `margin` is `false` THEN the bar/card/message touches the safe-area edges (horizontally too) and is never under a notch, cutout, status bar or home indicator (SDKIAM-28, A12).
- WHEN the device clock is wrong THEN `occurred_at` carries that clock; the server substitutes its own time when it is outside its window (contract), and the 7-day drop uses the device clock. No SDK-side correction is attempted.
- WHEN the same `event_id` is resent after a timeout whose response was lost THEN the server answers `200 duplicate` and the SDK removes the event (SDKIAM-47).
- WHEN a `button_id` was removed server-side before the click is flushed THEN the server answers `422 invalid_content` and the SDK drops the event (SDKIAM-48).

---

## Requirement Traceability

| Requirement ID | Story | Phase | Status |
| --- | --- | --- | --- |
| SDKIAM-01 | P1: Fetch once per session (call shape) | Tasks | T4/T6/T13, T16/T18/T25 |
| SDKIAM-02 | P1: Fetch once per session (never per screen/render/reload; config change is SDKIAM-70) | Tasks | T6/T13, T18/T25 |
| SDKIAM-03 | P1: Fetch once per session (flush before fetch) | Tasks | T6, T18 |
| SDKIAM-04 | P1: Fetch once per session (single-attempt flush, `eligible` regardless except after `401`, A15/A16) | Tasks | T6, T18 |
| SDKIAM-05 | P1: Fetch once per session (`eligible` 429: give up above 60 s, else wait `max(1, Retry-After)`, 60 s default, 3 waits) | Tasks | T4/T6, T16/T18 |
| SDKIAM-06 | P1: Fetch once per session (backoff, terminal 4xx, 403 warning vs 401 generic line) | Tasks | T4/T6, T16/T18 |
| SDKIAM-07 | P1: Fetch once per session (tolerant parse) | Tasks | T2, T14 |
| SDKIAM-08 | P1: Selection (session_start first renderable) | Tasks | T5/T6, T17/T18 |
| SDKIAM-09 | P1: Selection (event messages held in memory, dropped at session end, none from a late response) | Tasks | T5/T6, T17/T18 |
| SDKIAM-10 | P1: Selection (trackEvent local exact match) | Tasks | T5/T13, T17/T25 |
| SDKIAM-11 | P1: Selection (one visible, once per session) | Tasks | T5, T17 |
| SDKIAM-12 | P1: Selection (no persistent shown state) | Tasks | T5, T17 |
| SDKIAM-13 | P1: Selection (trackEvent before response and in the cold-start window, `awaitingFirstSession`, A14) | Tasks | T5/T6/T13, T17/T18/T25 (+ T30 scenario 25) |
| SDKIAM-14 | P1: Selection (renderability rules: valid buttons, https image, image action, unknown format) | Tasks | T2/T5, T14/T17 |
| SDKIAM-15 | P1: Selection (session end with visible display, late `eligible` response discarded) | Tasks | T5/T6/T10, T17/T18/T22 |
| SDKIAM-16 | P1: Layouts (four formats, unknown to center) | Tasks | T7/T8, T19/T20 |
| SDKIAM-17 | P1: Layouts (bars) | Tasks | T7/T8/T10, T19/T20/T22 |
| SDKIAM-18 | P1: Layouts (center) | Tasks | T7/T8, T19/T20 |
| SDKIAM-19 | P1: Layouts (full) | Tasks | T7/T8, T19/T20 |
| SDKIAM-20 | P1: Layouts (image placement) | Tasks | T8/T11, T20/T23 |
| SDKIAM-21 | P1: Layouts (close control) | Tasks | T8/T9, T20/T21 |
| SDKIAM-22 | P1: Layouts (gestures; Android Back consumed on center/full, not intercepted on bars) | Tasks | T9/T10, T21 (+ T30 scenario 26) |
| SDKIAM-23 | P1: Layouts (two buttons) | Tasks | T8, T20 |
| SDKIAM-24 | P1: Layouts (overflow, scroll) | Tasks | T8, T20 |
| SDKIAM-25 | P1: Layouts (rotation/recreation continuity) | Tasks | T10, T22 |
| SDKIAM-26 | P1: Style (colors) | Tasks | T2/T7, T14/T19 |
| SDKIAM-27 | P1: Style (text_align) | Tasks | T7/T8, T19/T20 |
| SDKIAM-28 | P1: Style (margin measured from the safe-area edge, false touches it, A12) | Tasks | T7/T8, T19/T20 |
| SDKIAM-29 | P1: Style (button tokens) | Tasks | T7/T8, T19/T20 |
| SDKIAM-30 | P1: Style (null/defaults, semantic system colors, no derivation) | Tasks | T7/T8, T19/T20 |
| SDKIAM-31 | P1: Safe actions (plain text) | Tasks | T8, T20 |
| SDKIAM-32 | P1: Click delivery (SDK never opens links) | Tasks | T12/T24, T29 |
| SDKIAM-33 | P1: Click delivery (click, listener, close; no dismiss) | Tasks | T6/T9/T10/T12, T18/T21/T22/T24 |
| SDKIAM-34 | P1: Safe actions (bar body tap) | Tasks | T9, T21 |
| SDKIAM-35 | P1: Safe actions (image tap) | Tasks | T9/T11, T21/T23 |
| SDKIAM-36 | P2: Auto dismiss (range) | Tasks | T2/T10, T14/T22 |
| SDKIAM-37 | P2: Auto dismiss (pause/resume) | Tasks | T10, T22 |
| SDKIAM-38 | P2: Auto dismiss (reason auto) | Tasks | T10, T22 |
| SDKIAM-39 | P2: Auto dismiss (close stays) | Tasks | T9/T10, T21/T22 |
| SDKIAM-40 | P1: Events (impression once per display) | Tasks | T10, T22 |
| SDKIAM-41 | P1: Events (impression before click/dismiss) | Tasks | T3/T10, T15/T22 |
| SDKIAM-42 | P1: Events (click payload) | Tasks | T6/T10, T18/T22 |
| SDKIAM-43 | P1: Events (dismiss payload, single terminal) | Tasks | T6/T10, T18/T22 |
| SDKIAM-44 | P1: Events (event_id, record carries `app_id`) | Tasks | T3, T15 |
| SDKIAM-45 | P1: Events (persistence, order, occurred_at, flush only the current `app_id`, purge on config change) | Tasks | T3/T6, T15/T18 |
| SDKIAM-46 | P1: Events (7-day drop) | Tasks | T3/T6, T15/T18 |
| SDKIAM-47 | P1: Events (201/200 success) | Tasks | T4/T6, T16/T18 |
| SDKIAM-48 | P1: Events (404/422 drop) | Tasks | T4/T6, T16/T18 |
| SDKIAM-49 | P1: Events (429 pause, 5xx/408/network backoff, 403 inactive warning once per session per route, 401 generic line and session stop, keep queue, no re-registration, A15/A16) | Tasks | T4/T6, T16/T18 |
| SDKIAM-50 | P1: Events (flush triggers, single-flight) | Tasks | T6/T13, T18/T25 |
| SDKIAM-51 | P1: Events (queue separate from CTR) | Tasks | T3, T15 |
| SDKIAM-52 | P1: Events (rate limits by construction) | Tasks | T6, T18 |
| SDKIAM-53 | P1: MAU (no last_seen trigger) | Tasks | T13, T25 (+ T29 review) |
| SDKIAM-54 | P1: Privacy (no sensitive logs) | Tasks | T4/T6/T13, T16/T18/T25 (+ T29 review) |
| SDKIAM-55 | P1: Privacy (synthetic fixtures) | Tasks | all test tasks, T26 |
| SDKIAM-56 | P1: Privacy (README data collected, PrivacyInfo note) | Tasks | T26, T27 |
| SDKIAM-57 | P1: Privacy (image fetch hygiene) | Tasks | T11, T23 |
| SDKIAM-58 | P1: API (`trackEvent`) | Tasks | T1, T13, T25 |
| SDKIAM-59 | P1: API (no-op robustness; cold-start window remembers, A14) | Tasks | T1, T5/T6/T13, T17/T18/T25 |
| SDKIAM-60 | P1: API (only `trackEvent` and the click listener) | Tasks | T1, T29 |
| SDKIAM-61 | P1: API (additive, docs, Codegen, CHANGELOG note on 403 divergence) | Tasks | T1, T26 |
| SDKIAM-62 | P1: Expo/manifest unchanged | Tasks | T29 |
| SDKIAM-63 | P2: Accessibility (labels from the in-code table, modal, focus) | Tasks | T9, T21, T30 |
| SDKIAM-64 | P2: Accessibility (font scaling) | Tasks | T8, T20, T30 |
| SDKIAM-65 | P1: Parity | Tasks | T29 |
| SDKIAM-66 | P1: Native tests, explicit takeRequest timeouts | Tasks | all, T30 |
| SDKIAM-67 | P1: API (click listener, Codegen emitter, `NottiInAppClick` payload) | Tasks | T1, T12/T13, T24/T25 |
| SDKIAM-68 | P1: API (no listener: report, close, open nothing, no buffer, one warning) | Tasks | T6/T12, T18/T24 |
| SDKIAM-69 | P1: Docs (README callout, example listener) | Tasks | T26, T28 |
| SDKIAM-70 | P1: Fetch once per session (re-initialize: same config preserves, different config resets, `app_id` on queue records, purge) | Tasks | T3/T5/T6/T13, T15/T17/T18/T25 (+ T30 scenario 27) |

**Coverage:** 70 total, 70 mapped to tasks, 0 unmapped.

---

## Success Criteria

- [ ] On a real Android device and a real iOS device against a running `zeep-notti` with `in-app-rich-messages`: a `session_start` message shows once at launch in each of the four layouts, an `event` message shows on `trackEvent`, and the dashboard metrics (impressions, reach, clicks per button and `image`, dismiss rate, auto-dismissed) match what the tester did.
- [ ] A rotation, an RN reload and a background/foreground cycle produce no duplicate `impression` and no second message in the same session.
- [ ] An impression/click/dismiss created in airplane mode, followed by a force-kill and relaunch, is delivered with the same `event_id` and the server shows no duplicate.
- [ ] `git diff` shows exactly two public JS additions (`trackEvent`, `Notti.InAppMessages.addClickListener`); `plugin/` and `AndroidManifest.xml` untouched; no URL-opening API in the In-App sources.
- [ ] A scan of production logs and test fixtures finds no token, device id, message text, URL or event name.
- [ ] Android JUnit and iOS XCTest suites include a test for every SDKIAM requirement (or the device-validation task lists it), and the definition-of-done gate passes on both platforms.
