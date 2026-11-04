# Android on the Native SDK Tasks

**Design**: `.specs/features/android-native-sdk/design.md` (approved by Julio, 2026-11-04)
**Status**: Approved (Julio, 2026-11-04)

---

## Test Coverage Convention (no `.specs/codebase/TESTING.md`; derived from `AGENTS.md` and `ci.yml`)

| Code layer | Test type | Command |
| --- | --- | --- |
| Android adapter (`android/src/main/java/com/notti/*.kt`) | JUnit 4 + Robolectric (`android/src/test`) with `FakeNottiNativeApi` | `cd example/android && ./gradlew :react-native-notti:testDebugUnitTest` |
| `android/build.gradle`, manifest, CI | Build | `cd example && pnpm build:android` (CI: `pnpm turbo run build:android`) |
| TS (`src/`), plugin (`plugin/`) | Jest | `pnpm typecheck && pnpm lint && pnpm test` |
| Behavior of `notti-android` itself | Tested in `zeep-notti-android-sdk`, not here (L-001) | - |

**Gates**:
- `quick` (adapter tasks): Android unit tests above.
- `build` (Gradle/manifest tasks): example Android build.
- `full` (T10): `pnpm typecheck && pnpm lint && pnpm test && pnpm run build:android && pnpm run build:ios`
  (`build:*` run through the example package: `pnpm example build:android`, `pnpm example build:ios`) and
  the Android unit tests.

