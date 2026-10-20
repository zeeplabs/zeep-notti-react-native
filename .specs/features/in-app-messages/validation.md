# In-App messages: device validation (T30)

**Status: NOT RUN.** This is the checklist for the owner's manual run on physical devices. Nothing below has been verified on a device. Fill the cells, attach evidence, then commit with `docs(inapp): record device validation of in-app messages`.

Rules: no real user data in evidence (synthetic token, title and event names); anything that fails becomes a fix task before release; sign-off is the owner's.

## Setup

| Item | Value |
| --- | --- |
| SDK version / commit | |
| `zeep-notti` version and URL (staging) | |
| Plan with `features.in_app_active` on (not yet verified server side) | |
| Android device, OS/API | |
| iPhone model, iOS | |
| iPad / tablet (optional) | |
| Test proxy for `429`/`5xx`/`403`/`401` and image capture | |
| Example app credentials | placeholders replaced locally, never committed |

Messages to create first (see README "In-App messages smoke test"): a `session_start` message (`center`, two buttons, one `deeplink`, `dismiss_after_seconds` 8) and an `event` message `checkout_done` (`bottom`, image + `image_action`). Add a `top` and a `full` message for scenarios 2, 4 and 6.

## Scenarios

Result: `pass`, `fail`, `n/a` or `not run`. Evidence: file name in a `validation/` folder or a dashboard readout.

| # | Scenario | Platforms | Android result | iOS result | Evidence / notes |
| --- | --- | --- | --- | --- | --- |
| 1 | Cold start: one `session_start` message after registration, one `eligible` | both | not run | not run | |
| 2 | Each layout inside its bounds, small and large phone/tablet, portrait and landscape | both | not run | not run | |
| 3 | Dark and light mode; only `background_color` set stays readable | both | not run | not run | |
| 4 | Full style set: colors, `text_align`, `margin` true/false, button tokens | both | not run | not run | |
| 5 | Largest font size / Dynamic Type: nothing unreachable (iOS: the 2 skipped Dynamic Type tests must pass on a simulator) | both | not run | not run | |
| 6 | Gestures and close `reason` (`swipe`, `outside_tap`, `close_button`) | both | not run | not run | |
| 7 | Taps: each button, image (`image`), bar body: only the click is reported | both | not run | not run | |
| 8 | Links: untouched action to JS, SDK opens nothing, no listener, no replay, unknown type gives `action: null` | both | not run | not run | |
| 9 | Auto dismiss: `auto`, paused in background, `close_button` when closed earlier | both | not run | not run | |
| 10 | Rotation during a message: same message, no second `impression` | both | not run | not run | |
| 11 | Activity recreation and RN `<Modal>` with a visible message (R2) | Android | not run | n/a | |
| 12 | iPad multi-scene, scene manifest, keyboard, orientation lock, status bar, window never key (the skipped `UIWindow` test must pass on a simulator) | iOS | n/a | not run | |
| 13 | RN reload with a visible and with a held message: no second `eligible`, no duplicate | both | not run | not run | |
| 14 | Background/foreground: new session fetches once, `once` not re-offered, visible message continues | both | not run | not run | |
| 15 | `trackEvent` matching: exact, case, before the fetch, tight loop without traffic | both | not run | not run | |
| 16 | Offline: airplane at launch; airplane during display, kill, relaunch: same `event_id`, no duplicates | both | not run | not run | |
| 17 | Server errors: `429` + `Retry-After`, `5xx`, `403`, `401`, `eligible` after failed flush, `eligible` 429 rules | both | not run | not run | |
| 18 | Event older than 7 days is never sent | both | not run | not run | |
| 19 | No sensitive data in device logs or in the image request (no `Authorization`, no cookies) | both | not run | not run | |
| 20 | MAU: `last_seen_at` unchanged by In-App traffic alone | both | not run | not run | |
| 21 | VoiceOver / TalkBack, modal focus, Reduce Motion, Android sibling hiding (R3) | both | not run | not run | |
| 22 | Insets: notch/cutout, gesture vs 3-button nav, Android 15+ edge-to-edge, Dynamic Island, `margin` true/false | both | not run | not run | |
| 23 | Memory/perf: 20 messages with images in one session | both | not run | not run | |
| 24 | Compare each layout with the dashboard `InAppPreview` | both | not run | not run | |
| 25 | Cold-start ordering of `initialize`, `trackEvent`, session open, `eligible` (A14); iOS `didBecomeActive` | both | not run | not run | |
| 26 | Android Back on `center`/`full` and bars, predictive back, API 33/34/35 (A19, DD-10) | Android | not run | n/a | |
| 27 | Re-initialize: same config keeps state; different app id resets, no dismiss, old queue discarded, one `eligible` | both | not run | not run | |

