---
name: notti-commit
description: Writes and validates commit messages for react-native-notti following this repo's commitlint config (@commitlint/config-conventional) and the scope conventions used in its history. Use when committing, splitting changes into commits, writing a commit message, or preparing a branch for a PR in this repo.
---

# notti-commit

Commit messages here feed two automated consumers, so a malformed one is a real defect, not a style nit:

- `lefthook` runs `commitlint --edit` on `commit-msg` and rejects invalid headers.
- `release-it` + `@release-it/conventional-changelog` (angular preset) builds `CHANGELOG.md` and picks the semver bump from commit types.

## Workflow

1. Inspect the change: `git status` and `git diff --cached` (or `git diff` if nothing is staged).
2. Decide the split. One logical change per commit. When a feature touches both platforms, prefer separate commits per platform (`feat(android): ...` then `feat(ios): ...`), matching the repo history. Specs/docs go in their own `docs(...)` commit.
3. Draft the message (format below).
4. Validate before committing:
   ```sh
   printf '%s\n' "<full message>" | npx commitlint
   ```
5. **Show the message to the user and wait for confirmation before running `git commit`.** Never commit on your own initiative.
6. Commit with `git commit -m "<header>" -m "<body>"`. Let the lefthook `pre-commit` (eslint + tsc) run; never use `--no-verify`. If a hook fails, fix the cause and create a new commit, do not `--amend` a commit that is already pushed.

## Format

```
<type>(<scope>): <subject>

<body: why, not what - wrap at 100 chars>

<footer: BREAKING CHANGE: ..., Refs: ...>
```

### Types

| Type       | Use for                                         | In CHANGELOG / bump |
| ---------- | ----------------------------------------------- | ------------------- |
| `feat`     | New SDK capability or public API                | yes, minor          |
| `fix`      | Bug fix in SDK behavior                         | yes, patch          |
| `perf`     | Performance improvement, no behavior change     | yes, patch          |
| `refactor` | Internal restructure, no behavior change        | no                  |
| `test`     | Tests only                                      | no                  |
| `docs`     | README, CHANGELOG notes, `.specs/`              | no                  |
| `build`    | Podspec, Gradle, bob, package.json build config | no                  |
| `ci`       | `.github/workflows`, `.github/actions`          | no                  |
| `chore`    | Tooling, deps, gitignore, agent config          | no                  |
| `revert`   | Reverting a previous commit                     | depends             |

`chore: release x.y.z` is reserved for `release-it`. Never write it by hand.

### Scopes (from repo history)

- `android`: Kotlin module under `android/`
- `ios`: Swift/Obj-C++ module under `ios/` (including `NotificationServiceExtension`)
- `ios,android`: same fix applied to both platforms in one commit (use sparingly)
- `js`: TypeScript facade in `src/` (`index.tsx`, `NativeNotti.ts`)
- `plugin`: Expo config plugin in `plugin/`
- `example`: example app
- `specs` / `design`: `.specs/` documents
- No scope: cross-cutting change (e.g. `feat: report body tap as both opened and clicked`)

### Rules enforced by commitlint (config-conventional)

- Header max 100 chars; type and scope lowercase.
- Subject: imperative mood, lowercase start, no trailing period (`add`, not `Added` / `adds`).
- Body and footer lines max 100 chars, separated from the header by a blank line.

### Breaking changes

Any change to the public JS API (`src/index.tsx` exports, event names, `InitializeOptions`), the config plugin props, or required integrator setup steps (manifest, entitlements, NSE) is breaking unless it is purely additive. Mark it with `!` and a footer:

```
feat(js)!: rename notificationClicked to notificationOpened

BREAKING CHANGE: listeners registered on `notificationClicked` no longer fire.
Migrate to `notificationOpened`.
```

Also add an upgrade note under `[Unreleased]` in `CHANGELOG.md`.

## Examples (real, from this repo)

```
fix(ios): ack profile fields only when the PATCH response echoes them
feat(android): sync device profile fields via generalized PATCH
feat(js): add email/phone setters and thread sdk_version through initialize
docs(specs): specify opened event reporting
chore: ignore .worktrees scratch dir
```

## Don't

- Don't put PII (emails, phones, device tokens, payloads from real users) in commit messages.
- Don't mix a platform fix with unrelated refactors in the same commit.
- Don't add tool/AI attribution lines unless the user explicitly asks for them.
