# Contributing

Contributions are always welcome, no matter how large or small!

We want this community to be friendly and respectful to each other. Please follow it in all your interactions with the project. Before contributing, please read the [code of conduct](./CODE_OF_CONDUCT.md).

## Development workflow

This project is a monorepo managed using [pnpm workspaces](https://pnpm.io/workspaces) (see [`pnpm-workspace.yaml`](./pnpm-workspace.yaml)). It contains the following packages:

- The library package in the root directory (JS facade + Kotlin/Swift native modules + Expo config plugin).
- An example app in the `example/` directory.

To get started, make sure you have the correct version of [Node.js](https://nodejs.org/) installed — see the [`.nvmrc`](./.nvmrc) file — and [pnpm](https://pnpm.io/installation) itself.

Install dependencies from the root directory:

```sh
pnpm install
```

> Since the project relies on pnpm workspaces, don't use `npm`/`yarn` for development without migrating the lockfile.

`pnpm install` also runs a `postinstall` step (`scripts/link-example-node-modules.js`) that creates `example/node_modules` as a symlink to the root's — CocoaPods and the Android Gradle plugin both resolve `REACT_NATIVE_PATH` through that path. If you ever see it missing (e.g. after manually deleting `node_modules`), rerun `node scripts/link-example-node-modules.js` or just `pnpm install` again.

The [example app](/example/) demonstrates usage of the library. You need to run it to test any changes you make.

It is configured to use the local version of the library, so any changes you make to the library's source code will be reflected in the example app. Changes to the library's JavaScript code will be reflected in the example app without a rebuild, but native code changes will require a rebuild of the example app.

If you want to use Android Studio or Xcode to edit the native code, you can open the `example/android` or `example/ios` directories respectively in those editors. To edit the Objective-C or Swift files, open `example/ios/NottiExample.xcworkspace` in Xcode and find the source files at `Pods > Development Pods > react-native-notti`.

To edit the Java or Kotlin files, open `example/android` in Android Studio and find the source files at `react-native-notti` under `Android`.

You can use various commands from the root directory to work with the project.

To start the packager:

```sh
pnpm example start
```

To run the example app on Android:

```sh
pnpm example android
```

To run the example app on iOS:

```sh
pnpm example ios
```

To confirm that the app is running with the new architecture, check the Metro logs for a message like this:

```sh
Running "NottiExample" with {"fabric":true,"initialProps":{"concurrentRoot":true},"rootTag":1}
```

Note the `"fabric":true` and `"concurrentRoot":true` properties.

Make sure your code passes TypeScript:

```sh
pnpm typecheck
```

To check for linting errors, run the following:

```sh
pnpm lint
```

To fix formatting errors, run the following:

```sh
pnpm lint --fix
```

Remember to add tests for your change if possible. Run the JS/TS unit tests by:

```sh
pnpm test
```

### Native tests

Business logic lives natively (Kotlin + Swift, no shared code between platforms — see `AD-001` in [`.specs/STATE.md`](./.specs/STATE.md)), so a change to `android/` or `ios/` needs its own native test run, not just `pnpm test`:

```sh
# Android (from example/android)
cd example/android && ./gradlew :react-native-notti:testDebugUnitTest

# iOS
xcodebuild test \
  -workspace example/ios/NottiExample.xcworkspace \
  -scheme NottiTests \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Both run in CI on every PR (see [`.github/workflows/ci.yml`](./.github/workflows/ci.yml)) — a PR touching native code without a passing native test run here will fail CI.

### Full sanity gate

Before opening a PR, all of the following should pass — this mirrors CI:

```sh
pnpm typecheck && pnpm lint && pnpm test && pnpm run build:android && pnpm run build:ios
```

### Commit message convention

We follow the [conventional commits specification](https://www.conventionalcommits.org/en) for our commit messages:

- `fix`: bug fixes, e.g. fix crash due to deprecated method.
- `feat`: new features, e.g. add new method to the module.
- `refactor`: code refactor, e.g. migrate from class components to hooks.
- `docs`: changes into documentation, e.g. add usage example for the module.
- `test`: adding or updating tests, e.g. add integration tests using detox.
- `chore`: tooling changes, e.g. change CI config.

Our pre-commit hooks (via [lefthook](https://github.com/evilmartians/lefthook)) verify that your commit message matches this format when committing.

### Publishing to npm

We use [release-it](https://github.com/release-it/release-it) to make it easier to publish new versions. It handles common tasks like bumping the version based on semver, generating [`CHANGELOG.md`](./CHANGELOG.md) from Conventional Commits, creating tags, and publishing GitHub Releases.

To publish a new version, run the following:

```sh
pnpm release
```

### Scripts

The `package.json` file contains various scripts for common tasks:

- `pnpm install`: set up the project by installing dependencies.
- `pnpm typecheck`: type-check files with TypeScript.
- `pnpm lint`: lint files with [ESLint](https://eslint.org/).
- `pnpm test`: run unit tests with [Jest](https://jestjs.io/).
- `pnpm example start`: start the Metro server for the example app.
- `pnpm example android`: run the example app on Android.
- `pnpm example ios`: run the example app on iOS.
- `pnpm run build:android` / `pnpm run build:ios`: build the example app in a release-like shape (also what CI runs).

### Sending a pull request

> **Working on your first pull request?** You can learn how from this _free_ series: [How to Contribute to an Open Source Project on GitHub](https://app.egghead.io/playlists/how-to-contribute-to-an-open-source-project-on-github).

When you're sending a pull request:

- Prefer small pull requests focused on one change.
- Verify that linters, JS tests, and any native tests you touched are passing.
- Review the documentation to make sure it looks good.
- Follow the [pull request template](./.github/PULL_REQUEST_TEMPLATE.md) when opening a pull request.
- For pull requests that change the public API or architecture, discuss with maintainers first by opening an issue.
