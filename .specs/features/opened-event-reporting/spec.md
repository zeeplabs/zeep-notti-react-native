# Opened Event Reporting Specification

## Problem Statement

`ctr-event-reporting` reports two event types: `received` (foreground arrival)
and `clicked` (tap on the notification body, default action). The Notti
backend overview v3 (`zeep-notti`, context D3, AD-023, migration `0023`) added
a third type, `opened`, and split the meaning of the two tap signals:

- `opened` = the user tapped the notification body (the app was opened from
  the notification).
- `clicked` = the user tapped an action button or a URL/deep-link CTA.

Today the SDK sends `clicked` for the body tap, so the backend falls back to
"opened = `opened` OR `clicked`" and open rate equals CTR. This spec makes the
SDK report the body tap as `opened` and reserve `clicked` for action-button
taps, on both platforms, reusing the `ctr-event-reporting` queue/flush/retry
path unchanged.

## Backend contract (source of truth, `zeep-notti` develop, not changed here)

Verified in the backend repo:

| Item | Location | Behavior |
| --- | --- | --- |
| Ingest | `POST /v1/apps/{app_id}/notifications/{id}/events`, `internal/api/notifications_handlers.go` `reportEvent` | Accepts `type` in `received`, `opened`, `clicked`; anything else is `422 invalid_type`. Body `{type, delivery_id, token}`, client key + token ownership proof. Inserts one row per call (no unique constraint). |
| Opened (analytics) | `internal/overview/analytics.go` `engagementColumns`, `TemplateCTRs`, `Heatmap` | A delivery with status `sent` counts as opened when `EXISTS` an `opened` **or** `clicked` event. |
| Clicked (analytics) | same | A delivery with status `sent` counts as clicked when `EXISTS` a `clicked` event. |
| Rates | AD-023 | Open rate = opened / delivered. CTR = clicked / delivered. |
| Per-notification CTR | `internal/notifications/events.go` `AggregateMetrics` | Distinct devices with a `clicked` event / delivered. Not changed by overview v3. |
| Dedup | all of the above | Every metric is an `EXISTS` per delivery, so duplicate rows of the same type for one delivery never inflate a rate. |
| Release | `zeep-notti` | `opened` is on `develop` only (after `v0.10.0`). A backend without migration `0023` rejects `opened` with `422`. |

The backend contract does not contradict D3: it accepts both types separately
and keeps the funnel monotonic (`clicked` implies `opened`). No backend change
is needed.

## Decisions

### D1: Body tap reports `opened` only, also when the payload carries a URL

**Decision**: A tap on the notification body reports exactly one `opened`
event. It never reports `clicked`, whatever the custom `data` contains
(including keys that look like a URL or deep link).

**Reason**:
- Neither the backend nor the SDK has a first-class launch URL / deep-link
  field. A URL in a Notti push is integrator-owned custom `data` that the host
  app handles itself in JS after `notificationClicked` /
  `getInitialNotificationClick()`. The SDK cannot tell a URL CTA from any other
  custom key without guessing a key name, and the SDK does not open the URL.
- D3 defines the body tap as the "opened" signal. The body tap with a URL is
  still a body tap: there is no separate element the user chose.
- Backend formulas: `opened` alone already counts the delivery as opened.
  Adding `clicked` would make CTR depend on integrator payload conventions the
  backend does not know about.

**Future rule (not implemented, recorded so a later spec does not re-decide
it)**: if the backend adds a first-class launch URL that the SDK itself opens,
a body tap on such a push should report `opened` **and** `clicked`. Under the
backend formulas `clicked` alone would produce the same aggregates (opened =
`opened` OR `clicked`), but sending both keeps the raw `opened` row count equal
to "all body taps", which is easier to audit.

### D2: iOS custom action button reports `clicked` only

**Decision**: On iOS, a `didReceive` response whose `actionIdentifier` is
neither `UNNotificationDefaultActionIdentifier` nor
`UNNotificationDismissActionIdentifier` (a button from a
`UNNotificationCategory` the host app registered, selected by the push's
`aps.category`) reports one `clicked` event. It does not also report `opened`.

**Reason**: D3 defines `clicked` as an action-button tap. The backend counts a
`clicked` delivery as opened, so a second `opened` row would add nothing to
the aggregates. The JS-facing `notificationClicked` event is **not** emitted
for action buttons (unchanged behavior, no new JS surface, AD-001).

