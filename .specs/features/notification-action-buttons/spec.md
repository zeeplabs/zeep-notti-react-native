# Notification Action Buttons Specification

## Problem Statement

The Compose screen in the dashboard (`zeep-notti` repo,
`web/src/screens/compose/AdvancedSettingsSection.tsx`) already ships two
disabled inputs labeled "Action ID" and "Action label" — a UI placeholder with
no model, no backend field, and no client support. An admin wants to send a
push with one or more tappable action buttons (e.g. "Accept" / "Reject") that
fire without opening the app.

The two platforms are not symmetric, and this spec treats them accordingly:

- **iOS/APNs cannot carry a dynamic button label in the push payload at all.**
  Action buttons on iOS are `UNNotificationAction`s grouped into a
  `UNNotificationCategory`, and categories must be **registered by the host
  app at boot** (`UNUserNotificationCenter.setNotificationCategories(_:)`).
  The push payload only ever carries a category *identifier*
  (`aps.category`) — which this SDK and the backend already support today
  (`IOSOptions.Category` → `aps.category`, `apns.go:135`). There is no APNs
  mechanism to send button text per-notification. This spec does not attempt
  to solve that; see Out of Scope.
- **Android/FCM *can* carry per-notification action data**, because the
  client fully controls rendering. But this SDK's current architecture
  doesn't build the visible `Notification` itself: Notti always sends a
  `notification` payload block, so the Android system tray auto-displays the
  push before any of this SDK's code runs
  (`NottiFirebaseMessagingService.kt:27-33`), and `onMessageReceived` (the
  only place a `data.actions` field could be parsed) is only guaranteed to
  fire in the foreground. Rendering custom
  `NotificationCompat.Action`s on a backgrounded/killed app's notification
  therefore requires switching that push to a **data-only** FCM message (no
  `notification` key) so `onMessageReceived` always invokes and this SDK
  builds the `Notification` — including its actions — itself. This is a
  real architecture change, not just new field parsing, and is called out as
  the central Design-phase decision below (see Edge Cases).

## Goals

