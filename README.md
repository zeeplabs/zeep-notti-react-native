# react-native-nuntis

Official React Native SDK for [Nuntis](https://github.com/zeeplabs/zeep-nuntis) push notifications (FCM + APNs). Handles device registration, tags, external user id, subscription state, and notification-received/clicked events — no hand-rolled REST calls required.

Nuntis is self-hosted or SaaS per deployment, so the SDK never hardcodes a host: you always pass your own instance's `baseUrl` to `initialize`.

## Installation

```sh
npm install react-native-nuntis
```

This installs the Turbo Module (New Architecture) for both bare React Native and Expo. Native setup differs by path — see below.

## Usage

```ts
import { Nuntis } from 'react-native-nuntis';

// Call once, e.g. at app startup. Registers the device with Nuntis using
// the current FCM (Android) / APNs (iOS) token.
Nuntis.initialize('<appId>', '<clientKey>', 'https://push.example.com');

// Ask for the OS push permission whenever your app is ready to show the
// prompt (not tied to initialize - call it explicitly, when you want it).
const granted = await Nuntis.requestPermission();

// Tag the device for Nuntis Segments.
Nuntis.User.addTag('plan', 'vip');
Nuntis.User.addTags({ plan: 'vip', region: 'br' });
Nuntis.User.removeTag('plan');
Nuntis.User.removeTags(['plan', 'region']);

// Associate the device with your own user id.
Nuntis.login('external-user-123');
Nuntis.logout();

// Enable/disable delivery without unregistering the device.
Nuntis.setSubscription(true);

// React to incoming/clicked notifications in-app.
const received = Nuntis.addEventListener('notificationReceived', (payload) => {
  console.log(payload.title, payload.body, payload.data);
});
const clicked = Nuntis.addEventListener('notificationClicked', (payload) => {
  console.log(payload.title, payload.body, payload.data);
});

// Call .remove() on the returned subscription when you're done listening
// (e.g. in a useEffect cleanup function).
received.remove();
clicked.remove();
```

### API reference

| Method | Description |
| --- | --- |
| `Nuntis.initialize(appId, clientKey, baseUrl)` | Registers the device with your Nuntis instance. Safe to call multiple times — a repeat call with the same `appId`/`clientKey` is a no-op. Never throws: missing/invalid arguments or a missing native push prerequisite (no `google-services.json`, no APNs capability) are logged, not thrown. |
| `Nuntis.requestPermission(): Promise<boolean>` | Triggers the native OS push-permission prompt. Resolves `true` immediately on Android below API 33 (no runtime permission exists there). Must be called after `initialize()` has run at least once. |
| `Nuntis.User.addTag(key, value)` / `Nuntis.User.addTags(tags)` | Merges tag(s) into the device's tag map and persists the full resulting map server-side. |
| `Nuntis.User.removeTag(key)` / `Nuntis.User.removeTags(keys)` | Removes tag key(s) from the device's tag map. |
| `Nuntis.login(externalUserId)` | Associates the device with your own user id. |
| `Nuntis.logout()` | Clears the external user id locally. Note: Nuntis' backend doesn't support clearing `external_user_id` server-side, so the previously-set value remains on the Device row server-side — `logout()` only affects local SDK state. |
| `Nuntis.setSubscription(enabled)` | Enables/disables push delivery for the device without unregistering it. |
| `Nuntis.addEventListener(eventName, callback)` | Subscribes to `'notificationReceived'` (foreground) or `'notificationClicked'` (any app state, including cold start). Returns an `EventSubscription` — call `.remove()` to unsubscribe. |

All tag/external-id/subscription mutations are serialized client-side (one in-flight network call at a time, last-write-wins on the merged local state) — calling them back-to-back is safe.

## Bare React Native setup

The Expo config plugin (below) automates all of this on `expo prebuild`. For a bare RN project, do it by hand:

### Android

1. Place your Nuntis App's `google-services.json` at `android/app/google-services.json` in your app (not this library).
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
     NuntisBridge.didRegisterForRemoteNotifications(deviceToken: deviceToken)
   }

   func application(
     _ application: UIApplication,
     didFailToRegisterForRemoteNotificationsWithError error: Error
   ) {
     NuntisBridge.didFailToRegisterForRemoteNotifications(error)
   }

   func application(
     _ application: UIApplication,
     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
   ) -> Bool {
     UNUserNotificationCenter.current().delegate = NuntisPushDelegate.shared
     // ... your existing launch code
     return true
   }
   ```

Without this forwarding, the device token never reaches the SDK and `notificationReceived`/`notificationClicked` never fire — `initialize()` still registers the device (with a `subscribed: false` state) but push delivery won't complete until the callbacks are wired.

## Expo setup

Add the config plugin to your `app.json`/`app.config.js`:

```json
{
  "expo": {
    "plugins": ["react-native-nuntis"]
  }
}
```

On `expo prebuild`, the plugin:

- **Android**: applies the Google Services Gradle plugin and copies your `google-services.json` (set via `android.googleServicesFile` in your Expo config, standard Expo convention).
- **iOS**: adds the `aps-environment` (push notifications) entitlement.

The Android runtime-permission declaration and the iOS `AppDelegate` forwarding above still apply the same way in an Expo dev client/prebuild project — the plugin only handles native project *configuration*, not the `AppDelegate` code path (Expo doesn't generate a customizable `AppDelegate` by default under managed workflow config plugins for this).

## Manual smoke testing

`example/` is a bare RN app wired against the real SDK (`example/src/App.tsx`) with placeholder credentials. To exercise it end-to-end against a running Nuntis instance:

1. Replace the `NUNTIS_APP_ID`/`NUNTIS_CLIENT_KEY`/`NUNTIS_BASE_URL` placeholders in `example/src/App.tsx` with a real App's values (never commit real values).
2. Drop your own `google-services.json` at `example/android/app/google-services.json` (gitignored).
3. Run `pnpm example android` / `pnpm example ios`, or `pnpm run build:android` / `pnpm run build:ios` for a release-shaped build.
4. Tap the example screen's buttons and confirm a new Device row appears in Nuntis' admin screen, tags/subscription reflect your taps, and notifications sent from Nuntis trigger the `notificationReceived`/`notificationClicked` console logs.

## Sanity gate

Before shipping a change, all of the following must pass:

```sh
pnpm typecheck && pnpm lint && pnpm test && pnpm run build:android && pnpm run build:ios
```

## Contributing

- [Development workflow](CONTRIBUTING.md#development-workflow)
- [Sending a pull request](CONTRIBUTING.md#sending-a-pull-request)
- [Code of conduct](CODE_OF_CONDUCT.md)

## License

MIT

---

Made with [create-react-native-library](https://github.com/callstack/react-native-builder-bob)
