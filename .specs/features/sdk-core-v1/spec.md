# SDK Core v1 Specification

## Problem Statement

Notti (self-hosted/SaaS push infra, `zeep-notti`) has a `Client key` auth scheme designed for device-facing use (`POST`/`PATCH /v1/apps/{app_id}/devices`), but no official mobile SDK exists yet — every integrator would have to hand-roll FCM/APNS token handling and hit the REST API directly. This mirrors the gap OneSignal's own `react-native-onesignal` SDK closes for their platform. `zeep-notti-react-native` is the first official client SDK; v1 delivers the OneSignal-equivalent core: init, device registration, external user id, tags, subscription state, and notification-received/clicked listeners.

## Goals

- [ ] A React Native app can register a device with Notti and receive FCM (Android) / APNS (iOS) pushes with only `Notti.initialize(appId, clientKey, baseUrl)` + native project setup (`google-services.json` / APNs capability), no custom native code.
- [ ] SDK surface API shape mirrors `react-native-onesignal`'s v5 public API closely enough that an integrator already familiar with OneSignal's SDK recognizes the pattern (`initialize`, `Notifications.requestPermission`, `User.addTag(s)`/`removeTag(s)`, `User.addAlias`/external id, `login`/subscription).
- [ ] Ships as a Turbo Module (New Architecture) with an Expo config plugin, working in both bare RN and Expo (dev client/prebuild).

## Out of Scope

| Feature | Reason |
| --- | --- |
| In-App Messages | Deferred — mirrors admin-webui's own P2/P3 deferral of the same feature; no backend support to consume yet either. |
| Live Activities | Deferred — same reason as In-App Messages. |
| Public-API hardening (rate limiting, key scoping, OpenAPI, docs portal) | Explicitly deferred to a separate future feature (`public-api-hardening`) in `zeep-notti`, once this SDK proves the contract works in practice. |
| Backend changes to Notti itself | This feature is SDK-only; any backend gap found gets its own `zeep-notti` feature (as already happened with `device-patch-attributes-completion`). |
| Android/iOS notification UI customization (custom sounds, rich media, notification channels beyond the default) | v1 delivers the default OS notification; customization is a follow-up once core registration/delivery is proven. |
| Deep-link / URL routing on notification click | v1's `notificationClicked` listener exposes the raw payload only; app-side routing is the integrator's responsibility in v1. |
| Delivery-receipt confirmation back to Notti (SDK-side) | Notti already tracks delivery status server-side (FCM/APNS provider callbacks); no SDK-initiated confirmation call exists in the backend contract to invoke. |

---

## Assumptions & Open Questions