This supersedes the event-reporting half of SDKCTR-03 ("custom action is not
reported"). The dismiss action stays unreported.

Android has no action-button support in the SDK (`notification-action-buttons`
spec is still at Design). When it ships, an action tap must report `clicked`
with the same rule.

### D3: Duplicate handling unchanged

**Decision**: No new dedup layer. One detection = one queued event, using the
detection-site guards that already exist for the body tap:

- Android: identity-keyed `handledIntents` (same Intent seen by
  `onActivityCreated` + `onActivityResumed` or repeated resumes is handled
  once), and the `savedInstanceState != null` / `FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`
  guards (process restore and Recents relaunch are not taps).
- iOS: `didReceive` runs once per user response.

The queue stays at-least-once (SDKCTR-14): a crash between a 2xx and the local
cleanup can resend the event. The backend metrics are `EXISTS` per delivery,
so a duplicate `opened` row never changes a rate.

### D4: JS surface unchanged

The JS event names stay `notificationReceived` / `notificationClicked` and
`getInitialNotificationClick()`. `notificationClicked` still fires for the
body tap. Only the backend event `type` changes. Renaming the JS event would
break every integrator for no analytics benefit.

## Analytics impact

- **SDK versions with this change**: body taps arrive as `opened`. They count
  toward open rate, not CTR. CTR only counts iOS custom action-button taps
  (D2). On Android there is no `clicked` source at all until the
  action-buttons feature ships, so Android CTR from these devices is 0.
- **Older SDK versions (<= 0.5.0)**: keep sending `clicked` for body taps.
  Those deliveries count as both opened and clicked, so for them open rate
  equals CTR, as today.
- **Mixed fleets**: CTR in the overview, the template table (and its Δ against
  the previous window) and the per-notification `AggregateMetrics` CTR drop as
  users upgrade. This is a change of meaning, not a drop in engagement. Open
  rate is not affected by the cutover (a body tap counts as opened under both
  versions).
- **Events queued before the upgrade**: an event persisted by an older SDK as
  `clicked` is flushed as `clicked` after the upgrade (the stored `type` is
  sent as is).
- **Backend compatibility**: a backend without migration `0023` (any release up
  to `v0.10.0`) answers `422 invalid_type` to `opened`. The SDK treats `422`
  as terminal and drops the event, so body taps are lost for those apps. The
  backend release that contains overview v3 must be deployed before apps ship
  this SDK version.

## Out of Scope

| Item | Reason |
| --- | --- |
| Backend changes (formulas, `AggregateMetrics`, fallback for old SDKs) | Owned by `zeep-notti`; the contract above is consumed as is. |
| Android action buttons | `notification-action-buttons` spec, not implemented yet. |
| First-class launch URL / deep link | Does not exist in the backend contract (D1). |
| A fallback that resends `opened` as `clicked` on `422` | Would hide a backend version mismatch and mix semantics; documented as a deploy-order requirement instead. |
| New JS API or event | AD-001, D4. |

---

## User Stories

### P1: Body tap reports `opened` ⭐ MVP

**User Story**: As the Notti backend, I want a tap on the notification body
reported as `opened`, so open rate and CTR measure different things.

**Acceptance Criteria**:

1. WHEN the user taps the notification body (iOS `UNNotificationDefaultActionIdentifier`; Android launch/resume Intent carrying `google.message_id`) with the app in the foreground or background AND `data` has both `notification_id` and `delivery_id` THEN the SDK SHALL queue and report one event with `type: "opened"`.
2. WHEN the tap cold-starts the app THEN the `opened` event SHALL be queued by the same native detection site, before and independently of any JS listener or TurboModule.
3. WHEN the user taps the notification body THEN the SDK SHALL NOT report `clicked` for that tap, whatever the custom `data` contains (D1).
4. WHEN one tap is seen more than once by the detection site (Android `onActivityCreated` + `onActivityResumed`, repeated resumes, process restore with saved state, relaunch from Recents) THEN at most one `opened` SHALL be queued for it; a new tap (new Intent) SHALL queue a new one (D3).

### P1: Action-button tap reports `clicked` (iOS) ⭐ MVP

**Acceptance Criteria**:

1. WHEN `didReceive` delivers a custom action identifier (not default, not dismiss) for a remote push whose `data` has both ids THEN the SDK SHALL queue one `clicked` event and no `opened` event (D2).
2. WHEN the action is `UNNotificationDismissActionIdentifier` THEN the SDK SHALL NOT queue any event.
3. WHEN a custom action is tapped THEN the JS `notificationClicked` event SHALL NOT be emitted (unchanged).

### P1: Unchanged rules apply to `opened`

**Acceptance Criteria**:

1. WHEN `data` lacks `notification_id` or `delivery_id`, or (iOS) the notification is not a remote push THEN no `opened`/`clicked` event SHALL be queued.
2. WHEN an `opened` event is flushed THEN it SHALL go through the existing write-ahead queue, retry policy and flush triggers of `ctr-event-reporting` with request body `type: "opened"`.
3. WHEN the user taps the notification body THEN `notificationClicked` / `getInitialNotificationClick()` SHALL still deliver the payload to JS (D4).

### P2: Documentation

**Acceptance Criteria**:

1. README "Notification event (CTR) reporting" SHALL describe `received`, `opened`, `clicked` with the new meaning.
2. CHANGELOG `[Unreleased]` SHALL flag the reclassification, the analytics impact and the backend requirement under "Breaking / attention when upgrading".

---

## Requirement Traceability

| Requirement ID | Story | Status | Tasks |
| --- | --- | --- | --- |
| SDKOPEN-01 | Body tap (foreground/background) → `opened` | Implemented | T1 (Android), T2 (iOS) |
| SDKOPEN-02 | Body tap cold start → `opened` | Implemented | T1, T2 |
| SDKOPEN-03 | Body tap never reports `clicked` | Implemented | T1, T2 |
| SDKOPEN-04 | At most one `opened` per tap; new tap → new event | Implemented | T1, T2 |
| SDKOPEN-05 | iOS custom action → `clicked` only | Implemented | T2 |
| SDKOPEN-06 | iOS dismiss → no event | Implemented | T2 |
| SDKOPEN-07 | iOS custom action → no JS event | Implemented | T2 |
| SDKOPEN-08 | Skip without ids / non-remote push | Implemented | T1, T2 |
| SDKOPEN-09 | `opened` uses the existing queue/retry/flush, body `type: "opened"` | Implemented | T1, T2 |
| SDKOPEN-10 | JS events unchanged for body tap | Implemented | T1, T2 (no `src/` change) |
| SDKOPEN-11 | README + CHANGELOG | Implemented | T3 |

**Coverage:** 11 total, 11 mapped to tasks, 0 unmapped.

## Success Criteria

- [x] Unit tests on both platforms cover SDKOPEN-01..10.
- [ ] A real device tap (background and cold start) produces an `opened` row in `notification_events` against a backend with migration `0023` (manual, pending a backend release).
- [ ] An iOS category action tap produces a `clicked` row (manual, needs an app with a registered category).
- [x] Zero changes in `src/` (AD-001).
