# AGENTS.md

Operating guide for AI coding agents (Claude Code, Codex, Cursor, etc.) working in this repo.
Human contributors: see [`CONTRIBUTING.md`](./CONTRIBUTING.md). Both must stay consistent; if you
change a command or convention here, update `CONTRIBUTING.md` too.

## What this repo is

`react-native-notti`: the official React Native SDK for Notti push notifications (FCM on Android,
APNs on iOS). Published to npm. Consumers are third-party apps, so the public API, the Expo config
plugin and the integrator setup steps are a contract.

- Turbo Module (New Architecture only), scaffolded with `create-react-native-library` and built with
  `react-native-builder-bob`.
- pnpm workspace: library at the root, demo app in `example/`.
- Node version in `.nvmrc`; package manager is **pnpm** (never npm/yarn, the lockfile is pnpm's).

## Architecture rules (read before adding behavior)

Full decision log: [`.specs/STATE.md`](./.specs/STATE.md). The ones that constrain almost every change:

- **AD-001: business logic lives natively.** HTTP calls to the Notti API, retry/backoff, queues,
  caches, device/subscription state: Kotlin in `android/`, Swift in `ios/`. The TS layer in `src/`
  is a thin facade over the Turbo Module. New SDK behavior goes native by default and is implemented
  **twice** (Android + iOS) with native tests on both sides.
- **AD-002: iOS is Swift behind an Obj-C++ shim.** `ios/Notti.mm` implements `getTurboModule:` and
  delegates to Swift classes via the CocoaPods-generated `Notti-Swift.h`. Keep the shim thin.
- **AD-003: engagement events.** Body tap reports `opened` + `clicked`; action button reports
  `clicked` only; dismiss reports nothing. Don't change event semantics without a new decision entry.

## Layout

| Path                                         | Contents                                                                                                |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `src/index.tsx`                              | Public JS API (`Notti` object, event names, `InitializeOptions`)                                        |
| `src/NativeNotti.ts`                         | Codegen spec (`NottiSpec`). Changing it changes the native interface on both platforms                  |
| `src/__tests__/`                             | Jest tests (facade + config plugin)                                                                     |
| `plugin/src/withNotti.ts`                    | Expo config plugin (Google Services, APNs entitlements, NSE)                                            |
| `android/src/main/java/com/notti/`           | Kotlin module, FCM service, API client, stores                                                          |
| `android/src/test/`                          | Android unit tests (JUnit + MockWebServer)                                                              |
| `ios/*.swift`, `ios/Notti.mm`, `ios/Notti.h` | Swift module + Obj-C++ Turbo Module shim                                                                |
| `ios/NotificationServiceExtension/`          | NSE shipped to integrators                                                                              |
| `ios/Tests/`                                 | XCTest suites (`NottiTests` scheme)                                                                     |
| `example/`                                   | Demo app used for manual testing and CI builds                                                          |
| `.specs/`                                    | Spec-driven feature docs: `features/<name>/{spec,design,tasks,validation}.md`, `STATE.md`, `LESSONS.md` |

## Commands

```sh
pnpm install                 # also links example/node_modules (scripts/link-example-node-modules.js)
pnpm typecheck               # tsc
pnpm lint                    # eslint (+ prettier); `pnpm lint --fix` to format
pnpm test                    # jest
pnpm prepare                 # bob build + config plugin build
pnpm example start|android|ios

# native unit tests (required when android/ or ios/ changes)
cd example/android && ./gradlew :react-native-notti:testDebugUnitTest
xcodebuild test -workspace example/ios/NottiExample.xcworkspace -scheme NottiTests \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Definition of done (mirrors CI)

```sh
pnpm typecheck && pnpm lint && pnpm test && pnpm run build:android && pnpm run build:ios
```

Plus the native test run for any platform you touched. Don't report a task as done without running
the gates that apply, and report failures with the actual output.

## Conventions

- **Commits**: Conventional Commits, enforced by commitlint via lefthook. Use the `notti-commit` skill.
  Always confirm the message with the user before committing; never `--no-verify`.
- **Release**: `pnpm release` (release-it) bumps version, writes `CHANGELOG.md`, tags `vX.Y.Z`. The
  tag triggers `.github/workflows/release.yml`, which publishes to npm via trusted publishing. Don't
  publish manually and don't hand-write `chore: release` commits.
- **Public API changes** (`src/index.tsx`, `NativeNotti.ts`, plugin props, integrator setup steps):
  update `README.md` and add upgrade notes under `[Unreleased]` in `CHANGELOG.md`. Breaking changes
  need `!` + `BREAKING CHANGE:` footer.
- **Feature work**: non-trivial features follow the spec-driven flow in `.specs/features/<name>/`
  (spec, then design, then tasks, then validation). Keep `STATE.md` decisions in sync. Lessons in
  `LESSONS.md` are machine-maintained; don't hand-edit them.
- **Tests verify behavior, not wiring** (lesson L-001): a mocked facade test doesn't prove a native
  acceptance criterion; test the layer that implements it.
- Keep platform parity: a fix on one platform needs the equivalent check on the other.

## Data and security

The SDK handles device tokens, email, phone and notification payloads of end users.

- Never log PII or tokens in production code paths, test fixtures or commit messages.
- No credentials in the repo (`google-services.json`, `.p8`, API keys). Use placeholders in `example/`.

## Known gotchas

- `Notti.podspec` subspecs must keep their `exclude_files` (`core` excludes `ios/Tests/**` and the
  NSE; `nse` excludes its `Tests/**`), or XCTest code compiles into the pod.
- New Swift files conforming to UIKit/UserNotifications protocols need the framework imported in
  `ios/Notti.h` before `Notti.mm` includes `Notti-Swift.h`.
- After native project edits, run `pod install` in `example/ios` if the build says "sandbox is not in
  sync". `example/ios/Podfile.lock` and `Info.plist` pick up local noise on `pod install`; revert them
  instead of committing.
- Android builds need a JDK; if none is on `PATH`, point `JAVA_HOME` at Android Studio's JBR.
  `pnpm turbo run build:android` drops `JAVA_HOME`; use `cd example && pnpm run build:android`.
- Every `MockWebServer.takeRequest()` must pass an explicit timeout (lesson L-003).
- The library manifest does not declare `POST_NOTIFICATIONS`; integrators add it (documented in README).

## Agent skills

Project skills live in `.agents/skills/` (Codex, Cursor) and are mirrored in `.claude/skills/`
(Claude Code). Third-party ones are pinned in `skills-lock.json`. Load the matching skill before
working in its area:

| Skill                         | Use when                                                                                  |
| ----------------------------- | ----------------------------------------------------------------------------------------- |
| `notti-commit`                | Writing or validating any commit (repo-owned)                                             |
| `create-react-native-library` | Library structure, bob/codegen config, Turbo Module scaffolding                           |
| `react-native-best-practices` | Native module performance, JS thread, memory, Hermes                                      |
| `upgrading-react-native`      | Bumping React Native / the library template                                               |
| `swift-concurrency`           | async/await, actors, `Sendable`, Swift 6 warnings in `ios/`                               |
| `expo-module`                 | Config plugin work (`plugin/`); the module itself is a Turbo Module, not Expo Modules API |
| `github-actions`              | CI workflows in `.github/`                                                                |

Updating third-party skills: `npx skills update -p`, then review the diff before committing (they run
with full agent permissions). Keep `.agents/skills/` and `.claude/skills/` identical.

Before adding a third-party skill, check its license: this repo is public and MIT, and vendored skills
are redistributed with it. Only permissive licenses (MIT, Apache-2.0, BSD). Example:
`dpearson2699/swift-ios-skills` is PolyForm Perimeter and stays out pending legal review.
