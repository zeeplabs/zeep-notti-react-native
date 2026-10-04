# Opened Event Reporting Tasks

**Spec**: `.specs/features/opened-event-reporting/spec.md`
**Design**: inline in the spec (Decisions D1-D4). No new component: only the
`type` chosen at the existing detection sites changes, plus shared constants
for the event type strings.

## Gate commands

| Layer | Command |
| --- | --- |
| Android | `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest` |
| iOS | `xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests -destination 'platform=iOS Simulator,name=iPhone 17'` |
| JS (sanity, `src/` untouched) | `pnpm typecheck && pnpm lint && pnpm test` |

## Execution plan

```
T1 (Android) ─┐
              ├──→ T3 (docs)
T2 (iOS)    ──┘
```

T1 and T2 never touch the same file.

---

### T1: Android — body tap reports `opened` [P]

**What**: Add `NottiEventType` constants (`received`, `opened`, `clicked`);
`NottiActivityLifecycleListener.handle` enqueues `opened` instead of
`clicked`; `NottiFirebaseMessagingService` uses the `received` constant.
**Where**: `android/src/main/java/com/notti/NottiEventStore.kt`,
`NottiActivityLifecycleListener.kt`, `NottiFirebaseMessagingService.kt`
**Requirement**: SDKOPEN-01, 02, 03, 04, 08, 09, 10
**Tests** (`android/src/test/java/com/notti/`):
- Lifecycle listener: warm tap with ids → one `opened`, never `clicked`; payload
  with a URL-like key still `opened` only; cold start (provider + create/resume)
  → one `opened` and the click still buffered for JS; same Intent via
  `onActivityCreated` + `onActivityResumed` → one `opened`; new Intent → second
  `opened`; restore/Recents guards → none (existing tests, now assert type).
- Core: a queued `opened` event is flushed with body `type: "opened"` and removed on 2xx.
**Done when**: Android gate green.
**Status**: Done

### T2: iOS — body tap `opened`, custom action `clicked` [P]

**What**: Add `NottiEventType` constants; `NottiPushDelegate.didReceive`
reports `opened` for the default action (JS `notificationClicked` unchanged),
`clicked` for a custom action (no JS event), nothing for dismiss.
**Where**: `ios/NottiEventStore.swift`, `ios/NottiPushDelegate.swift`
**Requirement**: SDKOPEN-01..10
**Tests** (`ios/Tests/`):
- Push delegate: default action → one `opened`; payload with URL-like key →
  `opened` only; custom action → one `clicked`, no buffered JS click; dismiss →
  none; custom action on non-remote push → none; default action still buffers
  the JS click (cold-start pull).
- Core: queued `opened` flushed with body `type: "opened"`.
**Done when**: iOS gate green.
**Status**: Done

### T3: Docs

**What**: README event section, feature bullet and known limitations;
CHANGELOG `[Unreleased]` (archive 0.5.0 notes first, same convention as 0.4.0);
`ctr-event-reporting` and `notification-action-buttons` specs point to this
spec where their rule changed; STATE.md decision entry.
**Requirement**: SDKOPEN-11
**Done when**: docs reviewed; JS sanity gate green.
**Status**: Done
