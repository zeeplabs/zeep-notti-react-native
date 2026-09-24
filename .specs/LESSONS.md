# LESSONS - auto-maintained by scripts/lessons.py

> Machine-owned. Do NOT hand-edit. Changes are overwritten on the next `lessons.py` write.
> Canonical state lives in `.specs/lessons.json`. Edit lessons only via the script.
> promote_threshold=2 distinct features · window_days=45 · quarantine_threshold=2

## Confirmed (load these at Specify/Design)

Corroborated across multiple features. Safe to apply as guidance.

_none_

## Candidates (under observation - do NOT load as guidance yet)

Seen once or not yet corroborated. Tracked, not trusted.

### L-001 - A thin facade layer's mocked call-argument test does not substitute for a business-logic test of the layer it delegates to - test the layer that actually implements the acceptance criterion, not just the layer that calls it.
- signal: `ac_gap` · recurrence: 1 feature(s) · scope: `test-coverage` · harmful: 0
- features: sdk-core-v1
- evidence: SDK-14,SDK-15,SDK-16 (test-coverage)
- last seen: 2026-09-06T00:25:37Z

### L-002 - A task's own completion note claiming a property is proven must be independently re-derived by the Verifier, not trusted - a presence-check test on a pure parsing function does not prove a stateful dedup/exactly-once property.
- signal: `ac_gap` · recurrence: 1 feature(s) · scope: `verification` · harmful: 0
- features: sdk-core-v1
- evidence: android/src/test/java/com/notti/NottiActivityLifecycleListenerTest.kt (SDK-18) (verification)
- last seen: 2026-09-06T00:25:37Z

### L-003 - Every MockWebServer.takeRequest() call must pass an explicit (timeout, TimeUnit) argument - an unbounded call is a live test-hang risk even while currently passing.
- signal: `gate_fail` · recurrence: 1 feature(s) · scope: `android-tests` · harmful: 0
- features: sdk-core-v1
- evidence: android/src/test/java/com/notti/NottiApiClientTest.kt:46,71 (android-tests)
- last seen: 2026-09-06T00:25:37Z

## Quarantined (failed when applied - ignore)

A confirmed lesson that recurred alongside failure. Kept for the maintainer to review.

_none_