`src/` is not touched (no JS API change). iOS is not touched (`ios-native-sdk`). Commits: one task per
commit, conventional commits (`build(android):`, `feat(android):`, `refactor(android):`, `test(android):`,
`ci:`, `docs:`), no AI attribution. Intermediate commits between T1 and T6 build and pass `quick`, but run
two engines in the example (old `com.notti` provider/service plus the AAR's); only the branch as a whole is
shippable.

---

## Prerequisites and blockers

| ID | What | Owner | Blocks |
| --- | --- | --- | --- |
| EXT-1 | `br.com.zeeplabs:notti-android` 0.2.0 with `Notti.initializeForWrapper` on Maven Central (native `wrapper-support`, AD-022). Status 2026-11-04: released (native `CHANGELOG.md`, tag `0.2.0`). | Native repo | T1 |
| EXT-2 | `ios-native-sdk` ships in the same 0.9.0 (G3): one `CHANGELOG.md` section, one `BREAKING CHANGE` | Julio | T10 release step (not this feature's merge) |
| D-1 | Android 13+ device with the example app, a Firebase project and a Notti app (synthetic test app, no real users), plus a build of `react-native-notti` 0.8.0 for the in-place upgrade | Julio | T11 |

---

## Execution Plan

### Phase 1: Dependency spike (sequential)

```
EXT-1 ──→ T1
```

### Phase 2: Adapter next to the old core

```
T1 ──→ T2 ──→ T3 ──→ T4
T1 ──→ T5 [P]
T8 [P] (independent)
```

### Phase 3: Swap, guards, docs, validate

```
T4, T5 ──→ T6 ──→ T7
T1, T5, T6 ──→ T9
T7, T8, T9 ──→ T10 ──→ T11
```

---

## Task Breakdown

### T1: Spike: depend on `notti-android` 0.2.0 and measure the host floors

**What**: `android/build.gradle` gets `api "br.com.zeeplabs:notti-android:0.2.0"` and loses
`implementation "com.google.firebase:firebase-messaging:25.1.2"` (now from the AAR's `api`). The old core
still compiles. Build the example (RN 0.87.1, its AGP and Kotlin 2.1.20) and record in `design.md` a
"Spike results" section with evidence:
1. resolution from `mavenCentral()` with no extra repository line;
2. the example's AGP consuming the AGP 9.2.1-built AAR (R3);
3. Kotlin: the example compiles against metadata 2.0 / stdlib 2.0.21; note what a Kotlin 1.9 host gets;
4. `./gradlew :app:dependencies --configuration releaseRuntimeClasspath`: exactly one
   `firebase-messaging`, `notti-android:0.2.0`, no duplicate-class error between `com.notti` and
   `com.zeeplabs.notti`;
5. real RN floor (OQ-5): first RN release with Kotlin >= 2.0 and first RN release exporting the
   `CodegenTypes` namespace used by `src/NativeNotti.ts` (from RN release tags/changelogs); the higher
   one goes to README in T9;
6. the merged manifest of the example (two providers, two services while the old core lives: expected,
   removed in T6).
**Where**: `android/build.gradle`, `.specs/features/android-native-sdk/design.md` (Spike results)
**Depends on**: EXT-1
**Reuses**: native README Requirements, native AD-017
**Requirements**: ANSDK-01 (partial), ANSDK-15, ANSDK-16
**Done when**:
- [x] Example Android build passes with the dependency
- [x] Items 1-6 recorded with command output excerpts; any failure becomes a blocker row above before T2
**Tests**: none (build)
**Gate**: build + quick (old suite still green)

### T2: `NottiNativeApi` seam and test support

**What**: `internal interface NottiNativeApi` with one method per native call the adapter makes
(`initializeForWrapper`, `login`, `logout`, `addTags`, `removeTags`, `setSubscription`,
`setLocationSharingEnabled`, `setEmail`, `clearEmail`, `setPhone`, `clearPhone`, `deviceId`,
`trackEvent`, `requestPermission`, `takeInitialClick`, the four listener adders returning a removable
handle) and adapter-owned value types (`NativeNotification`, `NativeInAppClick` with
`NottiInAppAction.Type?`). `DefaultNottiNativeApi` calls the static `Notti.*` with
`@OptIn(NottiWrapperApi::class)` and converts native values in one line each. Test support: new
`NottiTestSupport.kt` with `FakeNottiNativeApi` (records calls, holds listeners, counts live handles),
`ShadowArguments` moved out of `NottiActivityLifecycleListenerTest.kt` (removed there) and a capturing
event sink type.
**Where**: `android/src/main/java/com/notti/NottiNativeApi.kt` (new),
`android/src/test/java/com/notti/NottiTestSupport.kt` (new),
`android/src/test/java/com/notti/NottiActivityLifecycleListenerTest.kt` (shadow moved out)
**Depends on**: T1
**Reuses**: `ShadowArguments` (`NottiActivityLifecycleListenerTest.kt:553`)
**Requirements**: ANSDK-02, ANSDK-03, ANSDK-17
**Done when**:
- [x] Compiles next to the old core; `Notti.` appears only in `DefaultNottiNativeApi`
- [x] Old suite still green with the moved shadow
**Tests**: none of its own (pass-through; exercised through the fake in T3-T5)
**Gate**: quick

### T3: `NottiAdapter` method forwarding

**What**: `internal class NottiAdapter(native: NottiNativeApi, events: NottiEventSink)` in
`NottiModule.kt` (design "Staging"), with every Spec method per the design's method mapping table:
`initialize` -> `initializeForWrapper(ctx.applicationContext, appId.orEmpty(), clientKey.orEmpty(),
NottiOptions(baseUrl, opensInAppUrls = false), "react-native", sdkVersion)`; one-line forwards; 0.8.0
null handling (no call for null `login`/`setEmail`/`setPhone`/`trackEvent`); `addTags` drops non-string
values (0.8.0 `NottiModule.kt:275-277`); `removeTags` maps with `toString()`; `requestPermission`
resolves the native Boolean and never rejects; `getDeviceId` returns the native value. The old
`NottiModule` class is not changed yet.
**Where**: `android/src/main/java/com/notti/NottiModule.kt`,
`android/src/test/java/com/notti/NottiAdapterTest.kt` (new)
**Depends on**: T2
**Requirements**: ANSDK-02, ANSDK-03, ANSDK-04, ANSDK-17
**Done when**:
- [x] One test per Spec method: exact arguments forwarded once; null arguments make no call
- [x] `initialize` passes `sdkName == "react-native"`, the JS `sdkVersion`, the `baseUrl` and `opensInAppUrls == false`, never the plain `initialize`
- [x] `addTags` with a non-string value forwards only the string entries; empty map and empty list are forwarded (same core path as 0.8.0)
- [x] `requestPermission` resolves `true` and `false` from the fake; no reject path exists
**Tests**: JUnit + Robolectric with `FakeNottiNativeApi`
**Gate**: quick

### T4: `NottiAdapter` events, listener lifecycle and initial click

**What**: `NottiAdapter.start()` adds the received, clicked, device-id and In-App click listeners and
keeps the four handles; `stop()` removes them (idempotent). Payload mapping to `WritableMap`: notification
`{title, body, data}` with `putNull` for a missing title/body; In-App `{messageId, buttonId, action}` with
`Type.URL` -> `"url"`, `Type.DEEPLINK` -> `"deeplink"`, any other value and a null action -> `action: null`
(key present, OQ-3). `getInitialNotificationClick` resolves `takeInitialClick()` mapped, or `null`.
**Where**: `android/src/main/java/com/notti/NottiModule.kt`,
`android/src/test/java/com/notti/NottiAdapterTest.kt`
**Depends on**: T3
**Requirements**: ANSDK-05, ANSDK-06, ANSDK-07, ANSDK-17
**Done when**:
- [x] Received/clicked payloads match the 0.8.0 shape, `title`/`body` keys present with `null`
- [x] Every `NottiInAppAction.Type.entries` value has an explicit mapping (test fails if native adds one); null action gives `action: null`
- [x] `start()` leaves 4 live handles in the fake, `stop()` leaves 0; an event delivered after `stop()` emits nothing; a second adapter gets each event once
- [x] `getInitialNotificationClick` resolves the mapped click once, then `null`
**Tests**: JUnit + Robolectric with `FakeNottiNativeApi`
**Gate**: quick

### T5: Deprecated `com.notti.NottiBridge` shim [P]

**What**: Replace `NottiBridge.kt` with the design's shim: `@Deprecated` object (level WARNING, OQ-7) with
`ReplaceWith` to `com.zeeplabs.notti.NottiBridge`, the same two `@JvmStatic` signatures, each forwarding to
the native bridge through an `internal var target` (default: native) so the test can fake it. Rewrite
`NottiBridgeTest.kt`.
**Where**: `android/src/main/java/com/notti/NottiBridge.kt`,
`android/src/test/java/com/notti/NottiBridgeTest.kt`
**Depends on**: T1
**Requirements**: ANSDK-11, ANSDK-17
**Done when**:
- [x] Both calls reach the fake target with the same `RemoteMessage`/token
- [x] With the real target and no native runtime both calls are safe no-ops (Robolectric)
- [x] A Kotlin and a Java snippet calling the 0.8.0 signatures compile with a deprecation warning only (test source or example scratch check, recorded). Recorded 2026-11-04: Kotlin through `NottiBridgeTest`; Java through a temporary `NottiBridgeJavaCallerScratch.java` in `android/src/test` compiled by `compileDebugUnitTestJavaWithJavac` with only javac's "uses or overrides a deprecated API" note, then deleted
**Tests**: JUnit + Robolectric
**Gate**: quick

### T6: Swap: `NottiModule` delegates to the adapter; in-repo core deleted

**What**: `NottiModule(reactContext, native = DefaultNottiNativeApi)` builds a `NottiAdapter` whose sink
calls the generated `emitOn*`, delegates every Spec method, calls `start()` as its last `init` statement
and `stop()` in `invalidate()` before `super.invalidate()`. Delete the 20 core files under
`android/src/main/java/com/notti/` and the 18 core suites under `android/src/test/java/com/notti/`
(design "File fate"); rewrite `NottiModuleTest.kt` for the module wiring (package builds the module,
listeners added on construction, removed on `invalidate`). Empty `android/src/main/AndroidManifest.xml`
to `<manifest />`. Drop `lifecycle-process`, `mockwebserver`, `okhttp-tls`, `org.json` from
`android/build.gradle`.
**Where**: `android/src/main/`, `android/src/test/`, `android/build.gradle`
**Depends on**: T4, T5
**Requirements**: ANSDK-01, ANSDK-06, ANSDK-17
**Done when**:
- [x] `android/src/main/java/com/notti/` holds only `NottiModule.kt`, `NottiPackage.kt`, `NottiBridge.kt`, `NottiNativeApi.kt`
- [x] `android/src/test/java/com/notti/` holds only `NottiAdapterTest.kt`, `NottiModuleTest.kt`, `NottiBridgeTest.kt`, `NottiTestSupport.kt`
- [x] Merged example manifest has one provider (`com.zeeplabs.notti.NottiInitProvider`), one FCM service, `NottiPermissionActivity`
- [x] `quick` and `build` green
**Tests**: T3-T5 suites + rewritten `NottiModuleTest`
**Gate**: quick + build

### T7: CI guards for the adapter-only layout

**What**: Add a CI step (and a local script) that fails when `android/src/main/java/com/notti/` holds any
file outside the four adapter files, and when the example's release runtime classpath has more than one
`firebase-messaging` version or a `com.notti` class besides the adapter's. Keep the existing Android unit
test step (`ci.yml:111-114`).
**Where**: `scripts/check-android-adapter.sh` (new), `.github/workflows/ci.yml`
**Depends on**: T6
**Requirements**: ANSDK-01, ANSDK-16, ANSDK-18
**Done when**:
- [x] Script passes on the branch and fails when a dummy file is added (checked locally, not committed)
- [x] Workflow parses; new step pinned the same way as the others (no new action; CI run on the PR is the final check)
**Tests**: script self-check (manual, recorded in the PR)
**Gate**: CI run on the PR (if Actions billing blocks it, run locally and paste output)

### T8: Expo config plugin review [P]

**What**: Confirm the design finding: `plugin/src/withNotti.ts` writes only the Google Services setup and
the FCM default icon/color meta-data, references no `com.notti` class or manifest component, so 0.9.0
needs no plugin change. Run an Expo prebuild of a scratch app (outside the repo) against the branch and
check the merged manifest. Record the result in this task; change code and Jest tests only if a
reference turns up.
**Where**: `plugin/src/withNotti.ts` (read), this file (result)
**Depends on**: none
**Requirements**: ANSDK-13
**Done when**:
- [x] Finding recorded with the prebuild manifest excerpt (no `com.notti` component, native service and provider present)
- [x] JS gate green

**Result (2026-11-04):** plugin unchanged (`plugin/src/withNotti.ts` touches only Google Services and the FCM
notification icon/color; no `com.notti`, authority or Gradle dependency line). Scratch Expo SDK 58 / RN 0.88.1
app with the packed library: `expo prebuild --platform android` and `:app:assembleDebug` pass. Merged manifest:
`com.zeeplabs.notti.NottiInitProvider` (authority `${applicationId}.com.zeeplabs.notti.initprovider`),
`com.zeeplabs.notti.NottiFirebaseMessagingService`, `com.zeeplabs.notti.NottiPermissionActivity`; zero
`com.notti.` entries; `firebase-messaging:25.1.2` from `notti-android:0.2.0`. Unrelated, also on `main`: Expo 58
warns that `package.json` `exports` lacks `./app.plugin.js` (follow-up `fix(plugin)`).
**Tests**: Jest (only if code changes)
**Gate**: `pnpm typecheck && pnpm lint && pnpm test`

### T9: README and CHANGELOG upgrade notes

**What**: README Android setup: no Kotlin core in this package (depends on `notti-android`), Requirements
with the floors measured in T1 (RN version, Kotlin 2.0+, `compileSdk` 34+, `minSdk` 24), one engine per
app ("do not call `com.zeeplabs.notti.Notti` directly", OQ-1), own FCM service with the shim and the new
`tools:node="remove"` names. `CHANGELOG.md` `[Unreleased]` Android upgrade notes (`BREAKING CHANGE`
content), one entry per design "Behavior differences": identity calls before `initialize` dropped only
when the provider is removed (OQ-6); foreground-only permission dialog; `NottiPermissionActivity`;
malformed tap Intents no longer crash; provider authority and component class names; shim deprecated and
now reporting `received`; one process-wide core; `sdk_name: "react-native"` and its backend version.
**Where**: `README.md`, `CHANGELOG.md`
**Depends on**: T1, T5, T6
**Requirements**: ANSDK-12, ANSDK-14, ANSDK-15
**Done when**:
- [ ] Every item of design "Behavior differences" and the manifest table has a note
- [ ] README snippets (service with the shim, `tools:node="remove"` with new names) match the code
- [ ] No PII in examples (synthetic values only)
**Tests**: none
**Gate**: `pnpm lint`

### T10: Full gate

**What**: Run the full gate on the branch and paste outputs in the PR. Update `.specs/STATE.md` AD-006
status (implemented, pending device validation).
**Where**: `.specs/STATE.md`
**Depends on**: T7, T8, T9
**Requirements**: ANSDK-18
**Done when**:
- [ ] `pnpm typecheck && pnpm lint && pnpm test && pnpm run build:android && pnpm run build:ios` green
- [ ] `./gradlew :react-native-notti:testDebugUnitTest` green; test count reported (drop explained by the deleted core suites)
**Tests**: all
**Gate**: full

### T11: Device validation

**What**: On D-1, record in `validation.md`:
1. in-place upgrade 0.8.0 -> 0.9.0: register and add tags on 0.8.0, upgrade without uninstall: one device
   row on the backend, same `getDeviceId()`, tags intact, queued push/In-App events flushed, one PATCH
   with `sdk_version` 0.9.0 and `sdk_name: "react-native"`;
2. push received in foreground (`onNotificationReceived`), warm tap (`onNotificationClicked`), cold-start
   tap via `getInitialNotificationClick()` once;
3. In-App `url` and `deeplink` clicks reach the JS listener with the 0.8.0 payload and no link opens;
   `push_permission` gives `action: null` and runs the prompt;
4. `requestPermission` in the foreground (prompt via `NottiPermissionActivity`) and from the background
   (`false`, no prompt);
5. dev reload: each event once after reload, no duplicate emits;
6. host variant with its own `FirebaseMessagingService` calling `com.notti.NottiBridge` and
   `tools:node="remove"` on `com.zeeplabs.notti.NottiFirebaseMessagingService`: push delivered, `received`
   reported (R1 also checked with the old name left in place, to describe the failure mode).
**Where**: `.specs/features/android-native-sdk/validation.md` (new)
**Depends on**: T10, D-1
**Requirements**: ANSDK-05, ANSDK-06, ANSDK-07, ANSDK-08, ANSDK-09, ANSDK-10 (runtime), ANSDK-11, ANSDK-12
**Done when**:
- [ ] Every item has a recorded result by Julio or by a run with evidence (no PII in screenshots or logs)
**Tests**: manual
**Gate**: manual

ANSDK-10 (key audit) is verified by analysis in `design.md` ("Data continuity"); T11 item 1 is its runtime
proof.

---

## Validation (pre-approval checks)

### Check 1: Granularity

| Task | One deliverable? | Result |
| --- | --- | --- |
| T1 | One dependency line + spike record | ✅ |
| T2 | One seam file + its test support | ✅ |
| T3 | Method forwarding in one class + tests | ✅ |
| T4 | Event bridging in one class + tests | ✅ |
| T5 | One shim file + its test | ✅ |
| T6 | The swap: delegation + deletions (one atomic change; split impossible without breaking the build, since the old core uses `NottiModule`'s companion) | ✅ |
| T7 | One script + one CI step | ✅ |
| T8 | One review, conditional edit | ✅ |
| T9 | Docs only | ✅ |
| T10 | Gate + status line | ✅ |
| T11 | Validation record | ✅ |

### Check 2: Diagram vs `Depends on`

| Task | Depends on (definition) | Diagram | Match |
| --- | --- | --- | --- |
| T1 | EXT-1 | EXT-1 → T1 | ✅ |
| T2 | T1 | T1 → T2 | ✅ |
| T3 | T2 | T2 → T3 | ✅ |
| T4 | T3 | T3 → T4 | ✅ |
| T5 | T1 | T1 → T5 [P] | ✅ |
| T6 | T4, T5 | T4, T5 → T6 | ✅ |
| T7 | T6 | T6 → T7 | ✅ |
| T8 | none | [P] independent | ✅ |
| T9 | T1, T5, T6 | T1, T5, T6 → T9 | ✅ |
| T10 | T7, T8, T9 | T7, T8, T9 → T10 | ✅ |
| T11 | T10, D-1 | T10 → T11 (D-1 in blockers) | ✅ |

### Check 3: Test co-location

| Task | Layer | Required | In task | Result |
| --- | --- | --- | --- | --- |
| T1 | Gradle | build | example build + old suite | ✅ |
| T2 | Adapter seam | JUnit via fake (pass-through) | covered by T3-T5; quick | ✅ |
| T3 | Adapter | JUnit | `NottiAdapterTest` | ✅ |
| T4 | Adapter | JUnit | `NottiAdapterTest` | ✅ |
| T5 | Adapter (shim) | JUnit | `NottiBridgeTest` | ✅ |
| T6 | Module wiring + deletion | JUnit + build | `NottiModuleTest`, quick + build | ✅ |
| T7 | CI | script + run | self-check + workflow run | ✅ |
| T8 | plugin (TS) | Jest if changed | JS gate | ✅ |
| T9 | docs | none | lint | ✅ |
| T10 | all | full | full gate | ✅ |
| T11 | runtime | manual | `validation.md` | ✅ |

---

## Requirement coverage

| ID | Tasks |
| --- | --- |
| ANSDK-01 | T1, T6, T7 |
| ANSDK-02 | T2, T3 |
| ANSDK-03 | T2, T3 |
| ANSDK-04 | T3 |
| ANSDK-05 | T4, T11 |
| ANSDK-06 | T4, T6, T11 |
| ANSDK-07 | T4, T11 |
| ANSDK-08 | T11 |
| ANSDK-09 | T11 |
| ANSDK-10 | design.md analysis, T11 |
| ANSDK-11 | T5, T11 |
| ANSDK-12 | T9, T11 |
| ANSDK-13 | T8 |
| ANSDK-14 | T9 |
| ANSDK-15 | T1, T9 |
| ANSDK-16 | T1, T7 |
| ANSDK-17 | T2, T3, T4, T5, T6 |
| ANSDK-18 | T7, T10 |

**Coverage:** 18 total, 18 mapped, 0 unmapped.
