# iOS on the Native SDK Specification

## Problem Statement

`react-native-notti` 0.8.0 carries its own iOS implementation: about 6,900 lines of Swift in `ios/*.swift`
(API client, core, stores, push delegate, In-App engine and views) plus about 13,000 lines of XCTest in
`ios/Tests/`. The same logic now ships as the native iOS SDK `NottiSDK` 0.1.0 (`zeep-notti-ios-sdk`,
published 2026-10-26 on SPM and the CocoaPods trunk), which was ported from this repo at `v0.8.0`
(`291d5a7`) and kept behavior-identical (its AD-017/AD-018). Two copies of the same iOS logic mean every
fix and feature is written, tested and reviewed twice, and they have already started to diverge (the
iOS SDK's AD-020 opens In-App `url` actions; this repo's AD-004 never does).

The iOS SDK's AD-001 and its roadmap milestone M2 decide the fix: `react-native-notti` depends on the
`NottiSDK` pod and deletes its own Swift core, the same model as `react-native-onesignal` on
`OneSignal-iOS-SDK`. This spec covers that migration on iOS. The JS API stays the same.

## Goals

- [ ] The iOS side of `react-native-notti` holds no business logic: no HTTP, retry, queue, store or
      In-App code under `ios/`, only an adapter from the Codegen spec to the `NottiSDK` public API.
- [ ] Every JS behavior a 0.8.0 integrator relies on is unchanged on iOS (same events, payloads,
      initial-click semantics, In-App click listener, `sdk_version` reported as the RN package version).
- [ ] An app upgraded from 0.8.0 keeps its device id and pending queues (no duplicate device row).
- [ ] The integrator migration (Podfile, `AppDelegate`, NSE) is documented in `README.md` and in the
      upgrade notes, with the Expo config plugin doing the Expo part.

## Out of Scope

| Feature | Reason |
| --- | --- |
| Android on `zeep-notti-android-sdk` | That SDK is not on Maven Central yet (its B-001). Separate feature once it ships. |
| New SDK behavior or JS API additions | Pure migration. Behavior changes go through the iOS SDK first. |
| iOS SDK M3 items (LGPD wipe, Keychain, App Group, resilient queue) | Arrive later through a `NottiSDK` version bump. |
| Changing JS event names or payload shapes | Public contract; no reason to touch it here. |
| SPM as the RN install path | RN autolinking runs on CocoaPods; `spm_dependency` is still experimental (see Open Questions). |

---

## User Stories

### P1: The Turbo Module delegates to `NottiSDK` ⭐ MVP

**User Story**: As a maintainer, I want the iOS Turbo Module to call `NottiSDK` instead of an in-repo
core, so that a fix in the iOS SDK reaches React Native apps without being ported by hand.

**Why P1**: This is the whole point of the migration (iOS SDK AD-001, M2).

**Acceptance Criteria**:

1. WHEN the library is installed through CocoaPods THEN `Notti.podspec` SHALL declare a dependency on the
   `NottiSDK` pod and SHALL NOT compile any Swift file that implements networking, persistence, retry,
   queues or In-App presentation.
2. WHEN JS calls any method of `NativeNotti.ts` (`initialize`, `requestPermission`, `login`, `logout`,
   `addTags`, `removeTags`, `setSubscription`, `setLocationSharingEnabled`, `setEmail`, `clearEmail`,
   `setPhone`, `clearPhone`, `getDeviceId`, `trackEvent`, `getInitialNotificationClick`) THEN the module
   SHALL forward it to the matching `NottiSDK` API with the same arguments and return the SDK's result.
3. WHEN JS calls `initialize(appId, clientKey, baseUrl, sdkVersion)` THEN the backend SHALL receive
   `sdk_version` equal to the RN package version passed from JS, not the native SDK version, and
   `sdk_name: "react-native"`, not `ios` (backend `zeep-notti` AD-044, NottiSDK AD-024; added 2026-10-31).
4. WHEN JS calls `initialize` THEN the module SHALL keep this repo's AD-004 link rule: the SDK SHALL NOT
   open an In-App `url` or `deeplink` action (`opensInAppURLs` off).