Full wording and pass criteria for each scenario: `tasks.md`, task T30.

## Requirement evidence

`Test` = covered by an automated test (to be filled by the reviewer, not pre-claimed here). `Device run` = needs a scenario above. `Not verified` = neither. Requirements listed in T30 as not unit-testable are marked **device**.

| Requirement | Test | Device run (scenario #) | Not verified |
| --- | --- | --- | --- |
| SDKIAM-01  | | | |
| SDKIAM-02  | | | |
| SDKIAM-03  | | | |
| SDKIAM-04  | | | |
| SDKIAM-05  | | | |
| SDKIAM-06  | | | |
| SDKIAM-07  | | | |
| SDKIAM-08  | | | |
| SDKIAM-09  | | | |
| SDKIAM-10  | | | |
| SDKIAM-11  | | | |
| SDKIAM-12  | | | |
| SDKIAM-13 **device** | | | |
| SDKIAM-14  | | | |
| SDKIAM-15  | | | |
| SDKIAM-16  | | | |
| SDKIAM-17 **device** | | | |
| SDKIAM-18  | | | |
| SDKIAM-19  | | | |
| SDKIAM-20  | | | |
| SDKIAM-21 **device** | | | |
| SDKIAM-22 **device** | | | |
| SDKIAM-23  | | | |
| SDKIAM-24  | | | |
| SDKIAM-25 **device** | | | |
| SDKIAM-26  | | | |
| SDKIAM-27  | | | |
| SDKIAM-28 **device** | | | |
| SDKIAM-29  | | | |
| SDKIAM-30  | | | |
| SDKIAM-31  | | | |
| SDKIAM-32  | | | |
| SDKIAM-33  | | | |
| SDKIAM-34  | | | |
| SDKIAM-35  | | | |
| SDKIAM-36  | | | |
| SDKIAM-37 **device** | | | |
| SDKIAM-38  | | | |
| SDKIAM-39  | | | |
| SDKIAM-40 **device** | | | |
| SDKIAM-41  | | | |
| SDKIAM-42  | | | |
| SDKIAM-43  | | | |
| SDKIAM-44  | | | |
| SDKIAM-45 **device** | | | |
| SDKIAM-46  | | | |
| SDKIAM-47  | | | |
| SDKIAM-48  | | | |
| SDKIAM-49  | | | |
| SDKIAM-50  | | | |
| SDKIAM-51  | | | |
| SDKIAM-52  | | | |
| SDKIAM-53  | | | |
| SDKIAM-54  | | | |
| SDKIAM-55  | | | |
| SDKIAM-56  | | | |
| SDKIAM-57  | | | |
| SDKIAM-58  | | | |
| SDKIAM-59  | | | |
| SDKIAM-60  | | | |
| SDKIAM-61  | | | |
| SDKIAM-62  | | | |
| SDKIAM-63 **device** | | | |
| SDKIAM-64 **device** | | | |
| SDKIAM-65  | | | |
| SDKIAM-66 **device** | | | |
| SDKIAM-67  | | | |
| SDKIAM-68  | | | |
| SDKIAM-69  | | | |
| SDKIAM-70 **device** | | | |

## Gaps to close here (from earlier tasks)

- iOS: `testShortButtonsStackAtTheLargestTextSizeWhenTheyNoLongerFit`, `testTextUsesDynamicTypeFonts` (skipped under Mac Catalyst) and `testTheWindowNeverBecomesKeyAndPassesTouchesOutsideABar` must pass in `xcodebuild test` on an iOS simulator. The local machine has no simulator runtime (Xcode > Settings > Components).
- Bar height limited by the safe area is now unit-tested on both platforms; still check on a device with a large cutout (scenario 22).
- `features.in_app_active` on every plan of the license server: confirm before production.
- Open product calls: `pt-PT` close label, image tap as a button role (TalkBack), 1x vs 2x downscale, absolute `text_align: right` vs `END`.

## Sign-off

| Owner | Date | Decision |
| --- | --- | --- |
| | | |
