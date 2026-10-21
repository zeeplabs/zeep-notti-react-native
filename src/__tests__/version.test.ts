import { describe, expect, it } from '@jest/globals';
import { SDK_VERSION } from '../version';

const pkg = require('../../package.json') as { version: string };

describe('SDK_VERSION', () => {
  it('matches package.json (run scripts/sync-sdk-version.js after a bump)', () => {
    expect(SDK_VERSION).toBe(pkg.version);
  });

  it('is semver-shaped', () => {
    expect(SDK_VERSION).toMatch(/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/);
  });
});