5. WHEN the SDK reports a received push, a clicked push, a device id change or an In-App click THEN the
   module SHALL emit `onNotificationReceived`, `onNotificationClicked`, `onDeviceIdChanged` or
   `onInAppMessageClicked` with the same payload shape as 0.8.0 (`NotificationPayload`,
   `InAppClickPayload`).
6. WHEN the RN instance reloads or is invalidated THEN the module SHALL remove every SDK listener it
   registered, and a new module instance SHALL receive events without duplicates.
7. WHEN a push tap cold-starts the app THEN `getInitialNotificationClick()` SHALL resolve that payload
   once, as in 0.8.0.

**Independent Test**: Build the example app with the new podspec, run every button of the example
screen on a simulator and a device, and see the same JS events and backend requests as with 0.8.0.

---

### P1: Upgrading from 0.8.0 keeps the device ⭐ MVP

**User Story**: As an integrator upgrading from 0.8.0, I want the same install to keep its device and
pending events, so that the upgrade does not create a second device or lose CTR/In-App events.

**Why P1**: A duplicate device breaks targeting and metrics for every existing app.

**Acceptance Criteria**:

1. WHEN an app that registered with 0.8.0 launches with the new version THEN the SDK SHALL reuse the
   stored device id (UserDefaults suite `notti_prefs`) and SHALL NOT create a new device row.
2. WHEN events were queued by 0.8.0 (CTR queue, `notti_pending_inapp_events`, pending
   `external_user_id` clear) THEN the new version SHALL flush them.
3. WHEN 0.8.0 left a persisted key that `NottiSDK` 0.1.0 does not read THEN the spec SHALL list it and
   its handling (see Open Questions: key audit).

**Independent Test**: Repeat the iOS SDK's device checklist D20 with this library: install 0.8.0,
register, upgrade in place, confirm one device row and the same `getDeviceId()`.

---

### P1: Integrator setup on the new version ⭐ MVP

**User Story**: As an integrator, I want clear, minimal iOS setup steps for the new version, so that
push, rich media and In-App keep working after `pod install`.

**Why P1**: Without correct setup the device never receives a token; the setup is a public contract.

**Acceptance Criteria**:

1. WHEN an integrator follows the README iOS section THEN APNs token capture and the
   `UNUserNotificationCenter` delegate SHALL work through exactly one path (the chosen option of G1), and
   the token SHALL be registered once, not twice.
2. WHEN an integrator keeps the 0.8.0 `AppDelegate` code (`NottiBridge`, `NottiPushDelegate.shared`)
   THEN the app SHALL still build, and behavior SHALL follow the documented rule of G1 (no double
   registration, no duplicate `received`).
3. WHEN an integrator has a Notification Service Extension THEN the README SHALL give the new Podfile
   line and `import` for the rich-media helper (G2), and the helper's call signatures SHALL stay
   `didReceive(_:withContentHandler:)` and `serviceExtensionTimeWillExpire(_:contentHandler:)`.
4. WHEN the integrator uses Expo prebuild THEN the config plugin SHALL produce a project that builds
   and registers a device without manual native edits beyond what the README lists for Expo.
5. WHEN the change ships THEN `CHANGELOG.md` `[Unreleased]` SHALL hold upgrade notes for every
   integrator-visible change, and the release SHALL be marked breaking if any 0.8.0 setup step stops
   working.

**Independent Test**: Fresh RN app and fresh Expo app following only the README reach a registered
device, a delivered rich push and a shown In-App message.

---

### P1: Builds in every supported linkage ⭐ MVP

**User Story**: As an integrator, I want the library to build whatever linkage my Podfile uses, so that
the dependency on `NottiSDK` doesn't force a project change.

**Why P1**: A build failure blocks every upgrade.

**Acceptance Criteria**:

1. WHEN the example app builds with static libraries (default), `use_frameworks! :linkage => :static`
   and `use_frameworks! :linkage => :dynamic` THEN each SHALL compile, link and launch, and the
   `NottiSDK` launch hook (`+load`) SHALL run.
