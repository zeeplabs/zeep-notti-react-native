# Logout Clears External User ID Specification

Status: **Execute (approved by Julio 2026-10-23)**. Scope: Medium (Android + iOS `logout()`, no public API change).

Contract and full rationale live in the backend spec: `zeep-notti/.specs/features/device-logout-clears-external-id/spec.md` (requirements DLOG-10..15). This file mirrors the SDK side.

## Problem

`logout()` cleared `external_user_id` only on the phone. Since the backend stopped wiping it on re-registration (zeep-notti#189), a logged-out device stayed linked to the previous user for good, so pushes sent to that user by `external_user_ids` kept reaching a shared phone.

## Behavior

- `logout()` persists the local clear and a durable `pendingExternalUserIdClear` flag, then enqueues `PATCH {external_user_id: null}` on the serialized mutation queue (coalesced, key `externalUserId`), next to the existing `email`/`phone` clears.
- 2xx: local id cleared again (a queued `login` acked just before may have re-persisted it) and the flag dropped. Failure: flag kept.
- Registration success re-sends the clear while the flag is set (offline, failed PATCH, logout before `initialize()`).
- A successful `login()` drops the flag (the new link supersedes the owed clear).
- The clear PATCH is not gated on the flag: with `login("u1")` + `logout()` both queued before registration, login's ack drops the flag first.
- Tags and subscription are never part of the logout PATCH. An older backend decodes `null` as `""` (no-op 2xx), so the flag is dropped, no retry loop.

## Requirement Traceability

| Requirement ID | Behavior | Android test (`NottiCoreTest`) | iOS test (`NottiCoreTests`) | Status |
| --- | --- | --- | --- | --- |
| DLOG-10 | logout sends null on the queue | `logout clears the external user id server-side and clears email and phone` | `test_logoutClearsTheExternalUserIdServerSideAndEnqueuesEmailAndPhoneNullClears` | Done |
| DLOG-11 | login then logout ends NULL | `logout called right after login leaves the device logged out`, `login queued before registration then logout still ends with the id cleared` | `test_logoutRightAfterLoginEndsWithTheClearAfterTheLogin`, `test_loginQueuedBeforeRegistrationThenLogoutStillEndsCleared` | Done |
| DLOG-12 | logout then login ends new id | `logout then login ends linked to the new user` | `test_logoutThenLoginEndsLinkedToTheNewUser` | Done |
| DLOG-13 | re-sent after failure / pre-init | `a failed logout clear is re-sent at the next registration`, `logout before initialize sends the clear once registration completes` | `test_aFailedLogoutClearIsResentAtTheNextRegistration`, `test_logoutBeforeInitializeClearsLocallyAndResendsTheNullsAtRegistration` | Done |
| DLOG-14 | tags and subscription untouched | asserted in the DLOG-10 test | asserted in the DLOG-10 test | Done |
| DLOG-15 | harmless against old server | by contract (old server answers 2xx no-op) | same | Done (no test: server-side behavior) |
| DLOG-22 | CHANGELOG + README | `CHANGELOG.md` `[Unreleased]`, README API table + storage keys | | Done |
