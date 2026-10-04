# Segment Telemetry Reporting Specification

## Problem Statement

The companion backend spec `segments-onesignal-parity` (in `zeep-notti`) closes most of the gap between our segment model and OneSignal's, but explicitly punts on the fields OneSignal segments support that we structurally cannot fill yet: `app_version`, `last_session`/`first_session`, `session_count`, `session_time`, `location`/`country`. Those aren't backend query gaps — the data simply doesn't exist. `devices` today only carries what registration sends (`token`, `platform`, `external_user_id`, `tags`, `subscribed`); nothing about app build version, session activity, or geography is captured anywhere in the SDK (`android/NottiCore.kt`, `ios/NottiCore.swift` own device registration/mutation state, per prior session's exploration; there is no session-lifecycle hook, no version field, no location capture, in either).

This spec defines what the SDK needs to capture and report so a future backend change can expose these as real, non-fabricated segment fields — mirroring how `ctr-tracking`/`ctr-event-reporting` split a backend contract from its SDK-side producer. This spec is the SDK-side half; a backend companion spec (new `devices` columns + PATCH acceptance) is required before Design and is explicitly out of scope of this document.

## Goals

- [ ] App version is captured automatically at native init and sent on every device registration and on any subsequent app update (no integrator code, per `AD-001`).
- [ ] A lightweight session lifecycle is tracked natively (foreground start → background/terminate end) to compute `first_session_at`, `last_session_at`, a running `session_count`, and cumulative `session_time`.
- [ ] Session/version state is synced to the backend via the existing device PATCH mutation-queue path (`NottiCore`'s mutation queue on both platforms) — no new transport mechanism, batched with other pending device mutations rather than firing a request per session.
- [ ] Location (lat/long → reverse-resolved `country`, or `country` alone) is captured **only** when the host app has already been granted OS location permission and the integrator has explicitly opted in via a new SDK toggle — never requested by the SDK itself.
- [ ] Outside the location opt-in toggle (P3), nothing here changes the public JS API surface (`AD-001` preserved for P1/P2) — this is native-only bookkeeping, same pattern as CTR event reporting.

## Out of Scope

| Feature | Reason |
| --- | --- |
| Backend contract itself (new `devices` columns, PATCH schema, segment field allowlisting) | Owned by a future backend companion spec in `zeep-notti`, filed once this SDK spec is reviewed — same split used for `ctr-tracking`/`ctr-event-reporting`. |
| The SDK requesting location permission itself (`CLLocationManager`/`requestPermission`) | Permission UX (rationale copy, timing, Info.plist `NSLocationWhenInUseUsageDescription` / Android `ACCESS_COARSE_LOCATION` manifest entry) belongs to the host app, same boundary the SDK already respects for notification permission. The SDK only reads location if the host app already has it granted for its own purposes. |
| Background/continuous location tracking | Only a single best-effort read at report time (app foreground/session-sync), never a location `watch`/background updates. Matches OneSignal's own point-in-time model, not a live-tracking feature. |
| Precise/raw GPS coordinates leaving the device | The SDK resolves to `country` (and optionally coarse lat/long already truncated to city-level precision) before sending — no fine-grained coordinate stored server-side, minimizing what a segment filter can leak. Exact precision level is a Design-phase decision (see Assumptions). |
| Real-time session state (a "currently active" flag) | OneSignal's own fields are all point-in-time/aggregate (`last_session`, `session_count`), not live presence; matching that is enough, a live-presence feature is unrequested speculative scope. |
| Session precision beyond app foreground/background | No sub-screen or per-feature session tracking — one session = one foreground-to-background/terminate cycle, matching OneSignal's own granularity. |
| Backfilling `first_session_at`/`app_version`/`location` for devices already registered before this ships | Existing rows simply have `NULL`/unknown until their next natural sync; no migration script re-derives history that was never captured. |
| Sending session data on every single foreground/background transition immediately | Batched into the existing mutation-queue flush cadence to avoid a request storm on app-switching-heavy usage; see P2 below. |

---

## Assumptions & Open Questions

| Assumption / decision | Chosen default | Rationale | Confirmed? |
| --- | --- | --- | --- |
| Location opt-in shape | New JS method `ZeepNotti.setLocationSharingEnabled(enabled: boolean)`, defaulting `false`; persisted locally so it survives restarts until the integrator calls it again | Location is the one field here where "automatic, zero integrator code" (`AD-001`'s norm for P1/P2) is inappropriate — a location-collecting SDK opting itself in silently would be a real privacy problem. An explicit, JS-visible, default-off toggle is the minimum honest surface. | n (Julio should confirm the API name/shape before Design — this is a deliberate, scoped exception to `AD-001`, not an accidental one) |
| Precision sent to backend | Reverse-geocoded `country` (ISO 3166-1 alpha-2) only, no raw lat/long persisted server-side | Matches OneSignal's `country` field exactly, and avoids the SDK becoming a precise-location-storage pipe when the only confirmed use case is country-level segmentation | n (Julio should confirm — could instead mirror OneSignal's separate `location` lat/long+radius filter if city-level targeting is actually wanted) |
| Read cadence | One best-effort read per session start (P2), only if opted in and permission already granted; no forced read at SDK init | Ties it to an existing lifecycle hook instead of a new timer; avoids draining battery with a dedicated location poll | n (mechanical, follows from reusing the session hook) |
| Missing/denied permission behavior | Silently omit the field from the payload, never prompt, never error | Consistent with "the SDK never owns permission UX" | y (same principle as the rest of this spec's failure-mode handling) |

---

---

## User Stories

### P1: App version captured and reported

**User Story**: As a backend/admin, I want to segment by app version, so I can target users still on an old build (e.g. for a forced-update campaign).

**Why P1**: Lowest-effort of the two — a static value read once per launch, no lifecycle machinery needed; unblocks the simplest OneSignal-parity field first.

**Acceptance Criteria**:

1. WHEN the native SDK initializes THEN it SHALL read the host app's version string (`CFBundleShortVersionString` on iOS, `versionName` from `PackageInfo` on Android) once and hold it in `NottiCore`'s device state.
2. WHEN a device registration or the next mutation-queue flush occurs THEN the current app version SHALL be included in that request's payload.
3. IF the app version differs from the value last successfully synced for this device THEN the SDK SHALL treat it as a pending mutation (same "diff and enqueue" pattern already used for tag/external-user-id changes) so it syncs on the next flush without requiring app restart-triggered registration.
4. The version value SHALL be sent as an opaque string, with no client-side semver parsing or comparison (that logic, if needed, belongs to the segment `gt`/`lt` query layer on the backend, not the SDK).

**Independent Test**: Mock the native version reader to return `"1.2.3"`; assert a fresh device registration's payload includes it; bump the mocked value between two flushes and assert the second flush's payload includes the new value as a diffed mutation, not the old one.

---

### P2: Session lifecycle tracked and reported

**User Story**: As a backend/admin, I want to segment by recency and frequency of app usage (`last_session`, `session_count`), so I can re-engage lapsed users or reward frequent ones.

**Why P2**: Meaningfully more native lifecycle work than P1 (foreground/background hooks on both platforms) — sequenced after the simpler, self-contained version change.

**Acceptance Criteria**:

1. WHEN the host app transitions to the foreground (first launch or resume from background) THEN the SDK SHALL start a session: record the start timestamp locally, and if no prior session exists, set `first_session_at` to this timestamp.
2. WHEN the host app transitions to the background or is terminated THEN the SDK SHALL end the current session: increment a locally-held `session_count`, add the elapsed foreground duration to a locally-held cumulative `session_time`, and set `last_session_at` to the session's end timestamp.
3. WHEN the mutation-queue next flushes THEN it SHALL include the current `first_session_at`/`last_session_at`/`session_count`/`session_time` values as part of the device payload, same batching cadence as other pending mutations (not a dedicated per-session request).
4. IF the app is killed without a clean background transition (e.g. force-quit, crash) THEN the session SHALL still be considered ended no later than the next app launch's session-start handling, using the last known foreground timestamp to estimate the missed session's contribution to `session_time` — an app that's cleanly quit is not silently under-counted forever.
5. Locally-accumulated session state SHALL persist across process death (same on-disk store already used for the CTR event queue's durability guarantee) so it survives being killed before the next flush.

**Independent Test**: Simulate foreground → 30s → background; assert `session_count` increments by 1 and `session_time` increases by ~30s; simulate two sessions across a process kill in between and assert both counted correctly after relaunch; assert a flush payload includes all four fields together.

---

### P3: Opt-in location/country reporting

**User Story**: As a backend/admin, I want to segment by country, so I can run region-specific campaigns — matching OneSignal's `country`/`location` fields.

**Why P3**: Highest privacy/consent surface of the three stories, and the only one that deliberately adds a JS-visible API (an explicit exception to `AD-001`) — sequenced last, after the automatic, zero-consent fields.

**Acceptance Criteria**:

1. Location reporting SHALL default to disabled for every device; it SHALL only activate after the integrator explicitly calls the opt-in toggle from JS.
2. WHEN location sharing is enabled AND the host app already holds OS location permission (SDK checks, never requests) THEN the SDK SHALL perform a best-effort location read at the next session start (P2's hook) and resolve it to a `country` (ISO 3166-1 alpha-2) value.
3. IF location sharing is disabled, OR the host app has not been granted OS location permission, THEN the SDK SHALL omit the location/country field entirely from every payload — never send a stale, empty, or placeholder value.
4. WHEN the integrator calls the opt-in toggle to `false` after previously enabling it THEN the SDK SHALL stop reading location on the next session and SHALL enqueue a mutation clearing any previously-synced location/country value for that device.
5. The location read SHALL never trigger an OS permission prompt, and a read failure (permission revoked mid-session, location services disabled, no fix available) SHALL be treated the same as "no permission": payload field omitted, no error surfaced to the integrator.
6. The opt-in state SHALL persist locally across app restarts (an integrator who calls it once at app setup should not need to call it on every launch).

**Independent Test**: With opt-in `false`, assert no location field ever appears in a payload even with mocked permission granted; with opt-in `true` and mocked permission granted, assert a session-start payload includes `country`; toggle opt-in to `false` and assert the next payload clears the field via an explicit mutation, not by omission alone; mock a permission revocation mid-session and assert no crash, no field sent.

---

## Edge Cases

- IF the native version reader fails (unexpected platform API absence) THEN the SDK SHALL omit the version field from the payload rather than crash or block registration.
- IF the device has never completed a session (killed before backgrounding even once) THEN `first_session_at`/`last_session_at` MAY be absent from the very first payload — the backend companion spec must treat these as nullable, not required.
- IF the mutation queue is flushing session data and a new session starts mid-flush THEN the new session SHALL not be double-counted or lost — the in-flight flush uses a snapshot taken before the new session began.
- WHEN the host app is a widget/extension/background-fetch context with no real foreground UI (iOS) THEN the SDK SHALL NOT count that invocation as a session (avoids inflating `session_count` from non-interactive wake-ups).
- IF this SDK spec ships before its backend companion spec THEN the extra payload fields SHALL be sent but silently ignored server-side (no `422`) until the backend accepts them — additive payload growth must not break existing device PATCH/registration calls.
- IF the integrator never calls the location opt-in toggle THEN behavior SHALL be indistinguishable from a build of the SDK that never implemented P3 at all — zero payload/behavior change for every existing integrator.
- IF OS location permission is granted but returns a stale/cached fix (common right after app launch) THEN the SDK SHALL still use it rather than blocking the session-start hook waiting for a fresh fix — staleness is acceptable for country-level granularity.

---

## Requirement Traceability

| Requirement ID | Story | Phase | Status |
| --- | --- | --- | --- |
| SEGTEL-01 | P1: App version | Implemented | Implemented |
| SEGTEL-02 | P1: App version | Implemented | Implemented |
| SEGTEL-03 | P1: App version | Implemented | Implemented |
| SEGTEL-04 | P1: App version | Implemented | Implemented |
| SEGTEL-05 | P2: Session lifecycle | Implemented | Implemented |
| SEGTEL-06 | P2: Session lifecycle | Implemented | Implemented |
| SEGTEL-07 | P2: Session lifecycle (snapshot PATCH per session end; telemetry coalescing before registration) | Implemented (pre-release review, working tree) | Coalescing implemented on both platforms (queue-limit semantics differ, see below) |
| SEGTEL-08 | P2: Session lifecycle (unclean kill closed at last heartbeat) | Implemented (pre-release review, working tree) | Heartbeat implemented on both platforms |
| SEGTEL-09 | P2: Session lifecycle | Implemented | Implemented |
| SEGTEL-10 | P3: Location/country | Implemented | Implemented |
| SEGTEL-11 | P3: Location/country | Implemented | Implemented |
| SEGTEL-12 | P3: Location/country | Implemented | Implemented |
| SEGTEL-13 | P3: Location/country (opt-out clear persisted via `pendingCountryClear` until 2xx) | Implemented (pre-release review, working tree) | `pendingCountryClear` implemented on both platforms |
| SEGTEL-14 | P3: Location/country | Implemented | Implemented |
| SEGTEL-15 | P3: Location/country | Implemented | Implemented |

**ID format:** `SEGTEL-NN`

**Status values:** Pending -> In Design -> In Tasks -> Implemented -> Verified

**Coverage:** 15 total, 15 mapped to tasks, 0 unmapped — all Implemented (T1-T10, commits `981bb92`→`60389ee`; SEGTEL-07/08/13 revisions in the working tree), pending independent Verifier.

**Rule changes from pre-release review (v0.3.0..HEAD)** — implemented on both platforms with unit tests (`NottiCoreTest.kt`, `NottiCoreTests.swift`); at the time of this edit the code is in the working tree, not yet committed, and gates were not re-run by this docs pass:

- **SEGTEL-08 (heartbeat):** while a session is open and the app is in the foreground, a last-foreground timestamp is persisted every 60s (Android `NottiForegroundObserver` main-looper ticker between `onStart`/`onStop`, key `notti_last_foreground_at_ms`; iOS `DispatchSourceTimer` on the work queue that only writes while `appIsForeground`, key `notti_session_last_seen_at_ms`). An orphaned session (force-quit/crash) is closed at that timestamp on next launch instead of `now`, which counted dead time as foreground. Credited duration capped at 12h on Android (`MAX_ORPHAN_SESSION_MS`) and 24h on iOS (`maxOrphanSessionMs`); with no heartbeat beyond the session start it is credited 0s. Both platforms have a process-wide session gate (Android `NottiModule.processSessionGate`; iOS `NottiImpl.processSessionGate`, an `NSLock`-protected `NottiCore.SessionGate`, closed on `didEnterBackground`) so an RN reload or duplicate foreground signal does not open a second session. On a JS reload in the foreground, the new core adopts the persisted open session (iOS `adoptOpenSessionOnQueue`: no orphan close, `session_count` unchanged, only the heartbeat is resumed). iOS `NottiCore.invalidate()` (from `NottiImpl.invalidate`) removes the old core's observers and stops its heartbeat, leaving the persisted session and the gate for the new core. A country clear rejected with a permanent 4xx (401/403/404) logs a distinct message without personal data on both platforms; it stays pending and is re-sent by trigger.
- **SEGTEL-13 (`pendingCountryClear`):** opt-out sets a persisted `notti_pending_country_clear` flag, cleared only on a 2xx for the `{country: null}` PATCH, and re-sent on registration success, app foreground and network regain (covers opt-out before `initialize`, offline, 5xx, process death). Any failure, including a permanent 4xx, keeps it pending, so a permanently rejected clear is re-sent on every trigger. `notti_last_synced_country` tracks the last acknowledged value. Armed only when a country may exist server-side (sharing was on, a country was synced, or a clear is already owed).
- **SEGTEL-07 (sync cadence and coalescing):** each session end produces a cumulative snapshot PATCH. Once the device is registered it is sent immediately (one PATCH per move to background; iOS wraps it in a background task) — AC3's "same batching cadence, not a dedicated per-session request" holds only before registration. Before registration, telemetry mutations (session, country, app version) carry a coalesce key and a newer one replaces the queued one. The 32-entry pending-mutation limit differs per platform:
  - **Android** (`NottiCore.runOrQueue`): telemetry does not count toward the limit and is never evicted (at most one entry per key; country set and country clear share the `country` key). At 32 user mutations, the oldest user mutation is dropped.
  - **iOS** (`NottiCore.performOrQueue`): telemetry counts toward the limit. When full, the first queued telemetry entry is evicted; if only user mutations are queued, a new telemetry mutation is dropped and a new user mutation evicts the oldest user mutation. The iOS country clear does not go through this queue (`attemptPendingCountryClear` runs only when the device is addressable; otherwise the persisted flag waits for registration).
- **Backend dependency (open):** until the backend accepts the fields (DEVTEL-01..13 pending in `zeep-notti`), `app_version`, session fields and `country` are ignored with HTTP 200, and the SDK marks `app_version`/`country` as synced (not re-sent until changed). Resolved for `app_version` on 2026-10-04 (`segtel-app-version-ack`): the SDK now marks it synced only when the `PATCH /devices` response echoes the sent value, otherwise re-sends it on the next registration. `country` is unchanged.

---

## Success Criteria

- [ ] App version is captured natively on both platforms and included in registration/mutation payloads, diffed on change.
- [ ] Session start/end is tracked natively on both platforms, surviving process death, producing `first_session_at`/`last_session_at`/`session_count`/`session_time` synced via the existing mutation-queue flush.
- [ ] Location/country is opt-in only (new `setLocationSharingEnabled` toggle, default off), never requests OS permission itself, and cleanly clears server-side state when disabled.
- [ ] No new JS-visible API added for P1/P2 (`AD-001` preserved there); P3's opt-in toggle is the one deliberate, documented exception. No crash/registration-blocking failure mode if native version/session/location reads fail.
- [ ] Backend companion spec filed and reviewed before Design work starts on this spec.
