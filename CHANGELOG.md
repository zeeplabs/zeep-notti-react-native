# Changelog

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
