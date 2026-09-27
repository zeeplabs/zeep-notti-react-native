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
const withNottiAndroid: ConfigPlugin = (config) => {
  config = AndroidConfig.GoogleServices.withClassPath(config);
  config = AndroidConfig.GoogleServices.withApplyPlugin(config);
  config = AndroidConfig.GoogleServices.withGoogleServicesFile(config);
  return config;
};

export type NottiPluginProps = {
  /**
   * `aps-environment` entitlement value. Defaults to inferring from
   * `EAS_BUILD_PROFILE` (EAS Build sets this env var during `eas build`):
   * only the literal `production` profile gets the production entitlement,
   * every other value (`preview`, `staging`, `simulator`, `development`, or
   * unset) gets `development`. Deliberately default-safe (A7, found in
   * pre-release review): the previous logic treated anything *other than*
   * `development` as production, so common non-development EAS profiles
   * (`preview`, `staging`) - usually built with a dev client and a sandbox
   * APNs token - silently received the production entitlement, and push
   * stopped working with no build error at all. Builds run outside EAS (a
   * local/manual `expo prebuild` + Xcode archive) have no such signal, so
   * pass this explicitly for those release builds.
   */
  apsEnvironment?: 'development' | 'production';
};

/**
 * iOS side of the plugin (T17): adds the `aps-environment` entitlement so
 * `expo prebuild` provisions the push-notification capability the SDK's
 * APNs delegate hooks (T15) depend on - the same capability bare-RN
 * integrators must add manually in Xcode per T19's README.
 */
const withNottiIOS: ConfigPlugin<NottiPluginProps | undefined> = (
  config,
  props
) => {
  const apsEnvironment =
    props?.apsEnvironment ??
    (process.env.EAS_BUILD_PROFILE === 'production'
      ? 'production'
      : 'development');

  return withEntitlementsPlist(config, (entitlementsConfig) => {
    entitlementsConfig.modResults['aps-environment'] = apsEnvironment;
    return entitlementsConfig;
  });
};

const withNotti: ConfigPlugin<NottiPluginProps | undefined> = (
  config,
  props
) => {
  return withPlugins(config, [withNottiAndroid, [withNottiIOS, props]]);
};

export default withNotti;