| Assumption / decision | Chosen default | Rationale | Confirmed? |
| --- | --- | --- | --- |
| Auth model | SDK calls Notti directly from the device using the public Client key (no backend round-trip through the host app's own server) | Matches Notti' existing Client-key design intent (device register/update only, safe to embed) and OneSignal's own client-side model | y |
| API host | Notti is self-hosted-or-SaaS per deployment (not a fixed single host) — `Notti.initialize` takes an explicit `baseUrl` parameter naming the integrator's own Notti instance (e.g. `https://push.example.com` for self-hosted, or Zeep's SaaS host); no hardcoded default host ships in the SDK | An SDK that hardcodes one host cannot serve self-hosted Notti deployments, which the backend explicitly supports | y |
| Token acquisition | SDK obtains the FCM/APNS token itself natively (Firebase Messaging on Android, native APNS on iOS) rather than delegating to a pre-existing push lib in the host app | Locked in prior architecture brainstorm (see repo dev log) — gives rich push/badge/notification-action parity with OneSignal's real SDK from v1 | y |
| Permission request timing | Explicit `Notti.requestPermission()` call, separate from `initialize()` | User decision — mirrors OneSignal's real SDK, gives host app control over prompt timing; device still registers on init with `subscribed: false` until permission is granted | y |
| Tag merge semantics | SDK keeps a local in-memory cache of the device's last-known tags (seeded from the register/update response) and computes the full resulting map before every `PATCH`, since the backend only supports wholesale tag replacement | User decision — preserves OneSignal-equivalent granular `addTag`/`addTags`/`removeTag`/`removeTags` API despite the backend's replace-only contract | y |
| Concurrent tag mutation race | Last-write-wins; calls are serialized client-side (one in-flight PATCH at a time, later calls queue) but no cross-device/cross-session conflict resolution | Follows from the tag-merge decision above; acceptable for v1, revisit only if it proves to be a real-world problem | y |
| Registration retry policy | Exponential backoff, capped at 5 attempts, then stop until the next app foreground or the next token-refresh event | User decision — bounded to avoid battery/network drain from unbounded retry | y |
| Token rotation (FCM/APNS token refresh) | SDK re-registers via the same upsert path (`POST .../devices`) — the backend's `(app_id, token, platform)` unique upsert naturally creates a new Device row when the token changes; the SDK does not attempt to delete/merge the prior row | Backend contract already documented in `zeep-notti`'s `design.md`; changing that behavior is out of scope for an SDK-only feature | y |
| `login` / external user id API shape | `Notti.login(externalUserId: string)` and `Notti.logout()` (clears it), backed by `PATCH .../devices/{id}` with `external_user_id` | Mirrors OneSignal's `login`/`logout` naming over a more generic `setExternalUserId`, closer to the "recognizable to OneSignal users" goal | n — flagged for confirmation at Design if the exact method name matters to Julio; functionally equivalent either way |
| Init before native config (missing `google-services.json` / APNS capability) | SDK logs a clear, non-fatal error and no-ops registration (never crashes app boot) | Crash-safety is a hard requirement for any SDK embedded in a third-party app's boot path | y |
| Missing/invalid `appId`/`clientKey`/`baseUrl` at `initialize()` | Non-fatal: log an error, `initialize()` resolves/returns without throwing, no registration attempt is made | Same crash-safety rationale — an SDK must never be able to crash the host app from a config mistake | y |
| iOS native language | Scaffolded as Kotlin+Objective-C via `create-react-native-library` (no Turbo Module + Swift template exists in the tool as of v0.63.0); iOS side will be converted from Obj-C to Swift as an early implementation task, before any push logic is written | User decision this session — New Architecture Turbo Modules fully support Swift, the scaffolding tool just has no preset for that exact combination | y |

**Open questions:** none blocking — the `login`/`logout` naming is a low-risk naming choice, not a behavioral gap; proceed with it and easy to rename at Design/Tasks if flagged.

---

## User Stories

### P1: SDK initialization and automatic device registration ⭐ MVP

**User Story**: As a React Native app developer integrating Notti, I want to call one `initialize` function so that my app's device is registered with Notti and ready to receive push, without hand-rolling FCM/APNS/REST-API glue code.

**Why P1**: Without this, nothing else in the SDK has a device to act on — it's the foundation every other story depends on.

**Acceptance Criteria**:

