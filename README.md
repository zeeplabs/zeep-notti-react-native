# react-native-notti

[![CI](https://github.com/zeeplabs/zeep-notti-react-native/actions/workflows/ci.yml/badge.svg)](https://github.com/zeeplabs/zeep-notti-react-native/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/react-native-notti.svg)](https://www.npmjs.com/package/react-native-notti)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](./CONTRIBUTING.md)
![Platforms](https://img.shields.io/badge/platform-Android%20%7C%20iOS-lightgrey.svg)

Official React Native SDK for [Notti](https://github.com/zeeplabs/zeep-notti) push notifications (FCM + APNs). Handles device registration, tags, external user id, subscription state, and notification-received/clicked events — no hand-rolled REST calls required.

Notti is self-hosted or SaaS per deployment. By default `initialize` targets Notti's SaaS instance (`https://app.zeepnotti.app`); pass your own instance's `baseUrl` for self-hosted deployments or to target a sandbox instance.

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [API reference](#api-reference)
- [Bare React Native setup](#bare-react-native-setup)
- [Rich push notifications (iOS)](#rich-push-notifications-ios)
- [Data collected by the SDK](#data-collected-by-the-sdk)
- [Privacy, App Store labels and LGPD](#privacy-app-store-labels-and-lgpd)
- [Known limitations](#known-limitations)
- [Forwarding events manually](#forwarding-events-manually)
- [Expo setup](#expo-setup)
- [Manual smoke testing](#manual-smoke-testing)
- [Contributing](#contributing)
- [Security](#security)
- [Changelog](#changelog)
- [License](#license)

## Features

- 📲 **Device registration** — FCM (Android) / APNs (iOS) token fetched and registered natively, no extra push library required in the host app.
- 🏷️ **Tags & segmentation** — add/remove tags for Notti Segments, merged and persisted server-side.
- 👤 **External user id** — associate/clear the device with your own user id (`login`/`logout`).
- 🔕 **Subscription control** — enable/disable delivery without unregistering the device.
- 🔔 **Notification events** — `notificationReceived` (foreground) and `notificationClicked` (warm), plus `getInitialNotificationClick()` for cold-start taps.
- 🆔 **Device id** — `getDeviceId()` (cached getter) and `deviceIdChanged` event expose the Notti-internal id your own backend needs to route notifications to this device.
- 🧩 **Turbo Module (New Architecture)** — thin TypeScript facade over native Kotlin/Swift; works even if the JS thread isn't running yet.
- ⚙️ **Expo config plugin included** — works in bare React Native and Expo (dev client/prebuild) with no extra native-config package.
- 🔁 **Safe by default** — mutations (tags, subscription, login) are serialized client-side; retried with exponential backoff on transient failure.
- 🖼️ **Rich push (iOS)** — image/video/audio attachments via a Notification Service Extension helper, same setup model as OneSignal's.
- 📈 **CTR event reporting** — `received`/`clicked` events reported automatically to Notti, with an on-disk retry queue. See [Data collected by the SDK](#data-collected-by-the-sdk).
- 🧭 **Segment telemetry** — app version and session aggregates synced automatically; device country only after an explicit opt-in (`setLocationSharingEnabled`, default off).
- 📇 **Device profile** — OS version, device model, SDK version, timezone, language and detailed push-permission status synced automatically; first-class email/phone via `User.setEmail`/`User.setPhone`.

## Requirements

- React Native with the [New Architecture](https://reactnative.dev/architecture/landing-page) enabled (Turbo Modules).
- Android: `minSdkVersion` compatible with `com.google.firebase:firebase-messaging` (Firebase Cloud Messaging configured in your Firebase project).
- iOS: Push Notifications capability enabled for your app target (APNs).
- A running [Notti](https://github.com/zeeplabs/zeep-notti) instance (self-hosted or SaaS) and an App's `appId`/`clientKey`. The device-profile fields require `zeep-notti` **v0.10.0 or later**.

## Installation

```sh
npm install react-native-notti
```

This installs the Turbo Module (New Architecture) for both bare React Native and Expo. Native setup differs by path — see [Bare React Native setup](#bare-react-native-setup) / [Expo setup](#expo-setup) below.

## Usage

```ts
import { Notti } from 'react-native-notti';

// Call once, e.g. at app startup. Registers the device with Notti using
// the current FCM (Android) / APNs (iOS) token. Defaults to Notti's SaaS
// instance - pass `baseUrl` for self-hosted or sandbox instances.
Notti.initialize('<appId>', '<clientKey>');
// Notti.initialize('<appId>', '<clientKey>', { baseUrl: 'https://push.example.com' });

// Ask for the OS push permission whenever your app is ready to show the
// prompt (not tied to initialize - call it explicitly, when you want it).
const granted = await Notti.requestPermission();

// Tag the device for Notti Segments.
Notti.User.addTag('plan', 'vip');
Notti.User.addTags({ plan: 'vip', region: 'br' });
Notti.User.removeTag('plan');
Notti.User.removeTags(['plan', 'region']);

// First-class contact attributes (never merged into tags).
Notti.User.setEmail('user@example.com');
Notti.User.setPhone('+5511999999999');
Notti.User.clearEmail();
Notti.User.clearPhone();

// Associate the device with your own user id.
Notti.login('external-user-123');
Notti.logout();

// The Notti-internal device id your own backend needs to route
// notifications to this device. Subscribe *before* reading the current
// value: registration can complete between the two calls, and the event
// does not replay a change it already fired before you started listening.
const deviceIdChanged = Notti.addEventListener('deviceIdChanged', (id) => {
  console.log('Notti device id', id);
});

// `null` until registration assigns one - cached locally, no network
// round-trip. Persist whichever of the two you get first (this call, or the
// listener above) alongside your user record.
const deviceId = Notti.getDeviceId();

deviceIdChanged.remove();

// Enable/disable delivery without unregistering the device.
Notti.setSubscription(true);

// Opt-in (default: off) to country-based segmentation. The SDK never asks for
// location permission itself - only call this after your own consent flow, and
// only expect a country to be reported if your app already holds location
// permission. Passing `false` clears the previously reported country.
Notti.setLocationSharingEnabled(true);

// React to incoming/clicked notifications in-app.
const received = Notti.addEventListener('notificationReceived', (payload) => {
  console.log(payload.title, payload.body, payload.data);
});
const clicked = Notti.addEventListener('notificationClicked', (payload) => {
  console.log(payload.title, payload.body, payload.data);
});

// Call .remove() on the returned subscription when you're done listening
// (e.g. in a useEffect cleanup function).
received.remove();
clicked.remove();

// Cold start: the tap that launched the app happens before any listener
// above can be registered, so 'notificationClicked' never fires for it.
// Check once at startup instead.
Notti.getInitialNotificationClick().then((payload) => {
  if (payload) {
    console.log('app was launched by a notification tap', payload);
  }
});
```

## API reference

| Method | Description |
| --- | --- |
| `Notti.initialize(appId, clientKey, options?)` | Registers the device with your Notti instance. `options.baseUrl` defaults to Notti's SaaS instance (`https://app.zeepnotti.app`) — pass it for self-hosted or sandbox instances. Safe to call multiple times — a repeat call with the same `appId`/`clientKey` is a no-op. Never throws: missing/invalid arguments or a missing native push prerequisite (no `google-services.json`, no APNs capability) are logged, not thrown. |
| `Notti.requestPermission(): Promise<boolean>` | Triggers the native OS push-permission prompt. Resolves `true` immediately on Android below API 33 (no runtime permission exists there). Must be called after `initialize()` has run at least once. |
| `Notti.User.addTag(key, value)` / `Notti.User.addTags(tags)` | Merges tag(s) into the device's tag map and persists the full resulting map server-side. |
| `Notti.User.removeTag(key)` / `Notti.User.removeTags(keys)` | Removes tag key(s) from the device's tag map. |
| `Notti.User.setEmail(email)` / `Notti.User.setPhone(phone)` | Sets the device's first-class `email`/`phone` attribute (personal data — see [Privacy](#privacy-app-store-labels-and-lgpd)). Not format-validated by the SDK; the backend rejects malformed values. Calling it again with the value the backend already acknowledged is a no-op. Re-sent automatically on registration so a fresh device row converges. |
| `Notti.User.clearEmail()` / `Notti.User.clearPhone()` | Removes the value locally and sends an explicit `null` to the backend. Durable: if the clear cannot complete (called before `initialize`, offline, process killed, server error), it is re-sent on the next registration. |
| `Notti.login(externalUserId)` | Associates the device with your own user id. |
| `Notti.logout()` | Clears the external user id locally, and clears `email`/`phone` both locally and server-side (same durable path as `clearEmail`/`clearPhone`), so a previous user's contact data never stays on the device for the next user. Note: Notti's backend doesn't support clearing `external_user_id` server-side, so that value remains on the Device row server-side. |
| `Notti.setSubscription(enabled)` | Enables/disables push delivery for the device without unregistering it. |
| `Notti.setLocationSharingEnabled(enabled)` | Opt-in for reporting the device's country (ISO 3166-1 alpha-2) for segment targeting. **Default `false`.** The flag is persisted locally, so it survives restarts until you call it again. `true`: at the next session start, if the host app already holds OS location permission, the SDK reads the last cached location fix, reverse-geocodes it to a country code and sends only that code. It never prompts for permission and never runs continuous/background location. `false`: stops reading and sends an explicit `country: null` to the backend so the previously reported value is cleared, not just left stale. See [Opt-in country](#opt-in-country-setlocationsharingenabled). |
| `Notti.getDeviceId(): string \| null` | Cached, synchronous read of the Notti-internal device id — the id your own backend needs to route notifications to this device. Returns `null` until registration assigns one; no network round-trip. Subscribe to `'deviceIdChanged'` (below) *before* calling this — registration can complete between the two calls, and there is no replay of a value already assigned. |
| `Notti.addEventListener(eventName, callback)` | Subscribes to `'notificationReceived'` (foreground), `'notificationClicked'` (warm: app already running, backgrounded or foregrounded), or `'deviceIdChanged'` (fired when the device id is first assigned or later changes — reinstall, device change, revocation/renewal). Returns an `EventSubscription` — call `.remove()` to unsubscribe. Does **not** fire for a cold-start click — use `getInitialNotificationClick()` for that. |
| `Notti.getInitialNotificationClick(): Promise<NotificationPayload \| null>` | Resolves the notification that cold-launched the app from a tap, or `null` if the app wasn't launched that way. Only resolves once per cold start — the native side clears it after this reads it. Call at startup, before/alongside `addEventListener`. |

All tag/external-id/subscription mutations are serialized client-side (one in-flight network call at a time, last-write-wins on the merged local state) — calling them back-to-back is safe.

`NotificationPayload` is `{ title?: string | null; body?: string | null; data?: { [key: string]: string } }`. Both platforms deliver a missing title/body as `null` (not `undefined`), so check with `== null` (or `?? fallback`) rather than `=== undefined`.

## Bare React Native setup

The Expo config plugin (below) automates all of this on `expo prebuild`. For a bare RN project, do it by hand:

### Android

1. Place your Notti App's `google-services.json` at `android/app/google-services.json` in your app (not this library).
2. Apply the Google Services Gradle plugin in your app's `android/build.gradle` (root) and `android/app/build.gradle`:

   ```gradle
   // android/build.gradle
   buildscript {
     dependencies {
       classpath("com.google.gms:google-services:4.4.4")
     }
   }
   ```

   ```gradle
   // android/app/build.gradle
   apply plugin: "com.google.gms.google-services"
   ```

3. Declare the runtime notification permission in your app's own `android/app/src/main/AndroidManifest.xml` (required for `requestPermission()` to actually prompt on Android 13+):

   ```xml
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
   ```

The library's own manifest already registers its `FirebaseMessagingService` and merges into your app automatically via Gradle manifest merging — no manual step needed for that part. The `com.google.firebase:firebase-messaging` dependency is likewise already pulled in by this library.

4. If your main `Activity`'s `launchMode` is `singleTask` or `singleTop` (the RN/Expo default), override `onNewIntent` and call `setIntent(intent)`. Without it, tapping a notification while the app is already running (backgrounded, not killed) reuses the existing `Activity`, `onNewIntent` fires, but `Activity.getIntent()` keeps returning the **stale** launch intent — which is what this SDK reads to detect a click. Result: `notificationClicked` silently never fires on that path, while a cold-start tap (killed app, fresh `Activity`/intent) works fine, making the bug easy to miss in testing.

   ```kotlin
   // MainActivity.kt
   override fun onNewIntent(intent: Intent) {
     super.onNewIntent(intent)
     setIntent(intent)
   }
   ```

### iOS

1. Enable the **Push Notifications** capability for your app target in Xcode (adds the `aps-environment` entitlement).
2. Forward the APNs callbacks from your own `AppDelegate` — the SDK deliberately does **not** use method swizzling (see `design.md`'s AD-002 for why), so this small amount of integrator code is required:

   ```swift
   // AppDelegate.swift
   import UserNotifications

   func application(
     _ application: UIApplication,
     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
   ) {
     NottiBridge.didRegisterForRemoteNotifications(deviceToken: deviceToken)
   }

   func application(
     _ application: UIApplication,
     didFailToRegisterForRemoteNotificationsWithError error: Error
   ) {
     NottiBridge.didFailToRegisterForRemoteNotifications(error)
   }

   func application(
     _ application: UIApplication,
     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
   ) -> Bool {
     UNUserNotificationCenter.current().delegate = NottiPushDelegate.shared
     // ... your existing launch code
     return true
   }
   ```

Without this forwarding, the device token never reaches the SDK and `notificationReceived`/`notificationClicked` never fire — `initialize()` still registers the device (with a `subscribed: false` state) but push delivery won't complete until the callbacks are wired.

## Rich push notifications (iOS)

Attaching an image/video/audio to a push on iOS requires a [`Notification Service Extension`](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension) (NSE) — a separate, sandboxed app-extension target Apple requires for downloading and attaching media before the notification is shown. This is not something a Turbo Module can inject into your Xcode project automatically; like OneSignal, Notti ships the attachment logic as a small helper you wire into a target you create yourself (see `docs/adr/002-ios-rich-push-via-notification-service-extension-subspec.md` for the full rationale).

> **Not supported in an Expo managed workflow.** This setup requires manually creating and configuring a native Xcode target (steps 1–3 below); there is no Expo config plugin for it, and running `expo prebuild` regenerates `ios/` from scratch, destroying a manually-added target. Bare React Native (or an Expo app that has already ejected) only.

> **Requires `@objc(NotificationService)` on your extension's class.** `Info.plist`'s `NSExtensionPrincipalClass` addresses your class by string name at runtime (`NSClassFromString`); without an explicit Objective-C name, a plain Swift class name is mangled and the OS silently fails to instantiate the extension — it never runs, with no error anywhere, and the Simulator can't catch this either (NSE doesn't run there at all). The snippet below includes it — don't drop it.

1. In Xcode: **File > New > Target… > Notification Service Extension**. Name it (e.g. `NotificationService`), same deployment target as your app, "Don't Activate" when prompted.
2. Add it to your **Podfile** in its own target — never alongside your app's main target, since the extension never runs the RN runtime:

   ```ruby
   target 'NotificationService' do
     pod 'Notti/NotificationServiceExtension', :path => '../node_modules/react-native-notti'
   end
   ```

   Run `pod install` after adding it.
3. Replace the generated `NotificationService.swift` body with a one-line forwarding call into the helper:

   ```swift
   import UserNotifications
   import Notti

   @objc(NotificationService)
   class NotificationService: UNNotificationServiceExtension {
     var contentHandler: ((UNNotificationContent) -> Void)?
     var bestAttemptContent: UNMutableNotificationContent?

     override func didReceive(
       _ request: UNNotificationRequest,
       withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
     ) {
       self.contentHandler = contentHandler
       bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent
       NottiNotificationServiceExtension.didReceive(request, withContentHandler: contentHandler)
     }

     override func serviceExtensionTimeWillExpire() {
       guard let contentHandler else { return }
       NottiNotificationServiceExtension.serviceExtensionTimeWillExpire(
         for: bestAttemptContent, contentHandler: contentHandler
       )
     }
   }
   ```

Payload contract: the Notti backend sets `"notti_image_url"` (a URL string, sibling of `aps`) together with `aps.mutable-content: 1` whenever a push carries an attachment — namespaced so it can never collide with your own custom data field of the same name. Only `https://` URLs are honored; anything else (including `file://`/`http://`) is ignored. If the key is missing, malformed, or times out (~20s, under the extension's own ~30s OS budget), the helper calls `contentHandler` with the original (attachment-less) content — same fallback OneSignal itself documents.

Download rules enforced by the helper:

- **https only**, re-checked on the final URL after redirects — an `https://` URL that redirects to `http://` is refused.
- **10 MB cap** on the downloaded file; larger downloads are discarded and the original content is shown.
- **Attachment type allowlist**: the file extension is derived from the response MIME type (`image/jpeg`, `image/png`, `image/gif`, `video/mp4`, `audio/mpeg`), falling back to the URL's extension only if it is one of `jpg`, `png`, `gif`, `mp4`, `mp3`; anything else is saved as `jpg` (and may then be rejected by iOS itself, in which case the original content is shown).
- Non-2xx responses, timeouts and any download/attachment error fall back to the original content.

Known constraints (Apple platform limits, not Notti-specific): APNs payloads are capped at 4KB; the extension has roughly 30s to finish before the OS falls back to the plain notification; a Notification Service Extension **does not run in the iOS Simulator** since Xcode 11.4 — test rich push on a physical device.

> **CocoaPods subspecs.** `Notti.podspec` is split into `Notti/Core` (the Turbo Module; `default_subspec`, so plain `pod 'Notti'`/autolinking keeps working) and `Notti/NotificationServiceExtension` (the helper above, no React dependency). If your Podfile pins subspecs explicitly, make sure the app target gets `Core`.

## Data collected by the SDK

Besides what device registration already sends (push token, platform, `external_user_id`, tags, subscription state), the SDK sends the data below to **your configured Notti instance** (`baseUrl`). Nothing is sent to third parties by the SDK itself, except the OS reverse-geocoding call described under [Opt-in country](#opt-in-country-setlocationsharingenabled).

### Automatic (no toggle)

There is currently **no API to disable** the items in this subsection: they are sent by every integration of this version of the SDK.

| Data | When | Field(s) sent |
| --- | --- | --- |
| App version | Read once per launch (`CFBundleShortVersionString` on iOS, `versionName` on Android); sent via device `PATCH` when it differs from the last value the backend acknowledged. Sent as an opaque string. | `app_version` |
| Session aggregates | A session is one foreground → background/terminate cycle of the host app. On session end the SDK increments a local counter, adds the foreground duration, and issues a device `PATCH` with the cumulative snapshot. Once the device is registered, **every move to background sends one session `PATCH` right away** (iOS runs it inside an OS background task). Only before registration completes are snapshots coalesced: the queued session `PATCH` is replaced by the newer one, so a single request goes out when registration succeeds. A session left open by a force-quit/crash is closed on the next launch (see [Session heartbeat](#session-heartbeat-and-orphaned-sessions)). Non-interactive wake-ups (extensions, background fetch) do not count. | `first_session_at`, `last_session_at` (ISO-8601 UTC), `session_count`, `session_time_seconds` |
| Notification events (CTR) | See below. | `type`, `delivery_id`, `token` |
| Device profile | Read natively at initialize (and permission status again at each session start and after `requestPermission`); each field sent via device `PATCH` only when it differs from the last value the backend acknowledged. A field the OS can't provide is omitted, never fabricated. | `device_os`, `device_model`, `sdk_version`, `timezone_id` (IANA), `language` (ISO 639-1) |
| Push permission status | The OS permission state, independent of `setSubscription`: `granted`, `denied`, `notDetermined`, `provisional` (iOS only). An unknown/transitional state is omitted. | `permission_status` |
| Last unsubscribe | Timestamp of the most recent transition to unsubscribed, either `setSubscription(false)` or permission `granted` → `denied`. Never cleared by re-subscribing. | `last_unsubscribed_at` (ISO-8601 UTC) |

### Set by the integrator

| Data | When | Field(s) sent |
| --- | --- | --- |
| Email / phone | Only when you call `User.setEmail`/`User.setPhone`; cleared by `clearEmail`/`clearPhone` and by `logout()`. | `email`, `phone` |

#### Notification event (CTR) reporting

The SDK reports two event types to `POST {baseUrl}/v1/apps/{appId}/notifications/{notification_id}/events`, authenticated with the client key and the device's current push token:

- `clicked` — the user tapped the notification (default action) while the app was in the foreground, background, or killed (cold start). Custom action buttons and dismissals are **not** reported.
- `received` — the notification arrived through the same hook that emits `notificationReceived` (foreground). Notifications displayed by the OS while the app is backgrounded or killed are **not** reported as `received`.

No other event types exist (no `delivered`, `dismissed`, `opened`). Events are only reported when the push's `data` carries both `notification_id` and `delivery_id` (set by the Notti backend); other pushes are skipped silently.

Delivery guarantees, as implemented:

- Every event is written to disk **before** the first HTTP attempt and removed after a 2xx or a terminal failure.
- Retries: up to 5 attempts with exponential backoff (waits of 2s, 4s, 8s and 16s between attempts) on network errors, `5xx`, `408` and `429`. Any other `4xx` is terminal: the event is dropped and not retried. `Retry-After` is not honored. This is the same shared retry loop used by device registration and every device `PATCH` (see [Retry policy](#retry-policy)).
- Events are sent in queue order and a flush stops at the first non-terminal failure; the remaining events wait for the next trigger (see [Known limitations](#known-limitations)).
- Events still pending (offline, process killed mid-retry, retries exhausted) are flushed on the next app launch and when network connectivity returns.
- The on-disk queue holds at most **32** events; beyond that the oldest event is dropped.
- At-least-once: a crash between a successful send and the local cleanup can produce a duplicate report. The Notti backend tolerates duplicates by design.

#### Session heartbeat and orphaned sessions

- While a session is open **and the app is in the foreground**, the SDK persists a "last seen in foreground" timestamp every **60 seconds** (Android: main-thread handler started/stopped with the process lifecycle; iOS: a timer that only writes while the app is active). Nothing is written while the app is in background.
- If the process dies without a background transition (force-quit, crash), the next session start closes the orphaned session at that last heartbeat, not at "now", so time the process was dead is not counted as foreground. The estimate is at most one heartbeat interval short.
- The credited duration of an orphaned session is capped: **12 h on Android**, **24 h on iOS**. A session with no heartbeat beyond its own start (e.g. persisted by an older SDK version) is credited **0 s**.
- The heartbeat key differs per platform: `notti_last_foreground_at_ms` (Android) and `notti_session_last_seen_at_ms` (iOS) — see [Locally persisted data](#locally-persisted-data-backup-and-deletion).
- On both platforms a process-wide session gate (Android `NottiModule.processSessionGate`, iOS `NottiImpl.processSessionGate` / `NottiCore.SessionGate`) ensures a single session per foreground of the process. After a JS reload with the app in the foreground, the new core adopts the persisted open session instead of closing it as an orphan: `session_count` is not changed and only the heartbeat is resumed. The gate closes when the app goes to the background. On iOS, tearing the module down (`invalidate`) removes the old core's lifecycle observers and stops its heartbeat, so the old and the new core do not end the same session twice. On Android the gate also absorbs a duplicate foreground signal (cold-start sync racing the lifecycle observer).

### Retry policy

All HTTP calls go through one shared retry loop (`executeWithRetry` on both platforms): device registration (`POST /devices`), every device `PATCH` (login, tags, subscription, telemetry, country clear) and CTR events.

- Up to **5 attempts**, exponential backoff with waits of 2s, 4s, 8s and 16s between attempts.
- Retried: network errors, `5xx`, `408`, `429` and, for registration only, a `2xx` without a parseable device object (`PATCH` and events accept any `2xx`).
- Terminal (no retry): any other `4xx`.
- `Retry-After` is not honored.
- What happens after the attempts are exhausted depends on the caller: registration is retried on the next app foreground or token refresh; CTR events stay in the on-disk queue; a session `PATCH` is not retried itself (the next session end sends the new cumulative snapshot); a pending country clear stays pending.

### Pending-mutation queue before registration

Device mutations issued before registration completes are held in memory (lost on process death; persisted aggregates such as the session counters survive and are re-sent in the next snapshot) and flushed in order once registration succeeds. Telemetry mutations (session, country, app version) are coalesced by key: a newer one replaces the queued one. The queue limit of **32** behaves differently per platform:

- **Android**: telemetry does not count toward the 32-entry limit and is never evicted (at most one entry per telemetry key). When 32 user mutations (login, tags, subscription) are queued, the oldest user mutation is dropped.
- **iOS**: telemetry counts toward the limit. When the queue is full, a queued telemetry entry is evicted first; if the queue holds only user mutations, a new telemetry mutation is dropped, and a new user mutation evicts the oldest user mutation.

### Opt-in country (`setLocationSharingEnabled`)

Off by default. Behavior with `Notti.setLocationSharingEnabled(true)`:

- At the **next session start**, only if the host app already holds OS location permission (iOS: `authorizedWhenInUse`/`authorizedAlways`; Android: `ACCESS_COARSE_LOCATION` granted), the SDK reads the **last cached** location fix (no active location request, no background tracking).
- The fix is reverse-geocoded on the device through the OS geocoder (iOS `CLGeocoder`, Android `android.location.Geocoder`). These platform services may send the coordinates to the OS/platform vendor's geocoding backend; that is outside this SDK's control.
- Only the resulting ISO 3166-1 alpha-2 code is sent to Notti (`country`). Raw coordinates are never sent to Notti nor stored by the SDK.
- No permission, location services off, no cached fix or a geocoder error → the field is simply omitted. No error is surfaced and no prompt is shown.

Behavior with `Notti.setLocationSharingEnabled(false)` (opt-out):

- Reading stops immediately and the SDK sends `{"country": null}` so the backend clears the previously reported value.
- The pending clear is persisted locally and only cleared after the backend acknowledges it with a 2xx; if the call cannot complete (called before `initialize`, offline, server error, process killed) it is re-sent on a later registration/foreground/flush.

Host-app requirements when you use country reporting:

- **iOS**: the SDK never requests permission, so your app must request it itself and declare `NSLocationWhenInUseUsageDescription` in `Info.plist` with your own purpose string. The `Notti/Core` subspec links `CoreLocation` (declared in the podspec, nothing to add manually) and references location APIs even if you never opt in; App Store Connect upload validation may therefore warn about a missing location purpose string (ITMS-90683) for any app using this SDK — adding `NSLocationWhenInUseUsageDescription` avoids that.
- **Android**: declare `ACCESS_COARSE_LOCATION` in your app's manifest and request it at runtime yourself. This library's manifest does not declare it.

## Privacy, App Store labels and LGPD

This section lists what the SDK does so you can fill in your own disclosures; it is not legal advice.

- **App Store privacy "nutrition" labels** — for the data in [Data collected by the SDK](#data-collected-by-the-sdk), you will typically need to evaluate at least: **Usage Data → Product Interaction** (CTR events, session count/time, first/last session), **Identifiers → Device ID** (push token / Notti device id, and **User ID** if you call `login`), **Contact Info → Email Address / Phone Number** if you call `User.setEmail`/`User.setPhone` (declared in the SDK's `PrivacyInfo.xcprivacy` as linked, not tracking, App Functionality), **Diagnostics / Other Data** for the device profile (OS version, model, SDK version, timezone, language, permission status), and **Location → Coarse Location** if you enable `setLocationSharingEnabled`. Whether each item is "linked to the user" depends on whether you call `login` and how you use Notti data; whether it is used for tracking depends on your own use. Google Play's Data safety form has equivalent categories (App activity, Device or other IDs, Personal info → Email address / Phone number, Approximate location).
- **LGPD (and similar laws)** — the SDK does not collect consent and does not decide a legal basis. The automatic telemetry has no toggle in this version; country reporting requires your explicit opt-in call. The integrator is responsible for having the legal basis, consent flow, privacy notice, retention and data-subject-request process for this data **validated by its own legal/DPO team** before shipping.
- **Data minimization in the SDK** — country only (no coordinates sent to Notti); last cached fix only (no tracking); explicit server-side clear on opt-out; CTR payloads carry only `delivery_id`, `type` and the push token.

## Known limitations

- **No reliable acknowledgement for `app_version`.** The backend accepts the telemetry fields since `zeep-notti` v0.9.0 (DEVTEL-01..13, 2026-09-30) and persists them, but the device PATCH response does not echo `app_version` back. The SDK treats the 2xx as acknowledged and marks `app_version` as synced, so it is **not re-sent until the value changes** (tracked as TODO `segtel-app-version-ack` in the Android code and `TODO(review item 7)` in the iOS code). Session snapshots are cumulative and re-sent at every session end, so they are not affected the same way.
- **One bad CTR event can stall the event queue.** Events are flushed in order and a flush stops at the first non-terminal failure. An event that deterministically gets `5xx` or `429` blocks the events behind it until 32 newer events push it out of the on-disk queue. There is no per-event TTL, and `Retry-After` is not honored.
- **A pending country clear that gets a permanent `4xx` is re-sent on every trigger** (registration, app foreground, network regain), because the flag is only cleared on a 2xx.
- **Android 13+ `permission_status` "never asked" vs "denied" is inferred.** Android does not expose "not determined" directly. The SDK reports `notDetermined` when `POST_NOTIFICATIONS` is not granted, the SDK's `requestPermission` never ran and the OS does not ask for a rationale. If you request the permission through another library and the user permanently denies it, the device may report `notDetermined`.
- **Backends older than `zeep-notti` v0.10.0** ignore the device-profile fields, but any 2xx marks them as synced, so static values (`device_model`, `device_os`, `sdk_version`) are not re-sent after the backend is upgraded until they change.
- **Not yet validated on real devices:** session close on cold start / process kill on both platforms; the iOS background task on a slow network; `CLLocationManager` usage without runtime warnings; the `aps-environment` value in an EAS `preview` build (see [`aps-environment` value](#aps-environment-value)).

## Forwarding events manually

Both native setup paths above assume Notti owns the platform's single push hook (iOS's `UNUserNotificationCenter` delegate, Android's manifest-declared `FirebaseMessagingService`). If your app already owns that hook for another reason and can't hand it to Notti, forward events into the SDK manually instead — no delegate/manifest ownership required on either platform:

**iOS** — `NottiPushDelegate.shared`'s methods are plain `public func`s, callable from inside your own delegate. Forward **both** callbacks — omitting `didReceive` silently loses every `notificationClicked` event and cold-start tap (I5, found in pre-release review):

```swift
func userNotificationCenter(
  _ center: UNUserNotificationCenter,
  willPresent notification: UNNotification,
  withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
) {
  NottiPushDelegate.shared.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
}

func userNotificationCenter(
  _ center: UNUserNotificationCenter,
  didReceive response: UNNotificationResponse,
  withCompletionHandler completionHandler: @escaping () -> Void
) {
  NottiPushDelegate.shared.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
}
```

**Android** — `NottiBridge` exposes the same two callbacks your own `FirebaseMessagingService` would otherwise miss:

```kotlin
class YourFirebaseMessagingService : FirebaseMessagingService() {
  override fun onNewToken(token: String) {
    NottiBridge.onNewToken(token)
  }

  override fun onMessageReceived(remoteMessage: RemoteMessage) {
    NottiBridge.onMessageReceived(remoteMessage)
  }
}
```

Note this only forwards the *events*; you're also responsible for removing this library's own manifest-declared `NottiFirebaseMessagingService` in your merged manifest (`tools:node="remove"` on the `<service>` entry) so it doesn't race your own service for the same `com.google.firebase.MESSAGING_EVENT` intent-filter.

## Expo setup

Add the config plugin to your `app.json`/`app.config.js`:

```json
{
  "expo": {
    "plugins": ["react-native-notti"]
  }
}
```

On `expo prebuild`, the plugin:

- **Android**: applies the Google Services Gradle plugin and copies your `google-services.json` (set via `android.googleServicesFile` in your Expo config, standard Expo convention).
- **iOS**: adds the `aps-environment` (push notifications) entitlement.

### `aps-environment` value

The value written to the entitlements file is resolved like this (`plugin/src/withNotti.ts`, `resolveApsEnvironment`):

1. If you pass `apsEnvironment` (`'development' | 'production'`) as a plugin prop, that value is used.
2. Otherwise, if the `EAS_BUILD_PROFILE` env var is **exactly** `production`, the value is `production`.
3. Otherwise (any other profile name — `preview`, `staging`, `development`, … — or no EAS at all, e.g. a local `expo prebuild`), the value is `development`.

> **Ad hoc / internal (`preview`) builds.** EAS's default `preview` profile uses `distribution: "internal"`, i.e. an **ad hoc** provisioning profile, and ad hoc and App Store builds receive **production** APNs tokens. With the rule above such a profile gets `development` written by the plugin. Xcode's archive/export step normally rewrites `aps-environment` from the distribution provisioning profile, so the final binary is expected to end up with `production` anyway — but this has not been verified by this project on a real EAS build, and the device token's APNs environment must match how your Notti instance sends to it. Check what actually shipped:
>
> ```sh
> unzip -o YourApp.ipa -d /tmp/ipa && codesign -d --entitlements :- /tmp/ipa/Payload/*.app | grep -A1 aps-environment
> ```
>
> To make the prebuild output match the distribution explicitly, pin the prop per profile in `app.config.js`:
>
> ```js
> const adHocOrStore = ['production', 'preview'].includes(process.env.EAS_BUILD_PROFILE);
>
> export default {
>   expo: {
>     plugins: [
>       ['react-native-notti', { apsEnvironment: adHocOrStore ? 'production' : 'development' }],
>     ],
>   },
> };
> ```
>
> Adjust the list to your own `eas.json` profiles: any profile signed with an ad hoc, enterprise or App Store profile uses production APNs; only development-signed builds (dev client on a registered device, `expo run:ios` with a development team) use the sandbox.

The Android runtime-permission declaration and the iOS `AppDelegate` forwarding above still apply the same way in an Expo dev client/prebuild project — the plugin only handles native project *configuration*, not the `AppDelegate` code path (Expo doesn't generate a customizable `AppDelegate` by default under managed workflow config plugins for this).

## Manual smoke testing

`example/` is a bare RN app wired against the real SDK (`example/src/App.tsx`) with placeholder credentials. To exercise it end-to-end against a running Notti instance:

1. Replace the `NOTTI_APP_ID`/`NOTTI_CLIENT_KEY`/`NOTTI_BASE_URL` placeholders in `example/src/App.tsx` with a real App's values (never commit real values).
2. Drop your own `google-services.json` at `example/android/app/google-services.json` (gitignored).
3. Run `pnpm example android` / `pnpm example ios`, or `pnpm run build:android` / `pnpm run build:ios` for a release-shaped build.
4. Tap the example screen's buttons and confirm a new Device row appears in Notti' admin screen, tags/subscription reflect your taps, and notifications sent from Notti trigger the `notificationReceived`/`notificationClicked` console logs.

## Contributing

See the [contributing guide](CONTRIBUTING.md) to learn how to contribute to the repository and the development workflow, including:

- [Development workflow](CONTRIBUTING.md#development-workflow)
- [Sanity gate / native tests](CONTRIBUTING.md#native-tests)
- [Sending a pull request](CONTRIBUTING.md#sending-a-pull-request)
- [Code of conduct](CODE_OF_CONDUCT.md)

Before opening a PR, make sure the full gate passes:

```sh
pnpm typecheck && pnpm lint && pnpm test && pnpm run build:android && pnpm run build:ios
```

## Security

Found a vulnerability? Please **don't** open a public issue — see [SECURITY.md](SECURITY.md) for how to report it privately.

### Locally persisted data, backup and deletion

Notti persists its state in `SharedPreferences` file `notti_prefs` (Android) and in the `UserDefaults` suite `notti_prefs` (iOS):

| Key(s) | Content |
| --- | --- |
| `notti_device_id`, `notti_last_token` | Notti device id and last push token |
| `notti_external_user_id` | Your external user id (`login`) |
| `notti_tags` (iOS) / `notti_tag_<key>` (Android) | Tag map |
| `notti_subscribed` | Subscription state |
| `notti_app_version` | Last app version acknowledged by the backend |
| `notti_session_count`, `notti_session_time_ms`, `notti_session_started_at_ms`, `notti_first_session_at_ms`, `notti_last_session_at_ms`, plus the open session's last-foreground heartbeat (`notti_session_last_seen_at_ms` on iOS, `notti_last_foreground_at_ms` on Android) | Session aggregates and the open session's timestamps |
| `notti_location_sharing_enabled` | Country opt-in flag |
| `notti_pending_country_clear` | Opt-out `country: null` clear not yet acknowledged by the backend |
| `notti_last_synced_country` | Last country code acknowledged by the backend (only ever set after opt-in) |
| `notti_last_synced_device_os`, `notti_last_synced_device_model`, `notti_last_synced_sdk_version`, `notti_last_synced_timezone_id`, `notti_last_synced_language`, `notti_last_synced_permission_status` | Device-profile values last acknowledged by the backend |
| `notti_last_unsubscribed_at_ms` | Most recent unsubscribe timestamp |
| `notti_pending_unsubscribe_at_ms`, `notti_pending_permission_unsubscribe_at_ms` | Unsubscribe timestamp (app- or permission-driven) detected but not yet acknowledged by the backend; re-sent unchanged on retry |
| `notti_permission_requested` (Android) | Whether the SDK's `requestPermission` has run (used to infer `notDetermined`) |
| `notti_email`, `notti_phone` | Email/phone set via `User.setEmail`/`User.setPhone` (plaintext) |
| `notti_last_synced_email`, `notti_last_synced_phone` | Email/phone last acknowledged by the backend (drives the durable clear) |
| `notti_pending_events` | Queued CTR events (local id, `notification_id`, `delivery_id`, `type`, creation timestamp) awaiting delivery, max 32 |

There is no SDK API to wipe this local data. Uninstalling the app removes it; `logout()` clears `notti_external_user_id`, `notti_email` and `notti_phone`. If you need a "delete my data" flow, delete the device's data on your Notti instance (server side) and clear the keys above yourself.

**Device/OS backups may carry Notti's local device identity across devices.** Both stores are included in a full device backup/restore by default (Android Auto Backup, iOS device backups via Finder/iCloud). Restoring that backup onto a different physical device could carry this install's identifiers (and its session/telemetry state and pending events) onto it before Notti has re-registered in that new process, briefly aiming mutations (`login`, `addTags`, `setSubscription`, telemetry) at the *donor* device's row on your backend. If this is LGPD/PII-relevant for your app, exclude them from backup:
- **Android**: point `android:fullBackupContent`/`android:dataExtractionRules` at rules that exclude the `notti_prefs` shared-preferences file (see [Auto Backup for Apps](https://developer.android.com/guide/topics/data/autobackup)), or set `android:allowBackup="false"` app-wide if you don't otherwise rely on backup.
- **iOS**: no code change needed if you already avoid syncing sensitive `UserDefaults` data, but validate the `notti_prefs` suite and the keys above against your own backup/compliance review.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for released and upcoming changes.

## License

[MIT](LICENSE)