2. WHEN the RN Swift module (`Notti`) references the SDK's `Notti` facade (module `NottiSDK`) THEN the
   names SHALL resolve without ambiguity in all three linkages.
3. WHEN the app also has an NSE target THEN app and NSE SHALL build together in all three linkages
   (iOS SDK AD-012 scenario).

**Independent Test**: `pnpm run build:ios` plus two CI matrix legs with `use_frameworks!`.

---

### P2: Tests at the right layer

**User Story**: As a maintainer, I want the RN repo to test only what it implements, so that the suite
stays fast and doesn't duplicate the iOS SDK's tests (lesson L-001).

**Acceptance Criteria**:

1. WHEN the Swift core is removed THEN the matching suites in `ios/Tests/` SHALL be removed, and the
   remaining XCTest suite SHALL cover the adapter: argument mapping, payload mapping to Codegen types,
   listener lifecycle across invalidate, initial click, `sdk_version` and the link rule.
2. WHEN the CI runs THEN the definition of done (`pnpm typecheck && pnpm lint && pnpm test &&
   pnpm run build:android && pnpm run build:ios`) and the `NottiTests` scheme SHALL pass.

---

### P3: Single privacy manifest source

**User Story**: As an integrator, I want one correct privacy manifest for the SDK, so that App Store
privacy reports are accurate.

**Acceptance Criteria**:

1. WHEN the app is archived THEN the privacy report SHALL contain the `NottiSDK` manifest and SHALL NOT
   contain the old `Notti_Privacy` bundle from this repo.

---

## Edge Cases

- WHEN a JS call reaches the module before `initialize` THEN behavior SHALL match 0.8.0 for that call;
  where `NottiSDK` differs (it logs a warning for identity calls before `initialize`, iOS SDK AD-021),
  the difference SHALL be listed in the upgrade notes.
- WHEN JS calls `initialize` twice with the same config THEN nothing SHALL change; with a different
  app id, client key or base URL THEN the SDK SHALL reset as in 0.8.0 (iOS SDK AD-009 is idempotent
  on equal config and recreates the core otherwise).
- WHEN the host app has another push SDK or local notifications THEN only Notti pushes SHALL produce JS
  events (0.8.0 I4 rule). `willPresent` presentation options SHALL be documented if they change from
  0.8.0 (`[.banner, .list, .sound, .badge]` for every notification) to the iOS SDK's rule (iOS SDK
  AD-010 D2).
- WHEN `requestPermission` is called while a request is in flight THEN the promise SHALL resolve as in
  0.8.0.
- WHEN the integrator's Podfile cannot resolve the required `NottiSDK` version THEN `pod install`
  SHALL fail with a CocoaPods resolution error, and the README SHALL say which source line to add (G3).

---

## Open Questions (gray areas, to decide in Discuss)

**Resolved 2026-10-31 (Julio), see `context.md`:** G1 = (a) adopt swizzling, 0.8.0 symbols deprecated
and harmless; G2 = (a) subspec becomes an alias of `NottiSDKExtension`; G3 = `NottiSDK` 0.2.0 on the
trunk before the cutoff, own spec repo for later versions; G4 = `@_spi(Wrapper)` hook in `NottiSDK`
0.2.0. Key audit and release number stay open for Design.

- **G1 - APNs and delegate capture.** 0.8.0 has no swizzling: the integrator forwards from
  `AppDelegate` (`NottiBridge`) and sets `NottiPushDelegate.shared` as the center delegate. `NottiSDK`
  swizzles by default (`+load`, iOS SDK AD-004/AD-010) with an opt-out key that is still only a
  proposal (`NottiDisableSwizzling`, iOS SDK AD-014). Linking `NottiSDK` turns swizzling on, so both
  paths would run. Options: (a) adopt swizzling and make `NottiBridge`/`NottiPushDelegate` deprecated
  no-ops; (b) keep manual forwarding, disable swizzling and forward to `NottiSDK`'s manual API.
