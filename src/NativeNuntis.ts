import {
  TurboModuleRegistry,
  type TurboModule,
  type CodegenTypes,
} from 'react-native';

export interface NotificationPayload {
  title?: string;
  body?: string;
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
}

export default TurboModuleRegistry.getEnforcing<Spec>('Nuntis');