1. WHEN the host app calls `Notti.initialize(appId, clientKey, baseUrl)` for the first time THEN the SDK SHALL obtain the current FCM token (Android) or APNS device token (iOS) and call `POST {baseUrl}/v1/apps/{appId}/devices` with `{token, platform}` using `Authorization: Bearer {clientKey}`.
2. WHEN the device-registration call succeeds THEN the SDK SHALL persist the returned device id and cache the returned `tags` map locally for later merge operations (see SDK Core v1's tag-merge assumption).
3. IF `appId`, `clientKey`, or `baseUrl` is missing or empty THEN the SDK SHALL log an error and SHALL NOT throw or crash the host app, and SHALL NOT attempt registration.
4. IF the native push prerequisite is missing (no `google-services.json` resolvable on Android, no push capability/entitlement on iOS) THEN the SDK SHALL log a clear, actionable error and SHALL NOT crash the host app.
5. IF the registration HTTP call fails (network error or 5xx) THEN the SDK SHALL retry with exponential backoff up to 5 attempts, then stop until the next app foreground or the next FCM/APNS token-refresh event.
6. WHEN the OS delivers a refreshed FCM or APNS token (independent of app restart) THEN the SDK SHALL re-register via the same `POST` upsert call with the new token.
7. WHEN `Notti.initialize` is called more than once in the same app session THEN the SDK SHALL treat subsequent calls as a no-op (no duplicate registration call) if `appId`/`clientKey` are unchanged from the first call.

**Independent Test**: Fresh app install, call `initialize` with a valid App's Client key, confirm a new row appears in Notti' Devices admin screen with the correct platform and a `subscribed: false` state (permission not yet requested).

---

### P2: Explicit permission request

**User Story**: As a React Native app developer, I want to control exactly when the OS push-permission prompt appears, so that I can show it after onboarding context rather than immediately on launch.

**Why P2**: Core registration (P1) works and is useful (tags/segmentation) even before permission is granted; permission only gates actual push delivery.

**Acceptance Criteria**:

1. WHEN the host app calls `Notti.requestPermission()` THEN the SDK SHALL trigger the native OS permission prompt (`POST_NOTIFICATIONS` runtime permission on Android 13+, `UNUserNotificationCenter` authorization request on iOS).
2. WHEN the user grants permission THEN the SDK SHALL call `PATCH /v1/apps/{appId}/devices/{id}` with `{subscribed: true, token}`.
3. WHEN the user denies permission THEN the SDK SHALL call `PATCH .../devices/{id}` with `{subscribed: false, token}` (device stays registered and segmentable, just not delivery-eligible).
4. WHILE running on an Android version below 13 (no runtime permission needed) `Notti.requestPermission()` SHALL resolve immediately as granted without prompting.

**Independent Test**: Call `requestPermission()`, grant it, confirm the device's `subscribed` field flips to `true` in Notti; deny it in a separate run, confirm it stays/flips to `false`.

---

### P3: Tags, external user id, subscription control, and notification listeners

**User Story**: As a React Native app developer, I want to tag devices, associate them with my own user id, control subscription state, and react to incoming/clicked notifications in-app, so that I can target sends via Notti Segments and build in-app notification handling.

**Why P3**: Useful for real production use (segmentation, per-user targeting) but the app already works end-to-end (receives push) without it — P1+P2 are the deliverable MVP slice.

**Acceptance Criteria**:

1. WHEN the host app calls `Notti.User.addTag(key, value)` or `addTags({...})` THEN the SDK SHALL merge the new key(s) into its locally cached tag map and `PATCH .../devices/{id}` with the full resulting `tags` map.
2. WHEN the host app calls `Notti.User.removeTag(key)` or `removeTags([...])` THEN the SDK SHALL remove the key(s) from its locally cached tag map and `PATCH .../devices/{id}` with the full resulting `tags` map.
3. WHEN the host app calls `Notti.login(externalUserId)` THEN the SDK SHALL `PATCH .../devices/{id}` with `{external_user_id: externalUserId, token}`.
4. WHEN the host app calls `Notti.logout()` THEN the SDK SHALL clear the locally held external user id association for future reads; (the backend does not support clearing `external_user_id` server-side per `zeep-notti`'s documented contract, so the value is not cleared server-side — see Edge Cases).
5. WHEN the host app calls `Notti.setSubscription(enabled)` THEN the SDK SHALL `PATCH .../devices/{id}` with `{subscribed: enabled, token}`.
6. WHEN a push notification arrives while the app is in the foreground THEN the SDK SHALL emit a `notificationReceived` event with the raw notification payload.
7. WHEN the user taps a notification (foreground, background, or from a killed state via cold start) THEN the SDK SHALL emit a `notificationClicked` event with the raw notification payload.
8. IF any tag/external-id/subscription `PATCH` call is in flight WHEN another such call is requested THEN the SDK SHALL queue the new call and send it only after the in-flight one resolves (serialized, last-write-wins on the merged local state).

**Independent Test**: Call `addTags({plan: 'vip'})` then `removeTag('plan')` back-to-back; confirm the device's final persisted `tags` in Notti reflects the net result (no `plan` key), not an intermediate or reverted state.

---

## Edge Cases

- IF `Notti.logout()` is called THEN the system SHALL surface (via docs/code comment, not a runtime warning) that `external_user_id` remains set server-side, since clearing it is outside Notti' current backend contract — never silently claim success is doing more than it does.
- IF the app is killed and relaunched before a queued tag/subscription `PATCH` from story P3-AC8 is sent THEN the SDK SHALL drop the queued call (in-memory queue only, no persistence across process death, v1 scope) rather than attempt it on next launch with stale state.
- IF `requestPermission()` is called before `initialize()` THEN the SDK SHALL log an error and SHALL NOT crash; permission is not requested until `initialize()` has run at least once.
- WHEN the same `(appId, clientKey)` pair is used across multiple installs of the same App THEN each install SHALL still register as its own Device row (the Client key is shared per-App by design, not per-Device — matches Notti' AD-009).

---

## Requirement Traceability

| Requirement ID | Story | Phase | Status |
| --- | --- | --- | --- |
| SDK-01 | P1: Init & auto-register | Execute | ✅ Verified |
| SDK-02 | P1: Init & auto-register | Execute | ✅ Verified |
| SDK-03 | P1: Init & auto-register | Execute | ✅ Verified |
| SDK-04 | P1: Init & auto-register | Execute | ❌ Needs Fix (real missing-native-prerequisite path untested on both platforms) |
| SDK-05 | P1: Init & auto-register | Execute | ✅ Verified |
| SDK-06 | P1: Init & auto-register | Execute | ✅ Verified (declared scope: orchestration layer only, real OS token-refresh hooks untested) |
| SDK-07 | P1: Init & auto-register | Execute | ✅ Verified |
| SDK-08 | P2: Explicit permission | Execute | ⚠️ Spec-precision gap (declared scope: orchestration proven, real OS prompt call untested on both platforms) |
| SDK-09 | P2: Explicit permission | Execute | ✅ Verified |
| SDK-10 | P2: Explicit permission | Execute | ✅ Verified |
| SDK-11 | P2: Explicit permission | Execute | ✅ Verified |
| SDK-12 | P3: Tags/id/subscription/listeners | Execute | ⚠️ Spec-precision gap (iOS: indirect evidence only) |
| SDK-13 | P3: Tags/id/subscription/listeners | Execute | ⚠️ Spec-precision gap (iOS: indirect evidence only) |
| SDK-14 | P3: Tags/id/subscription/listeners | Execute | ✅ Verified |
| SDK-15 | P3: Tags/id/subscription/listeners | Execute | ✅ Verified |
| SDK-16 | P3: Tags/id/subscription/listeners | Execute | ✅ Verified |
| SDK-17 | P3: Tags/id/subscription/listeners | Execute | ⚠️ Spec-precision gap (declared scope: parsing proven, emission wiring untested on both platforms) |
| SDK-18 | P3: Tags/id/subscription/listeners | Execute | ✅ Verified |
| SDK-19 | P3: Tags/id/subscription/listeners | Execute | ✅ Verified |

**Coverage:** 19 total, 19 mapped to tasks. 14 Verified, 4 spec-precision gaps (SDK-08/12/13/17, declared-scope orchestration/parsing-only coverage per the Verifier's report), 1 Needs Fix (SDK-04, the real missing-native-prerequisite path). Per `.specs/features/sdk-core-v1/validation.md` (fix batch, verification round 1): SDK-11/14/15/16/18 moved from Needs Fix to Verified after native-layer test coverage landed.

---

## Success Criteria

- [ ] A bare RN app and an Expo (dev client) app can both integrate the SDK with the same public API and successfully register a device end-to-end against a running Notti instance.
- [ ] `initialize()` never throws/crashes regardless of misconfiguration (missing keys, missing native push setup) — verified by an explicit negative test per Edge Case.
- [ ] Tag add/remove sequences converge to the correct net `tags` map server-side even under back-to-back rapid calls (P3-AC8's serialization holds).
