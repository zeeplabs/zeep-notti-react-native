import type { EventSubscription } from 'react-native';
import NativeNuntis, { type NotificationPayload } from './NativeNuntis';

// SPEC_DEVIATION: T4 replaced NativeNuntis.ts's scaffolded `multiply` method
// with the real v1 Spec, orphaning the `multiply`/`multiply.native` files
// (removed). T16 now implements the real public facade below - a thin
// pass-through into NativeNuntis per design.md's AD-001 (no business logic
// in TS).

export type { NotificationPayload };

export type NuntisEventName = 'notificationReceived' | 'notificationClicked';

/**
 * Add/remove device tags used for Nuntis Segments. Single-key convenience
 * wrappers around the Spec's plural `addTags`/`removeTags` methods.
 */
const User = {
  addTag(key: string, value: string): void {
    NativeNuntis.addTags({ [key]: value });
  },

  addTags(tags: { [key: string]: string }): void {
    NativeNuntis.addTags(tags);
  },

  removeTag(key: string): void {
    NativeNuntis.removeTags([key]);
  },

  removeTags(keys: string[]): void {
    NativeNuntis.removeTags(keys);
  },
};

function initialize(appId: string, clientKey: string, baseUrl: string): void {
  NativeNuntis.initialize(appId, clientKey, baseUrl);
}

function requestPermission(): Promise<boolean> {
  return NativeNuntis.requestPermission();
}

function login(externalUserId: string): void {
  NativeNuntis.login(externalUserId);
}

function logout(): void {
  NativeNuntis.logout();
}

function setSubscription(enabled: boolean): void {
  NativeNuntis.setSubscription(enabled);
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
  eventName: NuntisEventName,
  callback: (payload: NotificationPayload) => void
): EventSubscription {
  switch (eventName) {
    case 'notificationReceived':
      return NativeNuntis.onNotificationReceived(callback);
    case 'notificationClicked':
      return NativeNuntis.onNotificationClicked(callback);
  }
}

export const Nuntis = {
  initialize,
  requestPermission,
  login,
  logout,
  setSubscription,
  addEventListener,
  User,
};

export default Nuntis;
