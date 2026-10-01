import { describe, expect, it } from '@jest/globals';
import { resolveApsEnvironment } from '../../plugin/src/withNotti';

// Pins the A7 rule documented in README "Expo setup": only the literal EAS
// profile `production` gets `aps-environment=production` by default; an
// explicit `apsEnvironment` prop always wins.
describe('resolveApsEnvironment', () => {
  it('maps the literal `production` EAS profile to production', () => {
    expect(resolveApsEnvironment(undefined, 'production')).toBe('production');
  });

  it.each(['preview', 'staging', 'development', 'simulator', 'Production'])(
    'maps EAS profile %p to development',
    (profile) => {
      expect(resolveApsEnvironment(undefined, profile)).toBe('development');
    }
  );

  it('maps an unset EAS profile (local prebuild) to development', () => {
    expect(resolveApsEnvironment(undefined, undefined)).toBe('development');
    expect(resolveApsEnvironment({}, undefined)).toBe('development');
  });

  it('lets an explicit apsEnvironment prop override the EAS profile', () => {
    expect(
      resolveApsEnvironment({ apsEnvironment: 'production' }, 'preview')
    ).toBe('production');
    expect(
      resolveApsEnvironment({ apsEnvironment: 'development' }, 'production')
    ).toBe('development');
  });
});
