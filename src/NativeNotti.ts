import {
  TurboModuleRegistry,
  type TurboModule,
  type CodegenTypes,
} from 'react-native';

export interface NotificationPayload {
  // A1 (found in pre-release review): both platforms deliver a JS `null` for
  // a missing title/body (iOS boxes an absent value as NSNull, Android
  // `putString(key, null)`), never `undefined` - a consumer checking
  // `=== undefined` got the wrong answer.
  title?: string | null;
  body?: string | null;
  data?: { [key: string]: string };
}

export interface Spec extends TurboModule {
  initialize(appId: string, clientKey: string, baseUrl: string): void;
  requestPermission(): Promise<boolean>;
  login(externalUserId: string): void;
  logout(): void;
  addTags(tags: { [key: string]: string }): void;
  removeTags(keys: string[]): void;
  setSubscription(enabled: boolean): void;

  /**
   * Returns the Notti-internal Device ID used by the Notti backend to route
   * notifications to this device, or `null` if not yet assigned. The value
   * is cached natively and populated asynchronously after
   * `initialize`/`login` complete a round-trip with the Notti backend - it
   * is not guaranteed to be available immediately. See ADR-001
   * (docs/adr/001-expose-device-id-getter-and-change-event.md).
   */
  getDeviceId(): string | null;

  /**
   * Returns the notification the app was cold-launched from by the user
   * tapping it, if any - and only once: the native side clears it after
   * this resolves. Must exist because the click that launches the process
   * happens before any JS listener can possibly be registered (the JS
   * bundle hasn't run `addEventListener` yet, sometimes hasn't even been
   * evaluated) - `onNotificationClicked` below fires only for clicks that
   * land while JS is already alive to receive them. Mirrors
   * `getInitialNotification()` in react-native-firebase/Notifee for the
   * same reason: an EventEmitter has no buffering for a subscriber that
   * doesn't exist yet, so cold-start delivery has to be pull-based.
   */
  getInitialNotificationClick(): Promise<NotificationPayload | null>;

  readonly onNotificationReceived: CodegenTypes.EventEmitter<NotificationPayload>;
  readonly onNotificationClicked: CodegenTypes.EventEmitter<NotificationPayload>;

  /**
   * Fires when the Device ID is assigned for the first time or updated
   * (reinstall, device change, revocation/renewal by the Notti backend).
   */
  readonly onDeviceIdChanged: CodegenTypes.EventEmitter<string>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Notti');
