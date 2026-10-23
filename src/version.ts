/**
 * SDK package version, forwarded to native `initialize` as `sdk_version`.
 *
 * A literal on purpose: the earlier `require('react-native-notti/package.json')`
 * self-reference sat inside a `try/catch`, which Metro treats as an optional
 * dependency, so an unresolved require dropped the module silently and the
 * field was never sent. `version.test.ts` fails when this drifts from
 * `package.json`; `scripts/sync-sdk-version.js` rewrites it on release.
 */
export const SDK_VERSION = '0.8.0';