- **G2 - NSE packaging.** Options: (a) `Notti/NotificationServiceExtension` subspec becomes a thin
  dependency on `NottiSDKExtension`; (b) remove the subspec and document `pod 'NottiSDKExtension'`.
  The Swift `import` changes from `Notti` to `NottiSDKExtension` in both.
- **G3 - Distribution of `NottiSDK` versions after the trunk cutoff** (iOS SDK AD-022, proposed): own
  spec repo `zeeplabs/specs` with a Podfile `source` line (Expo plugin can inject it), `:git`/`:tag`
  in the app's Podfile, or RN's experimental `spm_dependency`. The cutoff date (2026-12-02) comes from
  third-party sources and was not confirmed in the official announcement.
- **G4 - `sdk_version` hook.** `NottiSDK` 0.1.0 accepts `sdkVersion` only in internal `NottiCore`; the
  public `initialize` has no parameter. Requires a `NottiSDK` release with a wrapper hook. Options:
  `@_spi(Wrapper)` API (outside semver), a public `Options` field, or compiling this pod with
  `-package-name NottiSDK` (rejected unless the others fail: couples the two packages' internals).
- **Key audit.** Confirm every persisted key 0.8.0 writes is read by `NottiSDK` 0.1.0 (the SDK claims
  RN 0.8.0 parity; the audit proves it).
- **Release number.** 0.9.0 with `BREAKING CHANGE` if any 0.8.0 setup step breaks, otherwise minor.

---

## Requirement Traceability

| Requirement ID | Story | Phase | Status |
| --- | --- | --- | --- |
| NSDK-01 | P1: Delegates to `NottiSDK` (podspec dependency, no core Swift) | Specify | Pending |
| NSDK-02 | P1: Delegates (method forwarding) | Specify | Pending |
| NSDK-03 | P1: Delegates (`sdk_version` = RN version, needs G4) | Specify | Pending |
| NSDK-04 | P1: Delegates (no link opening, AD-004) | Specify | Pending |
| NSDK-05 | P1: Delegates (event emission, payload shape) | Specify | Pending |
| NSDK-06 | P1: Delegates (listener lifecycle on reload) | Specify | Pending |
| NSDK-07 | P1: Delegates (initial click) | Specify | Pending |
| NSDK-08 | P1: Upgrade keeps device id | Specify | Pending |
| NSDK-09 | P1: Upgrade flushes 0.8.0 queues | Specify | Pending |
| NSDK-10 | P1: Upgrade key audit | Specify | Pending |
| NSDK-11 | P1: Setup, single APNs/delegate path (G1) | Specify | Pending |
| NSDK-12 | P1: Setup, 0.8.0 `AppDelegate` code still builds (G1) | Specify | Pending |
| NSDK-13 | P1: Setup, NSE path (G2) | Specify | Pending |
| NSDK-14 | P1: Setup, Expo plugin | Specify | Pending |
| NSDK-15 | P1: Setup, README + upgrade notes | Specify | Pending |
| NSDK-16 | P1: Builds, three linkages | Specify | Pending |
| NSDK-17 | P1: Builds, `Notti` name resolution | Specify | Pending |
| NSDK-18 | P1: Builds, app + NSE | Specify | Pending |
| NSDK-19 | P2: Adapter-level tests, old suites removed | Specify | Pending |
| NSDK-20 | P2: Gates green | Specify | Pending |
| NSDK-21 | P3: Single privacy manifest | Specify | Pending |

**Coverage:** 21 total, 0 mapped to tasks.

---

## Success Criteria

- [ ] `ios/` holds only the Obj-C++ shim and the adapter (target: under 600 lines of Swift, down from
      about 6,900), and `ios/Tests/` only adapter tests.
- [ ] D20-equivalent upgrade from 0.8.0 on a device: one device row, same `getDeviceId()`.
- [ ] Example app passes the same manual checks as 0.8.0 (push, rich push, tap cold start, In-App
      click) on a device.
- [ ] Fresh RN and fresh Expo app reach a registered device from the README alone.
