# Changelog

# [0.8.0](https://github.com/zeeplabs/zeep-notti-react-native/compare/v0.7.0...v0.8.0) (2026-10-23)


### Bug Fixes

* **core:** keep only the latest login or logout queued before registration ([#41](https://github.com/zeeplabs/zeep-notti-react-native/issues/41)) ([3b063c4](https://github.com/zeeplabs/zeep-notti-react-native/commit/3b063c49bc9d9c4f12600b792d27550c8eb7a9f9))


### Features

* **core:** clear external_user_id server-side on logout ([#40](https://github.com/zeeplabs/zeep-notti-react-native/issues/40)) ([96f0500](https://github.com/zeeplabs/zeep-notti-react-native/commit/96f05002888aaa7a2cd55960e8500f0e752b8c48))

# [0.7.0](https://github.com/zeeplabs/zeep-notti-react-native/compare/v0.6.0...v0.7.0) (2026-10-23)


### Bug Fixes

* **android:** bound In-App image decode memory and survive decode errors ([cd14ee4](https://github.com/zeeplabs/zeep-notti-react-native/commit/cd14ee44528e0991bdbf3f20dd7989be83fcf801))
* **android:** bound In-App response bodies and ignore the events body ([c0d471f](https://github.com/zeeplabs/zeep-notti-react-native/commit/c0d471f94bde30f4cb40ab644283cc3a0d0553c4))
* **android:** open app details for push permission below API 26 ([ab26f7d](https://github.com/zeeplabs/zeep-notti-react-native/commit/ab26f7d35b8b626ae8de97b37792ef9fbfc153a7))
* **core:** re-send profile fields when registration answers with a new device id ([9c5af1d](https://github.com/zeeplabs/zeep-notti-react-native/commit/9c5af1d689fe6fb1556a55eb9c40217aff8cbb6b))
* **inapp:** fetch eligible only after this process registered and across a 429 pause ([14a4901](https://github.com/zeeplabs/zeep-notti-react-native/commit/14a4901c4748aadd7fc96b708d48d9a202a1ebb7))
* **inapp:** keep the buttons reachable when they exceed the card height ([1265833](https://github.com/zeeplabs/zeep-notti-react-native/commit/1265833764761009592d969408bd025c8adfddbe))
* **inapp:** refine the card image, close control and button layout ([ae47972](https://github.com/zeeplabs/zeep-notti-react-native/commit/ae4797239d57072dc2fd5a50ae5bbee7b5f31382))
* **inapp:** type the click action as present and nullable ([11541d1](https://github.com/zeeplabs/zeep-notti-react-native/commit/11541d143c59802cb04af7e212668b381ed8ec56))
* **ios:** honor EXIF orientation for small In-App images ([6660fb4](https://github.com/zeeplabs/zeep-notti-react-native/commit/6660fb4a9143c5e29e574c6429468cf47497efdf))
* **ios:** set the push permission port on the main thread ([396d320](https://github.com/zeeplabs/zeep-notti-react-native/commit/396d320226467a8f4448251d8f84e79bdec38e94))
* **js:** send sdk_version from a literal instead of a package self-require ([bd9bea9](https://github.com/zeeplabs/zeep-notti-react-native/commit/bd9bea9d1f08d257031d899268978d463f478b58))


### Features

* add Notti.trackEvent and the in-app click listener to the JS facade and Codegen spec ([fdf3085](https://github.com/zeeplabs/zeep-notti-react-native/commit/fdf308504ceba1094464b20c0c44c0b6bccd0170))
* **android:** add in-app coordinator for session fetch and event flush ([8a8a4cb](https://github.com/zeeplabs/zeep-notti-react-native/commit/8a8a4cb094a8cd4a85922799ac3b2d500f9f32d0))
* **android:** add in-app eligible and events requests ([9583b9a](https://github.com/zeeplabs/zeep-notti-react-native/commit/9583b9a479cc10e13b7b2c61c72a32e6d44b0fff))
* **android:** add in-app gestures, taps and accessibility ([c054d40](https://github.com/zeeplabs/zeep-notti-react-native/commit/c054d40992831a91cffd1d76247c31227a5e2655))
* **android:** add in-app selection state machine and display clock ([c218cfd](https://github.com/zeeplabs/zeep-notti-react-native/commit/c218cfde6da12e7ca3886f0ffe9f3a7c58176001))
* **android:** add in-app style resolver and layout metrics ([17e6710](https://github.com/zeeplabs/zeep-notti-react-native/commit/17e67109697908cd53f6428e21bfc01f74a84865))
* **android:** add persisted in-app event queue ([3930739](https://github.com/zeeplabs/zeep-notti-react-native/commit/3930739422dc3dece58b65ece83755fed15788ac))
* **android:** deliver in-app clicks to the JS listener without opening links ([77f840d](https://github.com/zeeplabs/zeep-notti-react-native/commit/77f840df7bdc4e5cb1a733a8744a739cb0652d2c))
* **android:** load in-app images with bounded credential-free requests ([ecbeac4](https://github.com/zeeplabs/zeep-notti-react-native/commit/ecbeac43f35b95e8a22d14d2b866ee0a3715007f))
* **android:** parse in-app eligible messages tolerantly ([e607484](https://github.com/zeeplabs/zeep-notti-react-native/commit/e607484cc55eb0be021eacb791271369eaad32af))
* **android:** present in-app messages over the resumed activity ([f816dfb](https://github.com/zeeplabs/zeep-notti-react-native/commit/f816dfbd69718f476a6d33ed7dcf3abd4cf1d9ca))
* **android:** render in-app message layouts with native views ([e71ec23](https://github.com/zeeplabs/zeep-notti-react-native/commit/e71ec23a94d78a87e39f0c2849c563dbe5e61501))
* **android:** run the push_permission action with an injected provider ([a5bc329](https://github.com/zeeplabs/zeep-notti-react-native/commit/a5bc3293c8015994feb30f1aa58d403f2d526086))
* **android:** wire in-app messages into session, registration and trackEvent ([3d910eb](https://github.com/zeeplabs/zeep-notti-react-native/commit/3d910eb9f99a7c5ccf800152b899cd94ffba0fff))
* **example:** add a trackEvent button and click listener for in-app message testing ([dda1994](https://github.com/zeeplabs/zeep-notti-react-native/commit/dda199459755d333e30674cdd49cdfd88410ac73))
* **inapp:** parse push_permission buttons and run an injectable port after the click ([8640894](https://github.com/zeeplabs/zeep-notti-react-native/commit/86408940037a9f4b7b97f981a5cc36cc34a8dd1d))
* **ios:** add in-app coordinator for session fetch and event flush ([add1c56](https://github.com/zeeplabs/zeep-notti-react-native/commit/add1c569aadf17eff472a1b48a4090f77ad9ad74))
* **ios:** add in-app eligible and events requests ([b09942c](https://github.com/zeeplabs/zeep-notti-react-native/commit/b09942ce5688bc88c024a3b2babb81724f3583ca))
* **ios:** add in-app gestures, taps and accessibility ([8ac35de](https://github.com/zeeplabs/zeep-notti-react-native/commit/8ac35dee30bfefaa4168f6969fca4f12ab32d1f9))
* **ios:** add in-app selection state machine and display clock ([03c8f1a](https://github.com/zeeplabs/zeep-notti-react-native/commit/03c8f1a62a3147b36bc178a94d2293c4ffa3018f))
* **ios:** add in-app style resolver and layout metrics ([f1011e4](https://github.com/zeeplabs/zeep-notti-react-native/commit/f1011e492a0f0d552b9c1e9c7b8199df02344e18))
* **ios:** add persisted in-app event queue ([c583758](https://github.com/zeeplabs/zeep-notti-react-native/commit/c583758e1a35c714459528a575a395cdf0ca9c32))
* **ios:** deliver in-app clicks to the JS listener without opening links ([eb5743a](https://github.com/zeeplabs/zeep-notti-react-native/commit/eb5743a2e12866a49b55923ce0d23b32fec2755f))
* **ios:** load in-app images with bounded credential-free requests ([99fb8c7](https://github.com/zeeplabs/zeep-notti-react-native/commit/99fb8c721a7b2327fe818d6098563b06beb49cae))
* **ios:** parse in-app eligible messages tolerantly ([1baf62e](https://github.com/zeeplabs/zeep-notti-react-native/commit/1baf62e54299d60c5ed594462f3a7fda4bfe11e4))
* **ios:** present in-app messages in a dedicated window ([49799bc](https://github.com/zeeplabs/zeep-notti-react-native/commit/49799bc961f68cda4e499e4789721703b17049a8))
* **ios:** render in-app message layouts with UIKit ([3933b75](https://github.com/zeeplabs/zeep-notti-react-native/commit/3933b75cf8bf8af12ff056607cf85ee48f24f8e6))
* **ios:** run the push_permission action with injected ports ([2b2a1c3](https://github.com/zeeplabs/zeep-notti-react-native/commit/2b2a1c3f3770340b6efae508ae657a470cb8cab3))
* **ios:** wire in-app messages into session, registration and trackEvent ([74200be](https://github.com/zeeplabs/zeep-notti-react-native/commit/74200bec80ae5e351407b67ca1cbd492cffa3264))
* narrow the in-app click action type to url or deeplink ([34d4368](https://github.com/zeeplabs/zeep-notti-react-native/commit/34d43686afb76f205828da1c37e9e954cf76e78d))
* **plugin:** set the Android notification icon and color ([#39](https://github.com/zeeplabs/zeep-notti-react-native/issues/39)) ([760dcd1](https://github.com/zeeplabs/zeep-notti-react-native/commit/760dcd1b4f54fcdc1d8a6869019ac9a885b9fe60))

# [0.6.0](https://github.com/zeeplabs/zeep-notti-react-native/compare/v0.5.0...v0.6.0) (2026-10-04)


### Bug Fixes

* **android:** ack profile fields only when the PATCH response echoes them ([c3a02ac](https://github.com/zeeplabs/zeep-notti-react-native/commit/c3a02aca21387fa61ba5eddc3a336673a8a58574))
* **android:** re-sync profile fields once on upgrade from 0.5.0 ([f65247b](https://github.com/zeeplabs/zeep-notti-react-native/commit/f65247bf73cdc72d33a1902ba2d8da21d13c28b1))
* **ios:** ack profile fields only when the PATCH response echoes them ([6c86e0e](https://github.com/zeeplabs/zeep-notti-react-native/commit/6c86e0e1c94376b14c31b4ea30056f88ba37de20))
* **ios:** re-sync profile fields once on upgrade from 0.5.0 ([3df5b13](https://github.com/zeeplabs/zeep-notti-react-native/commit/3df5b130f7e426e936a30c9bfda45d6de8cfa4e1))


### Features

* **android:** report notification body tap as opened ([6923f96](https://github.com/zeeplabs/zeep-notti-react-native/commit/6923f96ceae662c3d4284ba51697dda465bcaa9f))
* **ios:** report body tap as opened and action buttons as clicked ([39b8582](https://github.com/zeeplabs/zeep-notti-react-native/commit/39b8582a799c784f8ab5d02492cf2ba99471220e))
* report body tap as both opened and clicked ([12d0d45](https://github.com/zeeplabs/zeep-notti-react-native/commit/12d0d45c981bb308694dbb2fd9eca8f5d9842aa0))

# [0.5.0](https://github.com/zeeplabs/zeep-notti-react-native/compare/v0.4.0...v0.5.0) (2026-10-04)


### Bug Fixes

* address follow-up review findings on unsubscribe stamps and permission status ([29caa6c](https://github.com/zeeplabs/zeep-notti-react-native/commit/29caa6cce0beb13a14ad84c495526080ccce68b8))
* **android:** address device-profile-fields pre-release review findings ([030708f](https://github.com/zeeplabs/zeep-notti-react-native/commit/030708f39a8f8c687667015f1ccb94662d0d8b4d))
* **ios,android:** close cross-platform review gaps ([292e129](https://github.com/zeeplabs/zeep-notti-react-native/commit/292e129e896c1b4739fcbe55ed5839de8d0ae942))
* **ios:** address device-profile-fields pre-release review findings ([3f4a26f](https://github.com/zeeplabs/zeep-notti-react-native/commit/3f4a26fa31a5be40dc83d7f47cd6d77985296928))
* **ios:** re-read apiClient in async permission sync after re-initialize ([511ada4](https://github.com/zeeplabs/zeep-notti-react-native/commit/511ada4da4dd46ebd7dff5d9b34b028b0c8fce1e))


### Features

* add device-profile-fields spec, design and tasks ([14666dd](https://github.com/zeeplabs/zeep-notti-react-native/commit/14666ddfd890f884a054b95910266e8f6bfd1196))
* **android:** add device-profile fields to NottiDeviceStore ([16d63b2](https://github.com/zeeplabs/zeep-notti-react-native/commit/16d63b269e2a88ca78130b4688c5f1cb114916cb))
* **android:** add first-class email/phone set and clear ([1759316](https://github.com/zeeplabs/zeep-notti-react-native/commit/17593161519fb8c082d2ef819748c40ffdf03c84))
* **android:** sync device profile fields via generalized PATCH ([15b3313](https://github.com/zeeplabs/zeep-notti-react-native/commit/15b3313beaea0da3f52ef41863522a9029675d88))
* **android:** sync permission status and last-unsubscribe timestamp ([461d223](https://github.com/zeeplabs/zeep-notti-react-native/commit/461d2234620ebafd0c1216f7a8f02bfb0e5e5019))
* **ios:** add device-profile fields to NottiDeviceStore ([1bb0353](https://github.com/zeeplabs/zeep-notti-react-native/commit/1bb03532450155b7330693ef0eae08249728b6c2))
* **ios:** add first-class email/phone set and clear ([7e5c598](https://github.com/zeeplabs/zeep-notti-react-native/commit/7e5c598a531eacb4193d66e6ba44b515ddf90328))
* **ios:** sync device profile fields via generalized PATCH ([5d04c21](https://github.com/zeeplabs/zeep-notti-react-native/commit/5d04c218ca097b701e818e2ce7d6b03b154b4626))
* **ios:** sync permission status and last-unsubscribe timestamp ([a958356](https://github.com/zeeplabs/zeep-notti-react-native/commit/a958356aa45b89b9434d791205f7d068c0c8d352))
* **js:** add email/phone setters and thread sdk_version through initialize ([c6fc3f5](https://github.com/zeeplabs/zeep-notti-react-native/commit/c6fc3f59902e85291ed6967c3a4d0220b5b75808))

# [0.4.0](https://github.com/zeeplabs/zeep-notti-react-native/compare/v0.3.0...v0.4.0) (2026-10-02)


### Bug Fixes

* address pre-release review findings (rich push blockers + cross-platform bugs) ([b621e2e](https://github.com/zeeplabs/zeep-notti-react-native/commit/b621e2e829b4616a9c0c9dfc22325abbe3eea99f))
* address round-3 pre-release review findings (LGPD, CTR, privacy manifest) ([b0836ed](https://github.com/zeeplabs/zeep-notti-react-native/commit/b0836edaecd10defe1a5011299d8955ab9835dd1))
* address second-round pre-release review findings ([3fa3f8b](https://github.com/zeeplabs/zeep-notti-react-native/commit/3fa3f8ba3b54de86b6584830ef4c0210149ab31e))
* **android:** address pre-release review findings for CTR and telemetry ([6a0a615](https://github.com/zeeplabs/zeep-notti-react-native/commit/6a0a6157f0a130252792d1688ebefbb650772e8a))
* drop queued events on terminal 4xx report, per SDKCTR-11 ([aed1512](https://github.com/zeeplabs/zeep-notti-react-native/commit/aed15121ee6a8ffd5e8cc65be53e120368d06020))
* **ios:** address pre-release review findings for CTR and telemetry ([1014115](https://github.com/zeeplabs/zeep-notti-react-native/commit/10141153b404ac5afca90e3bd3343d10f5786777))
* **ios:** declare CoreLocation framework in podspec ([60389ee](https://github.com/zeeplabs/zeep-notti-react-native/commit/60389eec804cc723e86dbc3fecd59ba72e388d09))


### Features

* add iOS rich push via Notification Service Extension subspec ([c5dfc29](https://github.com/zeeplabs/zeep-notti-react-native/commit/c5dfc2996a3b196a2c14b4f5fd266c91036cdca3))
* add notification-action-buttons spec ([3197bab](https://github.com/zeeplabs/zeep-notti-react-native/commit/3197bab7f1c5498dbebbf364cc9d715646ca7830))
* add segment-telemetry-reporting spec, design, and tasks ([82eacd9](https://github.com/zeeplabs/zeep-notti-react-native/commit/82eacd9c0daa6dfdab9c8fe85cd6f74ad4cab296))
* **android:** add NottiApiClient.reportEvent with shared retry logic ([33717bb](https://github.com/zeeplabs/zeep-notti-react-native/commit/33717bba9729a705bb1f69eff73ac683b9a3d04e))
* **android:** add NottiCore.flushEventQueue and wire into foreground/registration triggers ([5d2f7cb](https://github.com/zeeplabs/zeep-notti-react-native/commit/5d2f7cb7c1559990af41a285e6933e4fadf47d76))
* **android:** add NottiEventStore for offline event persistence ([cabfb88](https://github.com/zeeplabs/zeep-notti-react-native/commit/cabfb881581abf86e3c6ef1b0dad4ef1f0527f61))
* **android:** add opt-in country reporting with explicit clear ([7437079](https://github.com/zeeplabs/zeep-notti-react-native/commit/7437079bb0f32773ecebeaabc37fe2ddcbc4f0ad))
* **android:** add telemetry fields to NottiDeviceStore ([c4cb5d7](https://github.com/zeeplabs/zeep-notti-react-native/commit/c4cb5d71c77ff499548cb6630224a452b382b949))
* **android:** sync app version via device PATCH on change ([db00399](https://github.com/zeeplabs/zeep-notti-react-native/commit/db0039918aca359eef891af8a75f1102b5373cd8))
* **android:** track session lifecycle with persisted aggregate ([6b77b1a](https://github.com/zeeplabs/zeep-notti-react-native/commit/6b77b1a6308d0bed6d504b3d0d9c199fcd8abab2))
* **android:** wire event detection, enqueue, and network-triggered flush ([eb74c5c](https://github.com/zeeplabs/zeep-notti-react-native/commit/eb74c5c7d49287109b1e4610bf0626e12ef9b842))
* create spec by ctr feature ([d5eeb15](https://github.com/zeeplabs/zeep-notti-react-native/commit/d5eeb15e3c8b22f18ca2a3b6f01fa1409be5cb6c))
* **ios:** add NottiApiClient.reportEvent with shared retry logic ([2ddad8a](https://github.com/zeeplabs/zeep-notti-react-native/commit/2ddad8a524bf02ae4d00b9630e0ca4506f399b68))
* **ios:** add NottiCore.flushEventQueue and wire into triggers ([aca2466](https://github.com/zeeplabs/zeep-notti-react-native/commit/aca246693b4a029de775aee026cedf3c94fdb68e))
* **ios:** add NottiEventStore for offline event persistence ([17cb7c3](https://github.com/zeeplabs/zeep-notti-react-native/commit/17cb7c335b3f0a116f6870857f89c6b17a088d9e))
* **ios:** add opt-in country reporting with explicit clear ([dccf877](https://github.com/zeeplabs/zeep-notti-react-native/commit/dccf87756cec71c1b633f080e70d51bd2a756385))
* **ios:** add telemetry fields to NottiDeviceStore ([c2e3804](https://github.com/zeeplabs/zeep-notti-react-native/commit/c2e3804344d414c58d86dd6c9c432eb0d8ca32f8))
* **ios:** sync app version via device PATCH on change ([feab0e6](https://github.com/zeeplabs/zeep-notti-react-native/commit/feab0e6e87e16ee7f9d9fe64013545345520f912))
* **ios:** track session lifecycle with persisted aggregate ([4f7ce63](https://github.com/zeeplabs/zeep-notti-react-native/commit/4f7ce6340f2b00b2aa63bd418bc8cfb94407eaed))
* **ios:** wire event detection, enqueue, and network-triggered flush ([3f1c938](https://github.com/zeeplabs/zeep-notti-react-native/commit/3f1c9388f389aedf650dad10f55eb1d67e60ff87))
* **js:** expose setLocationSharingEnabled opt-in toggle ([981bb92](https://github.com/zeeplabs/zeep-notti-react-native/commit/981bb92ea127a01dc12d3648f482797359452533))

# [0.3.0](https://github.com/zeeplabs/zeep-notti-react-native/compare/v0.2.0...v0.3.0) (2026-09-27)


### Bug Fixes

* harden device id feature per pre-release review ([c318516](https://github.com/zeeplabs/zeep-notti-react-native/commit/c318516396bab03fdb357dff56156ed9fa0b6712))


### Features

* expose device id via getDeviceId() and deviceIdChanged event ([c29fc79](https://github.com/zeeplabs/zeep-notti-react-native/commit/c29fc79d4fd48d6096869e0def43317e1f414bfe))

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries below `[Unreleased]` are generated automatically by `pnpm release`
([release-it](https://github.com/release-it/release-it) +
[conventional-changelog](https://github.com/release-it/conventional-changelog),
Angular preset) from Conventional Commit messages — do not hand-edit past
entries once released.

## [Unreleased]

### Bug Fixes

* **iOS builds with `use_frameworks!` (static or dynamic linkage) compile again.** 0.8.0 failed with `'Notti-Swift.h' file not found` in `Notti.mm` when the app's Podfile uses `use_frameworks!`, which Firebase iOS and Expo's `useFrameworks` require. No API change and nothing to do in your app beyond upgrading. Apps building with static libraries (the default) were not affected.

## Upgrade notes for 0.8.0 (released)

### Features

* **`Notti.logout()` unlinks the device from the user on the backend** (Android and iOS): it now also sends `external_user_id: null`, so pushes your backend sends to the signed-out user by `external_user_ids` stop reaching the device (shared phones). Tags and the subscription are kept. The clear is durable: if it fails, runs offline or before `initialize()`, it is re-sent at the next registration. No API change.

### Notes

* Requires a Notti backend that accepts `external_user_id: null` on `PATCH /devices/{id}`. An older backend reads it as an empty value and keeps the stored id; nothing breaks and the SDK does not retry.
* New local storage key `notti_pending_external_user_id_clear` (a flag, no personal data).
* `login()`/`logout()` calls made before the first device registration now collapse to the latest one (previously every queued `login` was sent in order), so a `logout()` → `login("u2")` → `logout()` sequence on a fresh install ends unlinked.

## Upgrade notes for 0.7.0 (released)

### Features

* **In-App messages** (Android and iOS): messages authored in the Notti dashboard are fetched once per foreground session, rendered natively (`top`, `center`, `bottom`, `full`) and measured with `impression`, `click` and `dismiss` events queued on disk. New: `Notti.trackEvent(name)` and `Notti.InAppMessages.addClickListener(handler)`; additive, no existing signature changes. Requires a Notti backend with In-App rich messages.
* **The SDK never opens a link.** A tap reports the click, closes the message and hands the untouched `url`/`deeplink` to the click listener; without a listener nothing opens. See the README "In-App messages" section.
* **Expo config plugin: Android notification icon and color.** New optional props `androidNotificationIcon` (PNG path) and `androidNotificationColor` (`#RRGGBB`) set FCM's `default_notification_icon` / `default_notification_color`. Without an icon Android keeps showing the launcher icon as a white silhouette. Bare React Native: see the new README section "Android notification icon, color and image" (manifest `<meta-data>`, FCM's 1 MB image limit).

### Notes

* **Deliberate divergence from the backend contract:** on `403` from the In-App routes the SDK does **not** re-register the device (the contract says to). It logs one fixed warning per session per route and In-App stays inactive on that device until the next registration (cold start or token refresh). A `401` stops In-App for the session without re-registering and logs only the generic line. Registration already runs at launch and on token refresh, and a rejected client key is not fixed by registering again.
* New local storage key `notti_pending_inapp_events` and a new request to the image host chosen by the message author; see "Data collected by the SDK" and "Locally persisted data" in the README.

## Upgrade notes for 0.6.0 (released)

### ⚠️ Attention when upgrading

* **Requires `zeep-notti` backend ≥ v0.11.0** to record `opened` (see Notes below).
* **iOS CTR step-up for apps with notification categories:** taps on action buttons were not reported in 0.5.0 and are now reported as `clicked`, which Notti counts as clicked and opened. Apps that register `UNNotificationCategory` actions will see CTR and open rate rise after the upgrade; this is a reporting change, not a behavior change of users. Account for it when comparing against pre-0.6.0 data.
* **One-time profile re-sync:** on the first registration after the upgrade, each install re-sends `app_version`, `device_os`, `device_model`, `sdk_version`, `timezone_id` and `language` once (at most six device `PATCH`es, once per install). This repairs installs where 0.5.0 marked a field synced against a backend that had ignored it (the 0.5.0 note below).

### Features

* **`opened` event:** a tap on the notification body (warm or cold start) now reports `opened` **and** `clicked` for the delivery (`.specs/features/opened-event-reporting`). CTR keeps its meaning: body taps are still clicks, exactly as in 0.5.0. With Notti's current formulas (opened = `opened` or `clicked`) open rate equals CTR; the `opened` rows let Notti tell body taps from action-button taps. SDK 0.5.0 and older send only `clicked` on a body tap, which Notti already counts as opened. JS API unchanged (`notificationClicked` / `getInitialNotificationClick()` still fire for the body tap).
* **iOS:** a tap on an action button from a `UNNotificationCategory` the app registered is reported as `clicked` only (no JS event). Dismissals are still not reported.

### Bug Fixes

* **Profile fields are acknowledged by the backend echo** (Android and iOS): `app_version`, `device_os`, `device_model`, `sdk_version`, `timezone_id` and `language` are marked synced only when the `PATCH /devices` response echoes the exact value sent. Previously any 2xx counted, so a backend that ignored a field never received it again. A field that is not echoed (older backend) is re-sent on the next registration (app launch, token refresh, or retry after a failed registration).

### Notes

* Requires `zeep-notti` **v0.11.0 or later** to record `opened`. An older backend answers `422` to `opened` and the SDK drops that event; the `clicked` of the same tap is still recorded.
* A body tap now writes two events to the on-disk queue (`opened` + `clicked`), so the 32-event cap holds 16 offline body taps instead of 32. When the cap is exceeded the oldest event is dropped, which can leave a `clicked` without its `opened`; Notti already counts `clicked` as opened, so rates are unaffected.

## Upgrade notes for 0.5.0 (released)

### ⚠️ Breaking / attention when upgrading

* **Requires `zeep-notti` backend ≥ v0.10.0** (DPROF-01..17). Older backends ignore the new device fields, but the SDK still marks them as synced on any 2xx, so static values (`device_model`, `device_os`, `sdk_version`) are not re-sent after the backend is upgraded until they change. *Fixed in 0.6.0: echo-based ack plus a one-time re-sync on upgrade.*
* **Automatic device profile:** this release starts sending `device_os`, `device_model`, `sdk_version`, `timezone_id`, `language`, `permission_status` and `last_unsubscribed_at` to your Notti instance, with no opt-out toggle. Review your privacy labels / LGPD documentation (README "Privacy, App Store labels and LGPD").
* **`logout()` now clears email and phone** locally and server-side (two device PATCHes, `{email: null}` and `{phone: null}`), so a previous user's contact data never stays attached to the next user on a shared device. Call `User.setEmail`/`User.setPhone` again after the next `login`.
* **iOS privacy manifest:** `PrivacyInfo.xcprivacy` now declares Email Address and Phone Number (linked to the user, not used for tracking, App Functionality). Data is only collected if you call `User.setEmail`/`User.setPhone`, but Xcode's privacy report lists the entries for every app embedding the SDK; adjust your own nutrition label to your actual use.

### Features

* **`Notti.User.setEmail` / `clearEmail` / `setPhone` / `clearPhone`** (new JS API): first-class email and phone attributes on the device row, never merged into tags. A clear is durable: the last value acknowledged by the backend is persisted, and a clear that could not complete (called before `initialize`, offline, process killed, server error) is re-sent as an explicit `null` on the next registration.

### Bug Fixes

* **iOS:** coalesced mutations (telemetry and email/phone set/clear) no longer count toward the 32-entry pre-registration queue limit and are never evicted, matching Android; a full queue now drops the oldest non-coalesced mutation.
* **Android:** `language` is normalized to the ISO 639-1 primary subtag (legacy `iw`/`in`/`ji` mapped to `he`/`id`/`yi`; empty/`und` omitted). iOS sends the primary subtag only.
* **Android 13+:** `permission_status` no longer reports `denied` for a device that was never asked, and reports `denied` when notifications are blocked in Settings even if the runtime permission is still granted.
* **Android and iOS:** `last_unsubscribed_at` is recorded on the first `setSubscription(false)` even when the permission was requested outside the SDK, and a retried transition re-sends the timestamp of when it was detected instead of a fresh one.

### Known limitations

* **Android 13+ `permission_status`:** "never asked" vs "denied" is inferred from whether the SDK's `requestPermission` ran and from `shouldShowRequestPermissionRationale`. If you request `POST_NOTIFICATIONS` through another library and the user permanently denies it, the device may report `notDetermined`. Without an Activity (background registration) an undecidable state is omitted. Dismissing the SDK's dialog without a choice reports `denied`.

## Upgrade notes for 0.4.0 (released)

### ⚠️ Breaking / attention when upgrading

* **TypeScript:** `NotificationPayload.title` and `NotificationPayload.body` are now typed `string | null` (still optional). Both platforms already delivered `null` for a missing value at runtime; code comparing with `=== undefined` must switch to `== null` / `??`.
* **iOS / CocoaPods:** `Notti.podspec` is split into subspecs `Notti/Core` (Turbo Module, `default_subspec`) and `Notti/NotificationServiceExtension`. Plain `pod 'Notti'` and autolinking keep resolving to `Core`; Podfiles that pin subspecs explicitly must include `Core` in the app target.
* **iOS / CocoaPods:** `Notti/Core` now links `CoreLocation`. App Store Connect may warn about a missing `NSLocationWhenInUseUsageDescription` (ITMS-90683) even if country reporting is never enabled; see README.
* **Expo plugin:** without an explicit `apsEnvironment` prop, only the EAS profile named exactly `production` gets `aps-environment=production`; every other profile (including `preview`) and non-EAS prebuilds get `development`. Ad hoc/internal builds should pin the prop per profile — see README "Expo setup".
* **Automatic telemetry:** this release starts sending notification events, app version and session aggregates to your Notti instance with no opt-out toggle. Review your privacy labels / LGPD documentation before shipping (README "Privacy, App Store labels and LGPD").
* **Retry policy:** HTTP `408` and `429` are now treated as transient instead of terminal in the shared retry loop (`executeWithRetry`), which applies to device registration, every device `PATCH` and CTR events alike: up to 5 attempts with exponential backoff (2s, 4s, 8s, 16s between attempts); a CTR event that exhausts them stays queued. Other `4xx` remain terminal. `Retry-After` is not honored.
* **No reliable acknowledgement for `app_version`:** the backend accepts the telemetry fields since `zeep-notti` v0.9.0 (DEVTEL-01..13), but the device PATCH response does not echo `app_version` back, so the SDK marks it as synced on any 2xx and does not re-send it until the value changes. See README "Known limitations".

### Features

* **iOS rich push** via a Notification Service Extension helper (`Notti/NotificationServiceExtension` subspec, no React dependency): attaches the media from `notti_image_url`; https only (re-checked after redirects), 10 MB download cap, attachment type allowlist (`jpg`, `png`, `gif`, `mp4`, `mp3`, MIME-type first), falls back to the original content on any failure.
* **CTR event reporting:** `received` (foreground) and `clicked` (default tap, including cold start) events reported automatically to `POST /v1/apps/{appId}/notifications/{notification_id}/events` when the push carries `notification_id` + `delivery_id`; write-ahead on-disk queue (max 32), up to 5 attempts with exponential backoff, flush on launch and on network reconnect.
* **Segment telemetry:** `app_version` synced on change; session aggregates (`first_session_at`, `last_session_at`, `session_count`, `session_time_seconds`) sent as a cumulative snapshot `PATCH` at each session end (immediately once the device is registered).
* **Session heartbeat:** while a session is open and the app is in the foreground, the last-foreground timestamp is persisted every 60s (`notti_last_foreground_at_ms` on Android, `notti_session_last_seen_at_ms` on iOS). A session orphaned by a force-quit/crash is closed at that timestamp on the next launch instead of at launch time; credited duration capped at 12h (Android) / 24h (iOS), 0s when no heartbeat exists.
* **Telemetry coalescing:** before registration completes, queued telemetry mutations (session, country, app version) are replaced by the newer one with the same key. Android: telemetry does not count toward the 32-entry pending-mutation limit and is never evicted. iOS: telemetry counts toward the limit and is evicted first when it is full.
* **`Notti.setLocationSharingEnabled(enabled)`** (new JS API, default `false`): opt-in country (ISO 3166-1 alpha-2) reporting from the last cached location fix, only when the host app already holds location permission; opt-out sends an explicit `country: null` clear tracked by a persisted `pendingCountryClear` flag (`notti_pending_country_clear`), cleared only on a 2xx and re-sent on registration, app foreground and network regain.

### Bug Fixes

* **Android and iOS:** process-wide session gate — an RN reload or a duplicate foreground signal no longer opens a second session for the same foreground (Android: `NottiModule.processSessionGate`; iOS: `NottiImpl.processSessionGate`, `NottiCore.SessionGate`, closed on `didEnterBackground`). After a JS reload with the app in the foreground, the new core adopts the persisted open session (no orphan close, `session_count` unchanged, heartbeat resumed). iOS: `NottiCore.invalidate()` (called from `NottiImpl.invalidate`) removes the old core's observers and stops its heartbeat, avoiding a double session end.
* **Android and iOS:** a country clear rejected with a permanent 4xx (401/403/404) now logs a distinct message (no personal data); the clear stays pending and is re-sent on the next trigger.
* **Android:** `NottiEventStore` read-modify-write operations (`enqueue`, `remove`, `all`) run under a process-wide lock, so concurrent enqueue/flush can no longer lose or resurrect queued events.

### Other

* npm package no longer ships native test sources (`android/src/test`, `ios/Tests`).
* CI runs the Notification Service Extension unit-test scheme.

# 0.2.0 (2026-09-24)

### Bug Fixes

* **android:** fall back to data payload for click title/body + add NuntisBridge ([bb0576a](https://github.com/zeeplabs/zeep-notti-react-native/commit/bb0576a639956b0cb2a5a7b5584ced6671243831))
* change code of conduct ([369b042](https://github.com/zeeplabs/zeep-notti-react-native/commit/369b042c8b3559a0cad3fffaacd3bf46b91b0eef))
* **ci:** widen iOS drain headroom and retry flaky test runs on CI ([#12](https://github.com/zeeplabs/zeep-notti-react-native/issues/12)) ([2ee87a2](https://github.com/zeeplabs/zeep-notti-react-native/commit/2ee87a25505da578fff26e5a0cce99d86f8e17b4))

### Features

* default initialize() baseUrl to Notti SaaS instance ([f70c88d](https://github.com/zeeplabs/zeep-notti-react-native/commit/f70c88db600b68d916cc7b3c282fb6d4e01b28c6))
* SDK Core v1 - Turbo Module client for Nuntis push registration ([#1](https://github.com/zeeplabs/zeep-notti-react-native/issues/1)) ([b09f06c](https://github.com/zeeplabs/zeep-notti-react-native/commit/b09f06c39aa72845782dc4b8d4869f3d6f29e0fb)), closes [String#untaint](https://github.com/String/issues/untaint)
