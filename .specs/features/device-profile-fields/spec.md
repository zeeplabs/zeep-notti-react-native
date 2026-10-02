# Device Profile Fields Specification

## Problem Statement

`zeep-notti-react-native` aims for OneSignal-equivalent reliability, but today it captures only a fraction of the device/user profile that OneSignal subscriptions carry. A Notti `Device` row today holds `token`, `platform`, `external_user_id`, `tags`, `subscribed`, plus the segment-telemetry fields shipped by `segment-telemetry-reporting` (`app_version`, session fields, opt-in `country`). Missing entirely, compared to OneSignal's subscription/user model (`documentation.onesignal.com/docs/en/user-subscription-properties`): `device_os` (OS version), `device_model`, `sdk` (SDK version), a detailed permission/subscription status (granted vs. denied vs. never-asked vs. provisional), `last_unsubscribed`/`last_active`-style timestamps, first-class `email` and `phone` (OneSignal `User.addEmail`/`User.addSms`), `timezone_id`, and `language` (ISO 639-1).

The consequences of the gap: the backend has no data to segment on OS version, model, language, timezone, permission state or opt-out recency; the dashboard can't show "devices that denied permission" or "devices that unsubscribed in the last 30 days"; and integrators migrating from OneSignal have no `email`/`phone` address on the device record, forcing them to smuggle these into `tags` (collision-prone, not first-class, not segmentable as native fields).

This spec defines the SDK-side producer half: what the SDK captures automatically (natively, per `AD-001`) and what it lets the integrator set explicitly, and how each field reaches the backend. A backend companion spec (new `devices` columns + PATCH acceptance + segment allowlist) is required before Design, same split as `segment-telemetry-reporting` ↔ `device-telemetry-fields`.

## Goals

