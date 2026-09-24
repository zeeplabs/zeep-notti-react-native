// Expo config-plugin entry point (per Expo's config-plugin convention:
// https://docs.expo.dev/config-plugins/plugins/#creating-a-plugin). Points
// at the compiled output of plugin/src/withNotti.ts (T17).
module.exports = require('./plugin/build/withNotti').default;
