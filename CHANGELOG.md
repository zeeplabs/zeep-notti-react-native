# Changelog

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

### ⚠️ Breaking / attention when upgrading

* **TypeScript:** `NotificationPayload.title` and `NotificationPayload.body` are now typed `string | null` (still optional). Both platforms already delivered `null` for a missing value at runtime; code comparing with `=== undefined` must switch to `== null` / `??`.
* **iOS / CocoaPods:** `Notti.podspec` is split into subspecs `Notti/Core` (Turbo Module, `default_subspec`) and `Notti/NotificationServiceExtension`. Plain `pod 'Notti'` and autolinking keep resolving to `Core`; Podfiles that pin subspecs explicitly must include `Core` in the app target.
* **iOS / CocoaPods:** `Notti/Core` now links `CoreLocation`. App Store Connect may warn about a missing `NSLocationWhenInUseUsageDescription` (ITMS-90683) even if country reporting is never enabled; see README.
* **Expo plugin:** without an explicit `apsEnvironment` prop, only the EAS profile named exactly `production` gets `aps-environment=production`; every other profile (including `preview`) and non-EAS prebuilds get `development`. Ad hoc/internal builds should pin the prop per profile — see README "Expo setup".
* **Automatic telemetry:** this release starts sending notification events, app version and session aggregates to your Notti instance with no opt-out toggle. Review your privacy labels / LGPD documentation before shipping (README "Privacy, App Store labels and LGPD").
* **Retry policy:** HTTP `408` and `429` are now treated as transient instead of terminal in the shared retry loop (`executeWithRetry`), which applies to device registration, every device `PATCH` and CTR events alike: up to 5 attempts with exponential backoff (2s, 4s, 8s, 16s between attempts); a CTR event that exhausts them stays queued. Other `4xx` remain terminal. `Retry-After` is not honored.
* **Telemetry not yet accepted by the backend:** until the Notti backend ships the device telemetry fields, it ignores `app_version`, session fields and `country` with HTTP 200; the SDK marks `app_version`/`country` as synced and does not re-send them until they change. See README "Known limitations".

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
