import type { ConfigPlugin } from '@expo/config-plugins';
import {
  AndroidConfig,
  withEntitlementsPlist,
  withPlugins,
} from '@expo/config-plugins';

/**
 * Android side of the plugin (T17): the SDK's Android module talks to
 * Firebase Cloud Messaging directly (design.md's Integration Points), which
 * requires the Google Services Gradle plugin applied and the integrator's
 * own `google-services.json` copied into the native project - the same
 * manual steps bare-RN integrators perform per T19's README, done here on
 * `expo prebuild` instead. Relies on the integrator's `app.json`/`app.config`
 * already setting `android.googleServicesFile` (standard Expo convention -
 * `withGoogleServicesFile` reads that field, it is not this plugin's job to
 * invent a path).
 */
const withNuntisAndroid: ConfigPlugin = (config) => {
  config = AndroidConfig.GoogleServices.withClassPath(config);
  config = AndroidConfig.GoogleServices.withApplyPlugin(config);
  config = AndroidConfig.GoogleServices.withGoogleServicesFile(config);
  return config;
};

/**
 * iOS side of the plugin (T17): adds the `aps-environment` entitlement so
 * `expo prebuild` provisions the push-notification capability the SDK's
 * APNs delegate hooks (T15) depend on - the same capability bare-RN
 * integrators must add manually in Xcode per T19's README.
 */
const withNuntisIOS: ConfigPlugin = (config) => {
  return withEntitlementsPlist(config, (entitlementsConfig) => {
    entitlementsConfig.modResults['aps-environment'] = 'development';
    return entitlementsConfig;
  });
};

const withNuntis: ConfigPlugin = (config) => {
  return withPlugins(config, [withNuntisAndroid, withNuntisIOS]);
};

export default withNuntis;
