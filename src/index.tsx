import type { EventSubscription } from 'react-native';
import NativeNotti, { type NotificationPayload } from './NativeNotti';

// SPEC_DEVIATION: T4 replaced NativeNotti.ts's scaffolded `multiply` method
// with the real v1 Spec, orphaning the `multiply`/`multiply.native` files
// (removed). T16 now implements the real public facade below - a thin
// pass-through into NativeNotti per design.md's AD-001 (no business logic
// in TS).

export type { NotificationPayload };

export type NottiEventName = 'notificationReceived' | 'notificationClicked';

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
};

function initialize(appId: string, clientKey: string, baseUrl: string): void {
  NativeNotti.initialize(appId, clientKey, baseUrl);
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
  eventName: NottiEventName,
  callback: (payload: NotificationPayload) => void
): EventSubscription {
  switch (eventName) {
    case 'notificationReceived':
      return NativeNotti.onNotificationReceived(callback);
    case 'notificationClicked':
      return NativeNotti.onNotificationClicked(callback);
  }
}

export const Notti = {
  initialize,
  requestPermission,
  login,
  logout,
  setSubscription,
  getInitialNotificationClick,
  addEventListener,
  User,
};

export default Notti;
