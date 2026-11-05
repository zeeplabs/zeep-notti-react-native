import { describe, expect, it } from '@jest/globals';

const pkg = require('../../package.json') as {
  exports: Record<string, unknown>;
  files: string[];
};

// Expo resolves the config plugin as `react-native-notti/app.plugin.js`; with an
// `exports` map, a subpath missing from it makes Expo SDK 58+ warn at prebuild.
describe('package exports', () => {
  it('exposes the Expo config plugin entry', () => {
    expect(pkg.exports['./app.plugin.js']).toBe('./app.plugin.js');
    expect(pkg.files).toContain('app.plugin.js');
  });
});
