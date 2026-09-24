## Summary

<!-- What does this PR change, and why? Link any related issue. -->

## Type of change

- [ ] `fix` — bug fix
- [ ] `feat` — new feature
- [ ] `refactor` — no behavior change
- [ ] `docs` — documentation only
- [ ] `test` — tests only
- [ ] `chore` — tooling/CI/build

## Checklist

- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/en) (`fix:`, `feat:`, …) — enforced by commitlint on commit.
- [ ] `pnpm typecheck && pnpm lint && pnpm test` pass locally.
- [ ] If native code changed: `./gradlew :react-native-notti:testDebugUnitTest` (Android) and/or `xcodebuild test -scheme NottiTests` (iOS) pass locally — see [CONTRIBUTING.md](../CONTRIBUTING.md).
- [ ] Added/updated tests for the behavior this PR changes.
- [ ] Updated the README/API reference if this changes public API.
- [ ] For a public-API or architecture change: discussed with maintainers first (open an issue before a large PR).

## Platforms affected

- [ ] Android
- [ ] iOS
- [ ] JS/TS facade only
- [ ] Expo config plugin

## How was this tested?

<!-- Unit tests added, and/or manual smoke test via example/ app against a real Notti instance. -->