- [ ] `device_os` (OS version), `device_model`, and `sdk_version` are captured automatically at native init and sent on device registration and on change — zero integrator code, per `AD-001`.
- [ ] `timezone_id` (IANA identifier) and `language` (ISO 639-1) are captured automatically at native init from the OS — zero integrator code, matching OneSignal's auto-detection.
- [ ] A detailed `permission_status` (the OS's actual push-permission state: granted / denied / notDetermined / provisional on iOS) is captured natively and kept in sync — including when the user changes it in OS settings outside the app (detected at next session start).
- [ ] `last_unsubscribed_at` is recorded natively whenever the subscription transitions to unsubscribed (either app-driven via `setSubscription(false)` or permission-driven via granted → denied), and synced to the backend.
- [ ] First-class `email` and `phone` fields on the device, settable from JS (`User.setEmail`/`User.clearEmail`, `User.setPhone`/`User.clearPhone`) and cleared explicitly — not stored in `tags`.
- [ ] Everything rides the existing device registration/PATCH mutation-queue path — no new transport mechanism.

## Out of Scope

| Feature | Reason |
| --- | --- |
| Backend contract itself (new `devices` columns, PATCH schema, segment field allowlisting) | Owned by a future backend companion spec in `zeep-notti`, filed once this SDK spec is reviewed — same split used for `segment-telemetry-reporting`/`device-telemetry-fields`. |
| Validation of `email`/`phone` format in the SDK | The SDK is the trusted producer of user-supplied values (mirrors how `tags` values are never format-validated). Whether the backend rejects malformed values is that spec's call, not the SDK's. |
| Sending email/phone as OneSignal-style separate *subscription channels* (own tokens, per-channel status) | OneSignal models email/SMS as separate Subscriptions each with their own status and last-session. Notti's model is one Device per install; email/phone here are first-class *attributes* of that Device for targeting/debugging, not independent delivery channels. Delivering to email/SMS is a different, much larger feature. |
| `last_active` (last app interaction) | `last_session_at` already exists from `segment-telemetry-reporting` and covers OneSignal's `last_active` intent. |
| A JS setter for `language` (`User.setLanguage` in OneSignal) | Confirmed scope decision: language is auto-detected only. An explicit override is a future additive change if a real need appears. |
| A JS setter/getter for timezone | Auto-detected only; OneSignal's own `timezone_id` is SDK-detected. |
| Backfilling `device_os`/`device_model`/`sdk_version`/`permission_status`/`last_unsubscribed_at`/`email`/`phone`/`timezone_id`/`language` for already-registered devices | Existing rows get `NULL` until their next natural sync; no migration fabricates history that was never captured. |
| `permission_status`/`last_unsubscribed_at` as queryable segment fields | Out of this SDK spec's scope entirely; segment allowlist decisions belong to the backend companion spec. |

---

## Assumptions & Open Questions

| Assumption / decision | Chosen default | Rationale | Confirmed? |
| --- | --- | --- | --- |
| `permission_status` value set | String enum: `granted`, `denied`, `notDetermined`, plus `provisional` (iOS only) | Mirrors the OS-level truth (Android `NotificationManagerCompat.areNotificationsEnabled()` + `POST_NOTIFICATIONS` check on 13+; iOS `UNUserNotificationCenter` `authorizationStatus`). Distinct from `subscribed`, which remains the app-controlled bool set by `setSubscription` — the same two-axis split OneSignal has (`enabled` bool + `notification_types`). | y (Julio, brainstorming) |
| `sdk_version` source | Read from the SDK package version at the JS layer and passed to native `initialize` (the package's own `exports` already surfaces `./package.json`, so the version is readable at runtime) | A natively hardcoded SDK version is a duplicate-constant drift risk across every release; the package version is the single source of truth. Passing a constant at init is not business logic, so `AD-001`'s native-only rule is preserved. `app_version` stays natively read, as today. | y (Julio, brainstorming) |
| `email`/`phone` as first-class fields, not tags | New `email`/`phone` columns on the Device + dedicated JS methods, with explicit clear semantics | Confirmed over "reserved tags": first-class fields are segmentable as native conditions, don't pollute the tag namespace, and match OneSignal. | y (Julio, brainstorming) |
| Timezone/language auto-detection | Native capture at init; no JS setter | Confirmed over JS setters; matches OneSignal and minimizes integrator code (`AD-001`). | y (Julio, brainstorming) |
| `last_unsubscribed_at` semantics | Set only on a true→false / granted→denied transition; **not** cleared on re-subscribe (records history) | A timestamp of the *most recent* unsubscribe is the useful signal for "opted out recently" segments; clearing it on re-subscribe would lose the recency signal and add a write. Re-subscribe just stops the timestamp from updating further. | y (Julio, brainstorming) |
| `permission_status` sync trigger | Registration, `requestPermission` result, and a re-check at each session start (catches changes made in OS settings while the app wasn't running) | Reuses the existing session-start hook from `segment-telemetry-reporting` — no new timer, catches the real-world "user disabled in Settings" case that app-driven `subscribed` alone can't. | y (follows from confirmed two-axis model) |
| Change detection | Diff-and-enqueue per field, same pattern as `app_version`/tags today — only a changed value becomes a pending mutation | Avoids a PATCH storm and keeps the "synced value" cache authoritative. | y (existing pattern) |

---

## User Stories

### P1: OS version, device model and SDK version captured automatically ⭐ MVP

**User Story**: As a backend/admin, I want to know each device's OS version, model, and the Notti SDK version it runs, so I can segment by platform maturity and debug delivery issues per device class — matching OneSignal's `device_os`/`device_model`/`sdk` subscription fields.

**Why P1**: The simplest of the automatic fields — static values read once at init, no lifecycle machinery, directly extends the existing `app_version` capture path.

**Acceptance Criteria**:

1. WHEN the native SDK initializes THEN it SHALL read and hold in `NottiCore`'s device state: `device_os` (Android `Build.VERSION.RELEASE`, iOS `UIDevice.current.systemVersion`), `device_model` (Android `Build.MODEL`, iOS `utsname.machine`), and `sdk_version` (the package version passed to native `initialize` from JS).
2. WHEN a device registration occurs THEN the current `device_os`/`device_model`/`sdk_version` SHALL be included in that request's payload.
3. IF any of these values differs from the value last successfully synced for this device THEN the SDK SHALL treat it as a pending mutation (same "diff and enqueue" pattern as `app_version`) so it syncs on the next flush without requiring app restart-triggered registration.
4. IF the native OS/device read fails (unexpected platform API absence) THEN the SDK SHALL omit the affected field from the payload rather than crash or block registration.
5. `app_version` capture is unchanged by this story — it already ships via `segment-telemetry-reporting` and remains a sibling field, not a re-implementation.

**Independent Test**: Mock the OS/device readers to return fixed values; assert a fresh device registration's payload includes `device_os`/`device_model`/`sdk_version`; mutate one value between two flushes and assert only the changed field is re-sent as a diffed mutation, not the whole set.

---

### P2: Timezone and language captured automatically

**User Story**: As a backend/admin, I want each device's IANA timezone and OS language, so I can schedule by local time and localize messaging — matching OneSignal's `timezone_id` and `language` fields.

**Why P2**: Still automatic, zero lifecycle machinery; sequenced after P1 because it shares the exact same "read once at init, diff and enqueue" path.

**Acceptance Criteria**:

1. WHEN the native SDK initializes THEN it SHALL read and hold `timezone_id` (IANA identifier: Android `TimeZone.getDefault().id`, iOS `TimeZone.current.identifier`) and `language` (ISO 639-1: Android `Locale.getDefault().language`, iOS `Locale.current.languageCode`).
2. WHEN a device registration occurs THEN both values SHALL be included in the registration payload.
3. IF `timezone_id` or `language` changes between flushes (device locale/timezone change, user switch) THEN the SDK SHALL diff-and-enqueue the changed field, same pattern as P1/`app_version`.
4. IF the locale/timezone read fails THEN the SDK SHALL omit the affected field rather than crash or block registration.

**Independent Test**: Mock locale/timezone readers; assert registration payload carries both; change the mocked timezone between two flushes and assert only `timezone_id` is re-sent.

---

### P3: Detailed permission status and last-unsubscribe timestamp ⭐ MVP

**User Story**: As a backend/admin, I want to distinguish "never asked", "denied", and "unsubscribed, and when", so I can re-engage lapsed permission and measure opt-out rate — the OneSignal `notification_types`/`last_unsubscribed` gap that a single `subscribed` bool cannot express.

**Why P3**: The most valuable non-obvious addition — `subscribed: true` today silently covers both "granted and receiving" and "granted but user turned off in Settings", which are different targeting situations.

**Acceptance Criteria**:

1. WHEN the native SDK initializes or a session starts THEN it SHALL read the OS push-permission state and hold it as `permission_status` (`granted`, `denied`, `notDetermined`; `provisional` where the OS reports it — iOS provisional auth only).
2. WHEN a device registration occurs THEN the current `permission_status` SHALL be included in the registration payload.
3. WHEN `requestPermission` resolves THEN the SDK SHALL update `permission_status` from the OS state (not from the bool it already maps to `subscribed`) and sync it.
4. WHEN the user changes push permission in OS settings outside the app THEN the SDK SHALL detect the change at the next session start and diff-and-enqueue the new `permission_status`.
5. WHEN the subscription transitions to unsubscribed — `setSubscription(false)` (app-driven) OR `permission_status` granted → denied (permission-driven) — THEN the SDK SHALL record `last_unsubscribed_at` (RFC 3339 UTC) locally and enqueue it as a pending mutation.
6. A re-subscribe (granted again, or `setSubscription(true)`) SHALL update `permission_status`/`subscribed` but SHALL NOT clear `last_unsubscribed_at`.
7. `permission_status` and `subscribed` SHALL remain independent fields: `subscribed=false` (app opt-out) does not change the OS `permission_status`, and OS `denied` does not force `subscribed` to change — each reflects its own axis.

**Independent Test**: Simulate granted → user disables in Settings → next session start; assert a PATCH carrying the new `permission_status` and a `last_unsubscribed_at` timestamp. Simulate `setSubscription(false)`; assert `last_unsubscribed_at` is set but `permission_status` stays `granted`. Simulate re-subscribe; assert `last_unsubscribed_at` is not cleared.

---

### P4: First-class email and phone via JS API

**User Story**: As an app, I want to attach the user's email and phone number to their device as first-class fields — the way I send tags today — so backend/dashboard can search and target by them, without polluting the tag namespace.

**Why P4**: The only story that adds a JS-visible API; `AD-001`'s native-only default applies to *capture*, but email/phone are integrator-supplied user data (like `login`'s `externalUserId`), so a JS entry point is the correct surface — not an exception to `AD-001`, but its established pattern for user-supplied identity.

**Acceptance Criteria**:

1. `User.setEmail(email: string)` SHALL enqueue `email` as a pending mutation and update the cached device state.
2. `User.clearEmail()` SHALL enqueue an explicit clear (same "present key, null value" contract the backend's `country` opt-out established) so a previously-synced email is removed server-side, not merely left stale.
3. `User.setPhone(phone: string)` and `User.clearPhone()` SHALL behave identically for `phone`.
4. When a device registration occurs, any locally-held `email`/`phone` SHALL be included in the registration payload.
5. Calling `setEmail`/`setPhone` with the value already synced SHALL NOT enqueue a mutation (no-op, matching `addTag` idempotence).
6. `email`/`phone` SHALL travel as their own PATCH fields, never merged into `tags`.

**Independent Test**: Call `setEmail`, assert a PATCH carries `email` and no `tags` change; call `clearEmail`, assert a PATCH clearing the field; call `setEmail` twice with the same value, assert only one mutation is enqueued; assert registration payload includes a locally-held value.

---

## Edge Cases

- IF the backend companion spec ships after this SDK spec THEN the new payload fields SHALL be sent but silently ignored server-side (no `422`) until the backend accepts them — additive payload growth must not break existing device registration/PATCH calls, same rule as `segment-telemetry-reporting`.
- IF the integrator never calls `User.setEmail`/`User.setPhone` THEN behavior SHALL be indistinguishable from a build that never implemented P4 — zero payload/behavior change.
- IF an existing integrator already stores email/phone as tags THEN their tag data is untouched (this spec adds fields, does not migrate or collide with tags).
- IF the user grants permission, then the app calls `setSubscription(false)` and later `setSubscription(true)`, THEN `permission_status` stays `granted` throughout (app opt-out doesn't touch OS state) and `last_unsubscribed_at` records only the first transition (per AC6, not cleared).
- IF the OS reports an unknown/transitional authorization state (neither granted, denied, nor notDetermined) THEN the SDK SHALL omit `permission_status` from the payload rather than send a fabricated value.
- IF `sdk_version` cannot be resolved at runtime (package metadata unreadable in a bundler edge case) THEN the SDK SHALL omit `sdk_version` and continue — it is diagnostic metadata, not required for registration.
- IF the same session-start check also runs `segment-telemetry-reporting`'s country/permission-gated read THEN the two checks SHALL coexist without conflict — both are reads at the same hook, no shared mutable state introduced by this spec.

---

## Requirement Traceability

| Requirement ID | Story | Phase | Status |
| --- | --- | --- | --- |
| DPF-01 | P1: OS/device/SDK version (native capture at init) | Implemented | Implemented |
| DPF-02 | P1: OS/device/SDK version (registration payload) | Implemented | Implemented |
| DPF-03 | P1: OS/device/SDK version (diff-and-enqueue on change) | Implemented | Implemented |
| DPF-04 | P1: OS/device/SDK version (read failure is non-fatal) | Implemented | Implemented |
| DPF-05 | P1: OS/device/SDK version (app_version unchanged) | Implemented | Implemented |
| DPF-06 | P2: Timezone/language (native capture at init) | Implemented | Implemented |
| DPF-07 | P2: Timezone/language (registration payload) | Implemented | Implemented |
| DPF-08 | P2: Timezone/language (diff-and-enqueue on change) | Implemented | Implemented |
| DPF-09 | P2: Timezone/language (read failure is non-fatal) | Implemented | Implemented |
| DPF-10 | P3: Permission status (native read at init/session-start) | Implemented | Implemented |
| DPF-11 | P3: Permission status (registration payload) | Implemented | Implemented |
| DPF-12 | P3: Permission status (requestPermission result sync) | Implemented | Implemented |
| DPF-13 | P3: Permission status (OS-settings change detected at session start) | Implemented | Implemented |
| DPF-14 | P3: last_unsubscribed_at (set on true→false / granted→denied) | Implemented | Implemented |
| DPF-15 | P3: last_unsubscribed_at (not cleared on re-subscribe) | Implemented | Implemented |
| DPF-16 | P3: Two-axis independence (subscribed vs permission_status) | Implemented | Implemented |
| DPF-17 | P4: Email/phone (JS set + enqueue) | Implemented | Implemented |
| DPF-18 | P4: Email/phone (explicit clear) | Implemented | Implemented |
| DPF-19 | P4: Email/phone (registration payload) | Implemented | Implemented |
| DPF-20 | P4: Email/phone (no-op on unchanged value) | Implemented | Implemented |
| DPF-21 | P4: Email/phone (never merged into tags) | Implemented | Implemented |

**ID format:** `DPF-NN`

**Status values:** Pending -> In Design -> In Tasks -> Implemented -> Verified

**Coverage:** 21 total, 21 mapped to tasks, 0 unmapped

---

## Success Criteria

- [ ] `device_os`, `device_model`, `sdk_version`, `timezone_id` and `language` are captured natively on both platforms, included in registration payloads, and diffed-and-enqueued on change — with no new JS API surface for any of them (`AD-001` preserved).
- [ ] `permission_status` reflects the real OS permission state on both platforms — including a change made in OS settings and detected at the next session start — independent of the app-controlled `subscribed` bool.
- [ ] `last_unsubscribed_at` is recorded on both unsubscription paths (app-driven and permission-driven), survives process death (persisted in `NottiDeviceStore`/`NottiDeviceStore.swift`), and is not cleared on re-subscribe.
- [ ] `User.setEmail`/`User.clearEmail`/`User.setPhone`/`User.clearPhone` enqueue proper set/clear mutations and never touch `tags`.
- [ ] No crash or registration-blocking failure mode exists if any native read fails.
- [ ] Backend companion spec filed and reviewed before Design work starts on this spec.