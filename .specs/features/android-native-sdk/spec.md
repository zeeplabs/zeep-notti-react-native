# Android on the Native SDK Specification

## Problem Statement

`react-native-notti` 0.8.0 carries its own Android implementation: the Kotlin core under
`android/src/main/java/com/notti/` (API client, core, stores, FCM service, process-start provider, In-App engine
and views) plus its JUnit/Robolectric suite. The same logic now ships as the native Android SDK
`br.com.zeeplabs:notti-android` 0.1.0 (`zeep-notti-android-sdk`, published on Maven Central 2026-11-04), which
was ported from this repo at `v0.8.0` (`291d5a7`) and kept behavior-identical (its AD-002). Two copies mean
every Android fix is written, tested and reviewed twice, and they already differ: the native SDK fixed three
lifecycle bugs (its AD-019: permission dialog only in the foreground, guarded tap detection, its own
permission Activity) and the flaky-test fake (PR #14 there, #45 here).

The native SDK's ROADMAP M2 (`rn-consumes-native-sdk`) decides the fix: this library depends on the Maven
artifact and deletes its Kotlin core, as `ios-native-sdk` (AD-005) does for iOS on `NottiSDK`. The JS API stays
the same. Android and iOS ship together in 0.9.0 (Julio, 2026-11-04).

## Goals

- [ ] The Android side holds no business logic: no HTTP, retry, queue, store, FCM service, provider or In-App
      code under `android/`, only the Turbo Module adapter from the Codegen spec to the native public API and a
      deprecated `NottiBridge` shim.
- [ ] Every JS behavior a 0.8.0 integrator relies on is unchanged on Android (same events, payloads,
      initial-click semantics, In-App click listener, `sdk_version` = RN package version).
- [ ] An app upgraded from 0.8.0 keeps its device id, tags and pending queues (no duplicate device row).
- [ ] The integrator migration (manifest overrides, own FCM service) is documented in `README.md` and the 0.9.0
      upgrade notes.

## Out of Scope

| Feature | Reason |
| --- | --- |
| iOS | `ios-native-sdk` (AD-005) |
| New SDK behavior or JS API additions | Pure migration. Behavior changes go through the native SDK first. |
| Native SDK changes beyond `wrapper-support` 0.2.0 | Native repo; this feature consumes 0.2.0 |
| Changing JS event names or payload shapes | Public contract |
| Expo config plugin Android changes | Only if a manifest change needs it; Design confirms (expected none) |

---

## User Stories

### P1: The Turbo Module delegates to the native SDK ⭐ MVP

**User Story**: As a maintainer, I want the Android Turbo Module to call `br.com.zeeplabs:notti-android`
instead of an in-repo core, so that a fix in the native SDK reaches React Native apps without a manual port.

**Why P1**: The point of the migration (native ROADMAP M2).

**Acceptance Criteria**:

1. WHEN the library builds THEN `android/build.gradle` SHALL declare `api "br.com.zeeplabs:notti-android:0.2.0"`
   (exact version, pinned) from `mavenCentral()` and SHALL NOT compile any Kotlin file that implements networking, persistence, retry,
   queues, FCM handling, the process-start provider or In-App presentation.
2. WHEN JS calls any method of `NativeNotti.ts` (`initialize`, `requestPermission`, `login`, `logout`, `addTags`,
   `removeTags`, `setSubscription`, `setLocationSharingEnabled`, `setEmail`, `clearEmail`, `setPhone`,
   `clearPhone`, `getDeviceId`, `trackEvent`, `getInitialNotificationClick`) THEN the module SHALL forward it to
   the matching native API (`Notti`, `Notti.User`, `Notti.Notifications`) with the same arguments and return its
   result.
3. WHEN JS calls `initialize(appId, clientKey, baseUrl, sdkVersion)` THEN the module SHALL use the native
   wrapper entry point (`@NottiWrapperApi`, native `wrapper-support`) so the backend receives
   `sdk_version` = the RN package version and `sdk_name: "react-native"`.
4. WHEN JS calls `initialize` THEN the module SHALL keep AD-004 (the SDK never opens a link):
   `NottiOptions(opensInAppUrls = false)`.
5. WHEN the native SDK reports a received push, a clicked push, a device id change or an In-App click THEN the
   module SHALL emit `onNotificationReceived`, `onNotificationClicked`, `onDeviceIdChanged` or
   `onInAppMessageClicked` with the 0.8.0 payload shape (`NotificationPayload` with `null` for a missing
   title/body; `InAppClickPayload` with the 0.8.0 action type strings and `action: null` for
   `push_permission`).
6. WHEN the RN instance reloads or the module is invalidated THEN the module SHALL remove every native
   subscription it added (`NottiSubscription.remove()`), and a new module instance SHALL receive each event
   once.
7. WHEN a push tap cold-starts the app THEN `getInitialNotificationClick()` SHALL resolve that payload once
   (`Notti.Notifications.takeInitialClick()`), as in 0.8.0.

**Independent Test**: build the example app, run every button of the example screen on a device, and see the
same JS events and backend requests as with 0.8.0.

---

### P1: Upgrading from 0.8.0 keeps the device ⭐ MVP

**User Story**: As an integrator upgrading from 0.8.0, I want the same install to keep its device, tags and
pending events, so that the upgrade does not create a second device or lose CTR/In-App events.

**Acceptance Criteria**:

1. WHEN an app that registered with 0.8.0 launches with 0.9.0 THEN the native SDK SHALL read the same
   `notti_prefs` file, reuse the stored device id and SHALL NOT create a new device row.
2. WHEN events were queued by 0.8.0 (push events, `notti_pending_inapp_events`, pending `external_user_id`
   clear) THEN 0.9.0 SHALL flush them.
3. WHEN 0.8.0 left a persisted key the native SDK does not read THEN the design SHALL list it and its handling
   (key audit; native AD-003 says file and keys are RN's, the audit proves it).

**Independent Test**: install 0.8.0 on a device, register, add tags, upgrade in place to 0.9.0: one device row,
same `getDeviceId()`, tags intact.

---

### P1: Integrator setup on 0.9.0 ⭐ MVP

**User Story**: As an integrator, I want my 0.8.0 Android setup to keep working, or to know exactly what to
change, so that push and In-App keep working after the upgrade.

**Acceptance Criteria**:

1. WHEN an integrator's app has its own `FirebaseMessagingService` calling `com.notti.NottiBridge.onMessageReceived`
   / `onNewToken` THEN it SHALL still compile and work: `com.notti.NottiBridge` stays as a `@Deprecated` shim
   with the same signatures that forwards to `com.zeeplabs.notti.NottiBridge` (Julio, 2026-11-04).
2. WHEN an integrator's manifest removes the 0.8.0 service or provider by class name
   (`com.notti.NottiFirebaseMessagingService`, `com.notti.NottiInitProvider`) THEN the README and upgrade notes
   SHALL give the new names (`com.zeeplabs.notti.NottiFirebaseMessagingService`,
   `com.zeeplabs.notti.NottiInitProvider`), because the old removal no longer matches and the native service
   would be merged next to the app's own.
3. WHEN the integrator uses Expo prebuild THEN the config plugin SHALL produce a project that builds and
   registers a device without manual native edits beyond what the README lists.
4. WHEN the change ships THEN `CHANGELOG.md` SHALL hold Android upgrade notes for every integrator-visible
   change, including the native behavior differences listed under Edge Cases, in the same 0.9.0 release as iOS.

**Independent Test**: fresh RN app and the example with a custom FCM service follow only the README and reach a
registered device and a delivered push.

---

### P1: Host build floors ⭐ MVP

**User Story**: As an integrator, I want the new dependency not to force upgrades my RN version cannot take.

**Acceptance Criteria**:

1. WHEN the host builds with the floors the native SDK declares (Kotlin 2.0 stdlib, `compileSdk` 34,
   `minSdk` 24, `firebase-messaging` as `api`) THEN the RN versions this library supports SHALL meet them; the
   README requirements SHALL state any raised floor.
2. WHEN the host resolves dependencies THEN there SHALL be one `firebase-messaging` on the classpath (no
   version conflict error) and no `com.notti` core classes next to `com.zeeplabs.notti`.

---

### P2: Tests at the right layer

**Acceptance Criteria**:

1. WHEN the Kotlin core is removed THEN its tests SHALL be removed, and the remaining JUnit suite SHALL cover the
   adapter: argument mapping, payload mapping to the Codegen types, listener lifecycle across invalidate,
   initial click, wrapper identity and the link rule.
2. WHEN CI runs THEN the definition of done (`pnpm typecheck && pnpm lint && pnpm test &&
   pnpm run build:android && pnpm run build:ios`) and the Android unit tests SHALL pass.

---

## Edge Cases

Native behavior that differs from 0.8.0 and goes into the upgrade notes (not reverted here):

- Identity calls before `initialize` are dropped with a `WARN` line (native AD-008) only in hosts that removed
  `NottiInitProvider` (no native runtime until the first `initialize`; `getDeviceId` is `null` then). With the
  provider in place the behavior is the same as 0.8.0 (Design, "Behavior differences" 1).
- The permission dialog is shown only while the app is in the foreground; otherwise `requestPermission`
  resolves `false` without marking it as asked (native AD-019, PRR-07).
- Permission dialog runs in the SDK's own `NottiPermissionActivity`, not the host Activity (native PRR-06).
- Malformed tap Intents no longer crash the host (native PRR-10).
- Provider authority changes from `${applicationId}.nottiinitprovider` to
  `${applicationId}.com.zeeplabs.notti.initprovider`.
- The deprecated `com.notti.NottiBridge.onMessageReceived` now also queues the CTR `received` event (0.8.0's
  bridge only emitted the JS event); upgrade note.

Other cases:

- WHEN JS calls `initialize` twice with the same config THEN nothing SHALL change; with a different config
  THEN the SDK SHALL rebuild (native AD-008 idempotence).
- WHEN `addTags` receives an empty map or `removeTags` an empty list THEN behavior SHALL match 0.8.0.
- WHEN the host also integrates the native SDK directly THEN the README SHALL say not to (one engine per app).

---

## Requirement Traceability

| Requirement ID | Story | Phase | Status |
| --- | --- | --- | --- |
| ANSDK-01 | Delegates: Gradle dependency, no core Kotlin | Tasks | Pending (T1, T6, T7) |
| ANSDK-02 | Delegates: method forwarding | Tasks | Pending (T2, T3) |
| ANSDK-03 | Delegates: `sdk_version`/`sdk_name` via wrapper hook | Tasks | Pending (T2, T3) |
| ANSDK-04 | Delegates: no link opening (AD-004) | Tasks | Pending (T3) |
| ANSDK-05 | Delegates: event emission, payload shape | Tasks | Pending (T4, T11) |
| ANSDK-06 | Delegates: subscriptions removed on invalidate | Tasks | Pending (T4, T6, T11) |
| ANSDK-07 | Delegates: initial click once | Tasks | Pending (T4, T11) |
| ANSDK-08 | Upgrade keeps device id | Tasks | Pending (T11) |
| ANSDK-09 | Upgrade flushes 0.8.0 queues | Tasks | Pending (T11) |
| ANSDK-10 | Upgrade key audit | Tasks | Pending (Design analysis, T11) |
| ANSDK-11 | Setup: deprecated `com.notti.NottiBridge` shim | Tasks | Pending (T5, T11) |
| ANSDK-12 | Setup: new class names for manifest removals | Tasks | Pending (T9, T11) |
| ANSDK-13 | Setup: Expo plugin | Tasks | Pending (T8) |
| ANSDK-14 | Setup: upgrade notes in 0.9.0 | Tasks | Pending (T9) |
| ANSDK-15 | Floors: Kotlin/compileSdk/minSdk | Tasks | Pending (T1, T9) |
| ANSDK-16 | Floors: one firebase-messaging, no duplicate core | Tasks | Pending (T1, T7) |
| ANSDK-17 | Adapter-level tests, old suites removed | Tasks | Pending (T2, T3, T4, T5, T6) |
| ANSDK-18 | Gates green | Tasks | Pending (T7, T10) |

**Coverage:** 18 total, 18 mapped to tasks, 0 unmapped.

## Dependencies

- Native `zeep-notti-android-sdk` `wrapper-support` released as 0.2.0 (ANSDK-03).
- `ios-native-sdk` for the shared 0.9.0 release and CHANGELOG.

## Success Criteria

- [ ] `android/src/main` holds only adapter files (`NottiModule`, `NottiPackage`, the `NottiBridge` shim and the
      `NottiNativeApi` seam); tests cover only the adapter.
- [ ] 0.8.0-to-0.9.0 upgrade on a device: one device row, same `getDeviceId()`.
- [ ] Example app: push, tap cold start, In-App click and permission on a device, same JS events as 0.8.0.