- [ ] Android: given an incoming push carrying one or more action buttons (backend contract owned by the companion `zeep-notti` backend spec — see Out of Scope), the SDK renders up to N `NotificationCompat.Action`s on the notification it displays.
- [ ] Android: tapping an action button dispatches a tap event (action id + the push's `notification_id`/`delivery_id` when present) to native listeners/JS, without launching the host app's Activity — a distinct signal from `NottiNotificationClickRelay`'s existing default-tap detection, not a variant of it.
- [ ] Android: the notification is dismissed after an action tap (standard action-button semantics), without requiring the app process to be running.
- [ ] AD-001 is preserved: action parsing, `NotificationCompat.Builder` construction, and tap dispatch all live in Kotlin; the JS facade only gains a new optional event listener (Codegen event, matching the existing `notificationClicked` pattern), no new imperative API surface beyond that.
- [ ] iOS: no dynamic label support (architecturally impossible, see Problem Statement). The only iOS-side goal this spec claims is documenting the limitation clearly enough that the backend/dashboard side doesn't build a UI promising iOS parity it can't deliver.

## Out of Scope

| Feature | Reason |
| --- | --- |
| iOS dynamic action-button text sent per-notification | Not possible via APNs — button text is registered app-side via `UNNotificationCategory`, never sent in the payload. Out of scope for this spec and any future one; the only iOS lever is the category identifier this SDK already forwards. |
| A host-app API to register custom `UNNotificationCategory`/`UNNotificationAction` sets at SDK init | A legitimate, separate iOS feature (would let an app pre-register categories the backend can then reference by id via the existing `category` field) — but it's additive to the existing category flow, not part of making the *dashboard's* free-text action buttons work, and has no concrete request driving it yet. |
| Backend contract (the `actions`/`ActionButton` field shape, where it's serialized in the FCM payload, the dashboard's Advanced Settings UI wiring) | Owned by a companion spec in the `zeep-notti` backend repo, the same split `ctr-event-reporting` (this repo) / `ctr-tracking` (backend repo) already established. This spec only consumes whatever `data` key that companion spec defines. |
| Reporting action-button taps to the CTR/events endpoint from `ctr-event-reporting` | That spec explicitly excludes non-default-tap actions by design (`ctr-event-reporting/spec.md:50`, enforced at `NottiPushDelegate.swift:84`). Whether action-button taps should eventually feed a *different* analytics signal is a future decision, not bundled here. |
| Rich content (icons, images) on action buttons | No product requirement yet; `NotificationCompat.Action` supports an icon resource, but nothing here specifies one. |
| iOS action-button tap detection/reporting | Since iOS can't receive a per-notification button label from this SDK's payload at all, there's nothing for this SDK to detect beyond what already exists (and is already deliberately ignored, per `NottiPushDelegate.swift:84`). |

---

## User Stories

### P1: Android action buttons render and dispatch taps ⭐ MVP

**User Story**: As an app publisher, I want a push with action buttons (e.g. "Accept" / "Snooze") to show those buttons on Android and tell my app which one was tapped, so I can react to the choice without the user opening the app.

**Why P1**: This is the entire feature — without it, the dashboard's Advanced Settings fields have no client to talk to.

**Acceptance Criteria**:

1. WHEN a push arrives whose `data` includes the backend's action-buttons field (defined by the companion backend spec; assumed here to be a JSON-encoded list of `{id, label}` under a reserved `data` key) THEN the SDK SHALL parse it into up to N actions and attach them to the `NotificationCompat.Builder` used to display that notification, in the order the backend sent them.
2. WHEN the action list is malformed (invalid JSON, missing `id`, or exceeds the platform's practical action limit) THEN the SDK SHALL display the notification without actions rather than failing to display it at all, and SHALL NOT crash.
3. WHEN the user taps an action button THEN the SDK SHALL dispatch a tap signal (action `id`, plus `notification_id`/`delivery_id` when present in the original `data`) to any attached listener, via a Codegen event distinct from `notificationClicked`.
4. WHEN the user taps an action button AND no JS listener is attached yet (app not running) THEN the tap SHALL still be captured and delivered once a listener attaches later — same buffer-until-attached guarantee `NottiNotificationClickRelay`/`NottiEventBuffer` already provide for the default tap, applied to this new event instead of reusing the same one.
5. WHEN an action button is tapped THEN the notification SHALL be dismissed from the shade and the host app's Activity SHALL NOT be launched (unless a future backend field explicitly requests it — not modeled here).

**Independent Test**: Send a push carrying two actions via a test harness hitting the real (or stubbed) FCM data-only path, confirm both buttons render in the system tray, tap one, confirm the dispatched event carries the correct action id — with the app backgrounded and, separately, force-killed.

---

### P1: Android switches this push type to a data-only message ⭐ MVP

**User Story**: As the SDK, I need to actually run my own code when an action-button push arrives — including when the app is backgrounded or killed — so I can build the `Notification` myself instead of relying on the system's automatic display of a `notification`-block payload (which never calls into this SDK, and cannot carry actions).

**Why P1**: Without this, the feature only works while the app happens to be in the foreground — not the case action buttons are usually needed for (background/killed is the common case: buttons let the user act without opening the app).

**Acceptance Criteria**:

1. WHEN the backend sends a push that includes action buttons THEN it SHALL be sent as an FCM **data-only** message (no `notification` key) — a backend-side requirement this spec depends on and the companion backend spec must satisfy, since a `notification`-block push never reaches `onMessageReceived` reliably.
2. WHEN a data-only message without action buttons arrives (any other Notti push, once this change is in place for the SDK generally, or scoped to only action-button pushes — an explicit Design-phase choice) THEN the SDK SHALL build and display the notification itself (title/body from `data`, matching what the system currently renders automatically) so existing non-action-button behavior is not regressed.
3. WHEN `onMessageReceived` fires while the app is in Doze/App Standby and the OS defers delivery THEN this SHALL be treated as a known, accepted platform limitation (data-only FCM messages are subject to Doze batching same as any Android background work) — not a bug this spec's implementation must work around.

**Independent Test**: With the app force-killed and the device screen off long enough to enter Doze, send an action-button push, confirm it eventually renders with working actions once the OS delivers it (accepting OS-level delay as expected, per AC3).

---

## Edge Cases

- **Central Design-phase decision, flagged here rather than resolved**: should the data-only switch (P1 story 2) apply to *every* Notti Android push, or only to pushes that carry action buttons (with a mixed model where the backend chooses `notification` vs. data-only per-send based on whether `actions` is present)? A mixed model avoids regressing the simplicity of today's "system auto-displays" path for the common case, but means the SDK must reliably build a visually-identical notification for the data-only path too (title, body, image, sound, channel — everything `NottiFirebaseMessagingService`'s comment currently says it gets "for free"). This is not decided here; Design must pick one and document the trade-off.
- WHEN the backend/dashboard sends an action-buttons push to a target that's actually iOS (mixed segment/device-list send) THEN the iOS side SHALL simply ignore the unused `data` key — no error, matching how unrelated custom `data` is already passed through inertly today (`apns.go:108-154`).
- WHEN more actions are sent than the platform/OS practically renders (Android's status bar typically caps visible actions around 3) THEN the SDK SHALL still attach all parsed actions to the `Notification` (the OS decides how many to surface) — the SDK does not itself truncate, per Android's own contract for `NotificationCompat.Builder.addAction`.
- WHEN the same device also receives a plain (non-action) Notti push concurrently with the data-only switch in place THEN existing `notificationReceived`/`notificationClicked` behavior (foreground detection, click relay) SHALL be unaffected — this spec does not change default-tap semantics, only adds a new, separate action-tap signal.

---

## Requirement Traceability

| Requirement ID | Story | Phase | Status |
| --- | --- | --- | --- |
| SDKACT-01 | P1: Action buttons render and dispatch (parse + attach) | Design | Pending |
| SDKACT-02 | P1: Action buttons render and dispatch (malformed data is non-fatal) | Design | Pending |
| SDKACT-03 | P1: Action buttons render and dispatch (tap dispatch event) | Design | Pending |
| SDKACT-04 | P1: Action buttons render and dispatch (buffer tap until listener attaches) | Design | Pending |
| SDKACT-05 | P1: Action buttons render and dispatch (dismiss, no Activity launch) | Design | Pending |
| SDKACT-06 | P1: Data-only message switch (backend sends data-only for action pushes) | Design | Pending |
| SDKACT-07 | P1: Data-only message switch (SDK builds notification itself, no regression) | Design | Pending |
| SDKACT-08 | P1: Data-only message switch (Doze/App Standby accepted limitation) | Design | Pending |

**Coverage:** 8 total, 0 mapped to tasks, 8 unmapped ⚠️ (expected — Design/Tasks not started yet)

---

## Success Criteria

- [ ] A real Android device, backgrounded, receives an action-buttons push and shows working, correctly-labeled buttons that dispatch the right action id on tap.
- [ ] The same push, with the app force-killed instead of backgrounded, still shows working buttons once FCM delivers it (Doze-related delay accepted).
- [ ] Zero regression in existing non-action-button push display/behavior on Android after the data-only switch ships (verified against the SDK's existing test suite plus a manual check of a plain push's visual appearance).
- [ ] Zero new exports in `src/index.tsx`/`src/NativeNotti.ts` beyond the one new action-tap event listener — confirms AD-001 wasn't violated.
- [ ] iOS is unchanged by this spec (no code touched under `ios/`), confirming the deliberate platform split holds.
