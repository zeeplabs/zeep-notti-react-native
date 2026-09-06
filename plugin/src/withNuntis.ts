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

export type NuntisPluginProps = {
  /**
   * `aps-environment` entitlement value. Defaults to inferring from
   * `EAS_BUILD_PROFILE` (EAS Build sets this env var during `eas build`;
   * any profile other than `development` is treated as `production`).
   * Builds run outside EAS (a local/manual `expo prebuild` + Xcode archive)
   * have no such signal, so pass this explicitly for those release builds -
   * otherwise the entitlement silently defaults to the sandbox APNs
   * environment and production push does not work.
   */
  apsEnvironment?: 'development' | 'production';
};

/**
 * iOS side of the plugin (T17): adds the `aps-environment` entitlement so
 * `expo prebuild` provisions the push-notification capability the SDK's
 * APNs delegate hooks (T15) depend on - the same capability bare-RN
 * integrators must add manually in Xcode per T19's README.
 */
const withNuntisIOS: ConfigPlugin<NuntisPluginProps | undefined> = (
  config,
  props
) => {
  const apsEnvironment =
    props?.apsEnvironment ??
    (process.env.EAS_BUILD_PROFILE &&
    process.env.EAS_BUILD_PROFILE !== 'development'
      ? 'production'
      : 'development');

  return withEntitlementsPlist(config, (entitlementsConfig) => {
    entitlementsConfig.modResults['aps-environment'] = apsEnvironment;
    return entitlementsConfig;
  });
};

const withNuntis: ConfigPlugin<NuntisPluginProps | undefined> = (
  config,
  props
) => {
  return withPlugins(config, [withNuntisAndroid, [withNuntisIOS, props]]);
};

export default withNuntis;
