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
SDK start reporting `opened` on both platforms, reusing the
`ctr-event-reporting` queue/flush/retry path unchanged. Per the product
decision below (D1, option B), the body tap reports `opened` **and** `clicked`,
and an iOS action button reports `clicked` only.

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
| Release | `zeep-notti` | `opened` ships in `v0.11.0` (migration `0023`). A backend without it (v0.10.0 or older) rejects `opened` with `422`. Backend release goes first (confirmed). |

The backend contract does not contradict D3: it accepts both types separately
and keeps the funnel monotonic (`clicked` implies `opened`). No backend change
is needed.

## Decisions

### D1: Body tap reports `opened` and `clicked` (option B, product decision 2026-10-04)

**Decision**: A tap on the notification body enqueues exactly one `opened`
and one `clicked` event for the delivery (warm and cold start). A body tap
whose custom `data` carries a URL or deep link is treated the same way.

**History**: the first revision of this spec (option A) reported the body tap
as `opened` only. The product owner switched to option B because option A
made Android CTR 0 (Android has no SDK-rendered action buttons, so no other
`clicked` source exists) and changed CTR's meaning for every app mid-rollout.

**Reason**:
- Preserves today's CTR semantics on both platforms: the body tap stays a
  click, exactly as with SDK <= 0.5.0, so CTR is comparable across SDK
  versions and does not drop during rollout.
- Starts collecting raw `opened` rows now, so the backend can distinguish a
  body tap (`opened` + `clicked`) from an action-button tap (`clicked`
  without `opened`) later without another SDK release.
- The URL case needs no special rule: the SDK has no first-class launch URL
  field and cannot tell a URL CTA from other custom data.

**Consequence under the current backend formulas** (opened = `opened` OR
`clicked`, clicked = `clicked`): every gesture this SDK reports produces a
`clicked` row, so **open rate equals CTR** for devices on this version, as it
does for older SDKs. Opened and clicked only diverge if the backend changes
its formulas (for example, CTR excluding deliveries that also have `opened`,
which would isolate action-button taps).

**Revisit when**: Android action buttons (`notification-action-buttons`) or
a first-class launch URL exist. At that point `clicked` can be narrowed to
action buttons / URL CTAs, which changes CTR's meaning and must be announced
as such.

### D2: iOS custom action button reports `clicked` only

**Decision**: On iOS, a `didReceive` response whose `actionIdentifier` is
neither `UNNotificationDefaultActionIdentifier` nor
`UNNotificationDismissActionIdentifier` (a button from a
`UNNotificationCategory` the host app registered, selected by the push's
`aps.category`) reports one `clicked` event. It does not also report `opened`.

**Reason**: Backend context D3 treats an action-button tap as a click. The
backend counts a `clicked` delivery as opened, so an `opened` row would add
nothing to the aggregates, and its absence is what tells an action-button tap
apart from a body tap (`opened` + `clicked`). The JS-facing `notificationClicked` event is **not** emitted
for action buttons (unchanged behavior, no new JS surface, AD-001).

This supersedes the event-reporting half of SDKCTR-03 ("custom action is not
reported"). The dismiss action stays unreported.

Android has no action-button support in the SDK (`notification-action-buttons`
spec is still at Design). When it ships, an action tap must report `clicked`
with the same rule.

### D3: Duplicate handling unchanged

**Decision**: No new dedup layer. One detection = one `opened` + one
`clicked` (body tap) or one `clicked` (iOS action button), using the
detection-site guards that already exist:

- Android: identity-keyed `handledIntents` (same Intent seen by
  `onActivityCreated` + `onActivityResumed` or repeated resumes is handled
  once), and the `savedInstanceState != null` / `FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`
  guards (process restore and Recents relaunch are not taps).
- iOS: `didReceive` runs once per user response.

The queue stays at-least-once (SDKCTR-14): a crash between a 2xx and the local
cleanup can resend an event. The backend metrics are `EXISTS` per delivery,
so a duplicate row never changes a rate.

### D4: JS surface unchanged

The JS event names stay `notificationReceived` / `notificationClicked` and
`getInitialNotificationClick()`. `notificationClicked` still fires for the
body tap. Only the backend event `type` changes. Renaming the JS event would
break every integrator for no analytics benefit.

## Analytics impact

- **CTR unchanged.** Body taps keep producing `clicked` on both platforms, as
  with SDK <= 0.5.0. No drop during rollout, no change in meaning.
- **Open rate.** Under the current backend formulas every reported gesture
  includes a `clicked`, so open rate equals CTR for this SDK too (body tap:
  `opened` + `clicked`; iOS action button: `clicked`, which the backend counts
  as opened). The new `opened` rows are what lets the backend tell body taps
  from action-button taps later.
- **Older SDKs (<= 0.5.0)** send only `clicked` on body tap; the backend
  already counts that delivery as opened. Raw `opened` rows exist only for
  devices on this version, so any future formula based on `opened` alone must
  account for mixed fleets.
- **Events queued before the upgrade** keep their stored type.
- **Backend compatibility**: a backend without migration `0023` (v0.10.0 or
  older) answers `422 invalid_type` to `opened`; the SDK treats it as terminal
  and drops only that event (the `clicked` of the same tap is unaffected).
  Backend `v0.11.0` ships first (confirmed).
- Not a breaking change.

## Out of Scope

| Item | Reason |
| --- | --- |
| Backend changes (formulas, `AggregateMetrics`) | Owned by `zeep-notti`; the contract above is consumed as is. |
| Android action buttons | `notification-action-buttons` spec, not implemented yet. |
| First-class launch URL / deep link | Does not exist in the backend contract (D1). |
| Any fallback on `422` for `opened` | Not needed: the body tap's `clicked` is still recorded; backend ships first. |
| New JS API or event | AD-001, D4. |

---

## User Stories

### P1: Body tap reports `opened` and `clicked` ⭐ MVP

**User Story**: As the Notti backend, I want a tap on the notification body
reported as `opened` (new) and `clicked` (as today), so `opened` data starts
being collected without changing CTR.

**Acceptance Criteria**:

1. WHEN the user taps the notification body (iOS `UNNotificationDefaultActionIdentifier`; Android launch/resume Intent carrying `google.message_id`) with the app in the foreground or background AND `data` has both `notification_id` and `delivery_id` THEN the SDK SHALL queue and report one `opened` event for that delivery.
2. WHEN the tap cold-starts the app THEN the events SHALL be queued by the same native detection site, before and independently of any JS listener or TurboModule.
3. WHEN the user taps the notification body THEN the SDK SHALL also queue one `clicked` event for the same delivery, whatever the custom `data` contains (D1).
4. WHEN one tap is seen more than once by the detection site (Android `onActivityCreated` + `onActivityResumed`, repeated resumes, process restore with saved state, relaunch from Recents) THEN at most one `opened` and one `clicked` SHALL be queued for it; a new tap (new Intent) SHALL queue a new pair (D3).

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
| SDKOPEN-03 | Body tap also reports `clicked` (option B) | Implemented | T1, T2, T4 |
| SDKOPEN-04 | At most one `opened` and one `clicked` per tap; new tap → new pair | Implemented | T1, T2, T4 |
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
- [ ] A real device tap (background and cold start) produces one `opened` and one `clicked` row in `notification_events` against a backend with migration `0023` (manual, pending a backend release).
- [ ] An iOS category action tap produces a `clicked` row (manual, needs an app with a registered category).
- [x] Zero changes in `src/` (AD-001).
