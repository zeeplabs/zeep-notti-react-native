import fs from 'fs';
import path from 'path';
import type { ConfigPlugin } from '@expo/config-plugins';
import {
  AndroidConfig,
  withAndroidColors,
  withAndroidManifest,
  withDangerousMod,
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
const withNottiAndroid: ConfigPlugin<NottiPluginProps | undefined> = (
  config,
  props
) => {
  config = AndroidConfig.GoogleServices.withClassPath(config);
  config = AndroidConfig.GoogleServices.withApplyPlugin(config);
  config = AndroidConfig.GoogleServices.withGoogleServicesFile(config);
  return withNottiAndroidNotification(config, props);
};

/** FCM reads these to style the tray notifications it displays itself. */
export const DEFAULT_NOTIFICATION_ICON_META =
  'com.google.firebase.messaging.default_notification_icon';
export const DEFAULT_NOTIFICATION_COLOR_META =
  'com.google.firebase.messaging.default_notification_color';
export const NOTIFICATION_ICON_RESOURCE = 'notti_notification_icon';
export const NOTIFICATION_COLOR_RESOURCE = 'notti_notification_color';

/**
 * Validates `androidNotificationColor` and normalizes it to the `#RRGGBB` /
 * `#AARRGGBB` form Android color resources accept. Throws on anything else so
 * a typo fails `expo prebuild` instead of shipping a gray circle.
 */
export function resolveAndroidNotificationColor(
  color: string | undefined
): string | undefined {
  if (color === undefined) return undefined;
  if (!/^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(color)) {
    throw new Error(
      `react-native-notti: androidNotificationColor must be #RRGGBB or #AARRGGBB, got "${color}"`
    );
  }
  return color.toUpperCase();
}

/**
 * Adds or removes the FCM default icon/color `<meta-data>` on the main
 * application. Pure over the parsed manifest so it is unit-testable; a
 * missing prop removes an entry this plugin wrote earlier, so dropping the
 * prop and re-running prebuild leaves no stale reference.
 */
export function setNotificationMetaData(
  manifest: AndroidConfig.Manifest.AndroidManifest,
  options: { icon: boolean; color: boolean }
): AndroidConfig.Manifest.AndroidManifest {
  const app = AndroidConfig.Manifest.getMainApplicationOrThrow(manifest);
  const entries: [string, string, boolean][] = [
    [
      DEFAULT_NOTIFICATION_ICON_META,
      `@drawable/${NOTIFICATION_ICON_RESOURCE}`,
      options.icon,
    ],
    [
      DEFAULT_NOTIFICATION_COLOR_META,
      `@color/${NOTIFICATION_COLOR_RESOURCE}`,
      options.color,
    ],
  ];
  for (const [name, value, enabled] of entries) {
    if (enabled) {
      AndroidConfig.Manifest.addMetaDataItemToMainApplication(
        app,
        name,
        value,
        'resource'
      );
    } else if (
      app['meta-data']?.some(
        (item) =>
          item.$['android:name'] === name &&
          item.$['android:resource'] === value
      )
    ) {
      AndroidConfig.Manifest.removeMetaDataItemFromMainApplication(app, name);
    }
  }
  return manifest;
}

/**
 * Copies the integrator's icon into `drawable-xxxhdpi` (Android scales it
 * down for lower densities). Only PNG: a vector or a full-color launcher
 * icon would need the integrator's own resource pipeline.
 */
export async function copyNotificationIconAsync(
  projectRoot: string,
  androidRoot: string,
  iconPath: string
): Promise<void> {
  const source = path.resolve(projectRoot, iconPath);
  if (path.extname(source).toLowerCase() !== '.png') {
    throw new Error(
      `react-native-notti: androidNotificationIcon must be a .png file, got "${iconPath}"`
    );
  }
  if (!fs.existsSync(source)) {
    throw new Error(
      `react-native-notti: androidNotificationIcon not found at "${source}"`
    );
  }
  const targetDir = path.join(androidRoot, 'app/src/main/res/drawable-xxxhdpi');
  await fs.promises.mkdir(targetDir, { recursive: true });
  await fs.promises.copyFile(
    source,
    path.join(targetDir, `${NOTIFICATION_ICON_RESOURCE}.png`)
  );
}

/**
 * Small icon and accent color of the notifications FCM shows in the tray.
 * Android draws the small icon from its alpha channel only, so without this
 * FCM falls back to the launcher icon and renders it as a white blob.
 */
const withNottiAndroidNotification: ConfigPlugin<
  NottiPluginProps | undefined
> = (config, props) => {
  const iconPath = props?.androidNotificationIcon;
  const color = resolveAndroidNotificationColor(
    props?.androidNotificationColor
  );

  if (iconPath) {
    config = withDangerousMod(config, [
      'android',
      async (modConfig) => {
        await copyNotificationIconAsync(
          modConfig.modRequest.projectRoot,
          modConfig.modRequest.platformProjectRoot,
          iconPath
        );
        return modConfig;
      },
    ]);
  }

  config = withAndroidColors(config, (colorsConfig) => {
    colorsConfig.modResults = color
      ? AndroidConfig.Colors.assignColorValue(colorsConfig.modResults, {
          name: NOTIFICATION_COLOR_RESOURCE,
          value: color,
        })
      : AndroidConfig.Colors.removeColorItem(
          NOTIFICATION_COLOR_RESOURCE,
          colorsConfig.modResults
        );
    return colorsConfig;
  });

  return withAndroidManifest(config, (manifestConfig) => {
    manifestConfig.modResults = setNotificationMetaData(
      manifestConfig.modResults,
      { icon: Boolean(iconPath), color: color !== undefined }
    );
    return manifestConfig;
  });
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
   *
   * Caveat (pre-release review, not yet verified on a real EAS build): EAS's
   * default `preview` profile uses `distribution: "internal"`, i.e. an ad hoc
   * provisioning profile, and ad hoc/App Store-signed apps talk to the
   * production APNs gateway. Xcode's archive export is expected to rewrite
   * `aps-environment` from the distribution profile, so the value written
   * here may not be what ends up in the signed binary. The README's "Expo
   * setup" section documents how to check (`codesign -d --entitlements`) and
   * how to pin this prop per profile; behavior is deliberately unchanged.
   */
  apsEnvironment?: 'development' | 'production';
  /**
   * Path (from the project root) to a PNG used as the Android notification
   * small icon: white shapes on a transparent background, 96x96 px. Copied to
   * `drawable-xxxhdpi/notti_notification_icon.png` and set as FCM's
   * `default_notification_icon`. Without it Android shows the launcher icon
   * as a white silhouette.
   */
  androidNotificationIcon?: string;
  /**
   * Accent color of the Android notification (`#RRGGBB` or `#AARRGGBB`), set
   * as FCM's `default_notification_color`. Android 12+ draws it as the
   * circle behind the small icon.
   */
  androidNotificationColor?: string;
};

/**
 * Resolves the `aps-environment` value written by the plugin. Pure (env is
 * passed in) so the exact rule is unit-testable: an explicit
 * `props.apsEnvironment` always wins; otherwise only the literal EAS profile
 * name `production` maps to `production`, everything else (including unset)
 * maps to `development`.
 */
export function resolveApsEnvironment(
  props: NottiPluginProps | undefined,
  easBuildProfile: string | undefined
): 'development' | 'production' {
  return (
    props?.apsEnvironment ??
    (easBuildProfile === 'production' ? 'production' : 'development')
  );
}

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
  const apsEnvironment = resolveApsEnvironment(
    props,
    process.env.EAS_BUILD_PROFILE
  );

  return withEntitlementsPlist(config, (entitlementsConfig) => {
    entitlementsConfig.modResults['aps-environment'] = apsEnvironment;
    return entitlementsConfig;
  });
};

const withNotti: ConfigPlugin<NottiPluginProps | undefined> = (
  config,
  props
) => {
  return withPlugins(config, [
    [withNottiAndroid, props],
    [withNottiIOS, props],
  ]);
};

export default withNotti;
