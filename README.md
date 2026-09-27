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

## Requirements

- React Native with the [New Architecture](https://reactnative.dev/architecture/landing-page) enabled (Turbo Modules).
- Android: `minSdkVersion` compatible with `com.google.firebase:firebase-messaging` (Firebase Cloud Messaging configured in your Firebase project).
- iOS: Push Notifications capability enabled for your app target (APNs).
- A running [Notti](https://github.com/zeeplabs/zeep-notti) instance (self-hosted or SaaS) and an App's `appId`/`clientKey`.

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
| `Notti.login(externalUserId)` | Associates the device with your own user id. |
| `Notti.logout()` | Clears the external user id locally. Note: Notti' backend doesn't support clearing `external_user_id` server-side, so the previously-set value remains on the Device row server-side — `logout()` only affects local SDK state. |
| `Notti.setSubscription(enabled)` | Enables/disables push delivery for the device without unregistering it. |
| `Notti.getDeviceId(): string \| null` | Cached, synchronous read of the Notti-internal device id — the id your own backend needs to route notifications to this device. Returns `null` until registration assigns one; no network round-trip. Subscribe to `'deviceIdChanged'` (below) *before* calling this — registration can complete between the two calls, and there is no replay of a value already assigned. |
| `Notti.addEventListener(eventName, callback)` | Subscribes to `'notificationReceived'` (foreground), `'notificationClicked'` (warm: app already running, backgrounded or foregrounded), or `'deviceIdChanged'` (fired when the device id is first assigned or later changes — reinstall, device change, revocation/renewal). Returns an `EventSubscription` — call `.remove()` to unsubscribe. Does **not** fire for a cold-start click — use `getInitialNotificationClick()` for that. |
| `Notti.getInitialNotificationClick(): Promise<NotificationPayload \| null>` | Resolves the notification that cold-launched the app from a tap, or `null` if the app wasn't launched that way. Only resolves once per cold start — the native side clears it after this reads it. Call at startup, before/alongside `addEventListener`. |

All tag/external-id/subscription mutations are serialized client-side (one in-flight network call at a time, last-write-wins on the merged local state) — calling them back-to-back is safe.

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

Known constraints (Apple platform limits, not Notti-specific): APNs payloads are capped at 4KB; the extension has roughly 30s to finish before the OS falls back to the plain notification; a Notification Service Extension **does not run in the iOS Simulator** since Xcode 11.4 — test rich push on a physical device.

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

**Device/OS backups may carry Notti's local device identity across devices.** Notti persists `device_id`, `last_token`, `external_user_id` and tags in `SharedPreferences` (Android, file `notti_prefs`) / `UserDefaults` (iOS) — both are included in a full device backup/restore by default (Android Auto Backup, iOS device backups via Finder/iCloud). Restoring that backup onto a different physical device could carry this install's identifiers onto it before Notti has re-registered in that new process, briefly aiming mutations (`login`, `addTags`, `setSubscription`) at the *donor* device's row on your backend. If your app's identifiers here are LGPD/PII-relevant, exclude them from backup:
- **Android**: point `android:fullBackupContent`/`android:dataExtractionRules` at rules that exclude the `notti_prefs` shared-preferences file (see [Auto Backup for Apps](https://developer.android.com/guide/topics/data/autobackup)), or set `android:allowBackup="false"` app-wide if you don't otherwise rely on backup.
- **iOS**: no code change needed if you already avoid syncing sensitive `UserDefaults` keys, but validate Notti's keys (`notti_device_id`, `notti_last_token`, `notti_external_user_id`, `notti_tags`) against your own backup/compliance review.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for released and upcoming changes.

## License

[MIT](LICENSE)
