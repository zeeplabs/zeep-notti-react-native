# iOS on the Native SDK - Context (gray-area decisions)

Decided by Julio, 2026-10-31. Locked for Design and Tasks unless a spike proves one unworkable; then
record the change here and in `STATE.md`.

## G1 - APNs token and delegate capture: adopt `NottiSDK` swizzling

- `react-native-notti` relies on `NottiSDK`'s default swizzling (`+load`, iOS SDK AD-004/AD-010). The
  integrator no longer forwards anything from `AppDelegate`.
- `NottiBridge.didRegisterForRemoteNotifications(deviceToken:)`,
  `NottiBridge.didFailToRegisterForRemoteNotifications(_:)` and `NottiPushDelegate.shared` stay as
  deprecated symbols so 0.8.0 `AppDelegate` code still builds (NSDK-12). They must not register the
  token a second time or report a second `received`. Design decides between a pure no-op and forwarding
  that the SDK deduplicates.
- Consequence to document: `willPresent` follows the iOS SDK rule (AD-010 D2: with no host
  `willPresent`, only Notti pushes are presented in the foreground), not 0.8.0's
  `[.banner, .list, .sound, .badge]` for every notification. Upgrade notes must say so.
- Consequence for Expo: no `AppDelegate` step left for push capture.
- Open for Design: an integrator who sets `NottiPushDelegate.shared` as the center delegate would
  replace the SDK's delegate. Design must make that assignment harmless (for example, the deprecated
  object forwards to the SDK's delegate) and prove it with a test.

## G2 - NSE packaging: subspec becomes an alias

- `pod 'Notti/NotificationServiceExtension'` keeps working and depends on the `NottiSDKExtension` pod.
  It ships no Swift of its own.
- The integrator changes only the Swift `import` (`Notti` to `NottiSDKExtension`); call signatures are
  the same (iOS SDK AD-011). Design checks whether the subspec can re-export the module so even the
  import stays; if not, the upgrade note covers it.
- The subspec must never pull React or `NottiSDK` into the NSE target (iOS SDK AD-012).

## G3 - Distribution: trunk now, own spec repo later

- `NottiSDK` 0.2.0 (with the G4 hook) and `NottiSDKExtension` 0.2.0 go to the CocoaPods trunk before
  the read-only cutoff (about 2026-12-02, unconfirmed; read-only test window 2026-11-01..07). Releasing
  and `pod trunk push` stay with Julio.
- Versions after the cutoff go to an own spec repo (`zeeplabs/specs`). When that happens, the README
  adds the `source` line and the Expo plugin injects it. Not needed for this feature's release if 0.2.0
  lands on the trunk in time.
- `Notti.podspec` pins `NottiSDK` with `~> 0.2` (exact pin vs `~>` decided in Design).

## G4 - `sdk_version`: `@_spi(Wrapper)` hook in `NottiSDK`

- `NottiSDK` 0.2.0 adds an SPI entry point (for example `@_spi(Wrapper) Notti.initialize(appId:
  clientKey:options:sdkVersion:)`; final shape decided in the iOS SDK repo) that feeds `NottiCore`'s
  existing `sdkVersion`. Outside the public semver surface; `check-public-surface.sh` must keep passing.
- This repo imports it with `@_spi(Wrapper) import NottiSDK` and passes the JS-provided version.
- The same hook serves `zeep-notti-flutter` later.
- This is work in `zeep-notti-ios-sdk`, a prerequisite of NSDK-03. Track it there as its own change.

## Not decided yet (Design)

- Exact behavior of `initialize` called twice (0.8.0 vs iOS SDK AD-009), confirmed by reading both.
- Key audit (NSDK-10).
- Release number (0.9.0 breaking is the default assumption: the `AppDelegate` step and the NSE import
  change).
