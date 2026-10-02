import type { EventSubscription } from 'react-native';
import NativeNotti, { type NotificationPayload } from './NativeNotti';

// SPEC_DEVIATION: T4 replaced NativeNotti.ts's scaffolded `multiply` method
// with the real v1 Spec, orphaning the `multiply`/`multiply.native` files
// (removed). T16 now implements the real public facade below - a thin
// pass-through into NativeNotti per design.md's AD-001 (no business logic
// in TS).

export type { NotificationPayload };

export type NottiEventName =
  'notificationReceived' | 'notificationClicked' | 'deviceIdChanged';

/**
 * Add/remove device tags used for Notti Segments. Single-key convenience
 * wrappers around the Spec's plural `addTags`/`removeTags` methods.
 */
const User = {
  addTag(key: string, value: string): void {
    NativeNotti.addTags({ [key]: value });
  },

  addTags(tags: { [key: string]: string }): void {
    NativeNotti.addTags(tags);
  },

  removeTag(key: string): void {
    NativeNotti.removeTags([key]);
  },

  removeTags(keys: string[]): void {
    NativeNotti.removeTags(keys);
  },

  setEmail(email: string): void {
    NativeNotti.setEmail(email);
  },

  clearEmail(): void {
    NativeNotti.clearEmail();
  },

  setPhone(phone: string): void {
    NativeNotti.setPhone(phone);
  },

  clearPhone(): void {
    NativeNotti.clearPhone();
  },
};

/** Default `baseUrl` for Notti's SaaS mode. Self-hosted deployments must pass their own. */
const SAAS_BASE_URL = 'https://app.zeepnotti.app';

/**
 * The SDK package version, resolved once at module load from the package
 * manifest (`./package.json` is exported, so the version is readable at
 * runtime). Forwarded to native `initialize` as `sdk_version` - the package
 * version is the single source of truth, and a native hardcoded copy would
 * drift across releases. Passed as a constant, not business logic (AD-001).
 * On any resolution failure (bundler edge case), an empty string is passed
 * and native treats it as `null` -> the field is omitted.
 */
const SDK_VERSION: string = (() => {
  try {
    const pkg = require('react-native-notti/package.json') as {
      version?: string;
    };
    return typeof pkg.version === 'string' ? pkg.version : '';
  } catch {
    return '';
  }
})();

export interface InitializeOptions {
  /**
   * Overrides the default SaaS `baseUrl` - required for self-hosted Notti
   * instances and for testing against a sandbox instance.
   */
  baseUrl?: string;
}

function initialize(
  appId: string,
  clientKey: string,
  options: InitializeOptions = {}
): void {
  NativeNotti.initialize(
    appId,
    clientKey,
    options.baseUrl ?? SAAS_BASE_URL,
    SDK_VERSION
  );
}

function requestPermission(): Promise<boolean> {
  return NativeNotti.requestPermission();
}

function login(externalUserId: string): void {
  NativeNotti.login(externalUserId);
}

function logout(): void {
  NativeNotti.logout();
}

function setSubscription(enabled: boolean): void {
  NativeNotti.setSubscription(enabled);
}

/**
 * Opt-in toggle for country-based segment targeting. Defaults to `false`.
 * The SDK never requests OS location permission itself; it only reads the
 * device's country at the next session start when the host app has already
 * granted permission. Calling with `false` clears any previously-synced
 * country value server-side. This is the one deliberate JS-visible addition
 * in the segment-telemetry feature (AD-001 exception for privacy-critical
 * opt-in).
 */
function setLocationSharingEnabled(enabled: boolean): void {
  NativeNotti.setLocationSharingEnabled(enabled);
}

/**
 * Returns the Notti-internal Device ID, cached natively, or `null` if not
 * yet assigned. See ADR-001
 * (docs/adr/001-expose-device-id-getter-and-change-event.md).
 */
function getDeviceId(): string | null {
  return NativeNotti.getDeviceId();
}

/**
 * Resolves with the notification that cold-launched the app (the user
 * tapped it while the app wasn't running), or `null` if the app was not
 * launched this way. Call this once on startup, before or alongside
 * wiring `addEventListener('notificationClicked', ...)` - it is the only
 * reliable way to observe that specific click, since no JS listener can
 * exist early enough to catch it via the event instead.
 */
function getInitialNotificationClick(): Promise<NotificationPayload | null> {
  return NativeNotti.getInitialNotificationClick();
}

/**
 * Subscribes to a Codegen-declared native event. Mirrors the Spec's
 * `onNotificationReceived`/`onNotificationClicked` EventEmitter properties
 * (each already a directly-callable `(handler) => EventSubscription`
 * function under React Native 0.85's New Architecture EventEmitter codegen
 * - no `NativeEventEmitter` wrapping needed) behind a JS-friendly,
 * string-named API.
 */
function addEventListener(
  eventName: 'notificationReceived' | 'notificationClicked',
  callback: (payload: NotificationPayload) => void
): EventSubscription;
function addEventListener(
  eventName: 'deviceIdChanged',
  callback: (deviceId: string) => void
): EventSubscription;
function addEventListener(
  eventName: NottiEventName,
  callback: (payload: any) => void
): EventSubscription {
  switch (eventName) {
    case 'notificationReceived':
      return NativeNotti.onNotificationReceived(callback);
    case 'notificationClicked':
      return NativeNotti.onNotificationClicked(callback);
    case 'deviceIdChanged':
      return NativeNotti.onDeviceIdChanged(callback);
  }
}

export const Notti = {
  initialize,
  requestPermission,
  login,
  logout,
  setSubscription,
  setLocationSharingEnabled,
  getDeviceId,
  getInitialNotificationClick,
  addEventListener,
  User,
};

export default Notti;
