# Segment Telemetry Reporting Context

**Gathered:** 2026-09-30
**Spec:** `.specs/features/segment-telemetry-reporting/spec.md`
**Status:** Ready for design

---

## Feature Boundary

Native-only bookkeeping on both platforms (Android/iOS) that captures and reports, via the existing device PATCH mutation-queue path, three groups of telemetry: (P1) the host app's version string, (P2) a lightweight foreground/background session lifecycle producing `first_session_at`/`last_session_at`/`session_count`/`session_time`, and (P3) an opt-in reverse-geocoded `country` (ISO 3166-1 alpha-2). Backend contract (6 new `devices` columns + PATCH acceptance + clearing) is owned by the closed companion spec `device-telemetry-fields` in `zeep-notti`. No new transport; batched with other pending device mutations.

---

## Implementation Decisions

### Session scope & approach

- Design + Tasks + Execute complete in this session (same flow as `ctr-event-reporting`).
- Full session lifecycle is native-only; P1/P2 add **no** JS-visible API (preserves `AD-001`). P3 adds exactly one JS toggle, below.

### P3 location opt-in API

- Name/shape: **`ZeepNotti.setLocationSharingEnabled(enabled: boolean)`**, default `false`.
- Persisted locally (survives app restarts) until the integrator calls it again.
- The SDK never requests OS location permission; it only reads if the host app has already granted it.

### P3 precision

- **Country only** (ISO 3166-1 alpha-2), reverse-geocoded on-device.
- No raw lat/long ever leaves the device; no coordinate column on the backend (companion spec already matches).
- Stale/cached fix acceptable at country-level granularity.

### Read cadence

- One best-effort location read per session start (P2's hook), only if opted in and permission already granted.
- Missing/denied permission → silently omit the field, never prompt, never error.

---

## Agent's Discretion

- Exact storage layout for session/version state (reuse `NottiDeviceStore` vs. dedicated store) — follow existing SDK persistence patterns.
- How session end is estimated on unclean kill (force-quit/crash) — use last known foreground timestamp per spec AC4.
- Widget/extension/background-fetch exclusion mechanics on iOS.

---

## Specific References

- No "I want it like X" product references beyond the spec; behavior mirrors OneSignal's point-in-time fields and reuses the SDK's existing mutation-queue/PATCH flow.

---

## Deferred Ideas

- Precise/truncated lat/long reporting (would require a new backend column + SDK read policy) — explicitly out of scope per spec.
- Session precision beyond foreground/background (sub-screen sessions) — out of scope.
- Semver-aware `app_version` comparison — out of scope (backend does `eq`/`neq`/`exists` only).