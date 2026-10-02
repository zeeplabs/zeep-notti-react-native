import { beforeEach, describe, expect, it, jest } from '@jest/globals';

const mockInitialize = jest.fn();
const mockRequestPermission = jest.fn();
const mockLogin = jest.fn();
const mockLogout = jest.fn();
const mockAddTags = jest.fn();
const mockRemoveTags = jest.fn();
const mockSetSubscription = jest.fn();
const mockSetLocationSharingEnabled = jest.fn();
const mockSetEmail = jest.fn();
const mockClearEmail = jest.fn();
const mockSetPhone = jest.fn();
const mockClearPhone = jest.fn();
const mockGetDeviceId = jest.fn();
const mockGetInitialNotificationClick = jest.fn();
const mockOnNotificationReceived = jest.fn();
const mockOnNotificationClicked = jest.fn();
const mockOnDeviceIdChanged = jest.fn();

jest.mock('../NativeNotti', () => ({
  __esModule: true,
  default: {
    initialize: (...args: unknown[]) => mockInitialize(...args),
    requestPermission: (...args: unknown[]) => mockRequestPermission(...args),
    login: (...args: unknown[]) => mockLogin(...args),
    logout: (...args: unknown[]) => mockLogout(...args),
    addTags: (...args: unknown[]) => mockAddTags(...args),
    removeTags: (...args: unknown[]) => mockRemoveTags(...args),
    setSubscription: (...args: unknown[]) => mockSetSubscription(...args),
    setLocationSharingEnabled: (...args: unknown[]) =>
      mockSetLocationSharingEnabled(...args),
    setEmail: (...args: unknown[]) => mockSetEmail(...args),
    clearEmail: (...args: unknown[]) => mockClearEmail(...args),
    setPhone: (...args: unknown[]) => mockSetPhone(...args),
    clearPhone: (...args: unknown[]) => mockClearPhone(...args),
    getDeviceId: (...args: unknown[]) => mockGetDeviceId(...args),
    getInitialNotificationClick: (...args: unknown[]) =>
      mockGetInitialNotificationClick(...args),
    onNotificationReceived: (...args: unknown[]) =>
      mockOnNotificationReceived(...args),
    onNotificationClicked: (...args: unknown[]) =>
      mockOnNotificationClicked(...args),
    onDeviceIdChanged: (...args: unknown[]) => mockOnDeviceIdChanged(...args),
  },
}));

jest.mock('react-native-notti/package.json', () => ({ version: '0.4.0' }));

import { Notti, type NotificationPayload } from '../index';

describe('Notti facade', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('initialize calls NativeNotti.initialize with appId, clientKey, baseUrl, sdkVersion', () => {
    Notti.initialize('app-1', 'key-1', {
      baseUrl: 'https://push.example.com',
    });
    expect(mockInitialize).toHaveBeenCalledWith(
      'app-1',
      'key-1',
      'https://push.example.com',
      '0.4.0'
    );
  });

  it('initialize defaults baseUrl to the SaaS instance when not passed', () => {
    Notti.initialize('app-1', 'key-1');
    expect(mockInitialize).toHaveBeenCalledWith(
      'app-1',
      'key-1',
      'https://app.zeepnotti.app',
      '0.4.0'
    );
  });

  it('initialize defaults baseUrl to the SaaS instance when options omit it', () => {
    Notti.initialize('app-1', 'key-1', {});
    expect(mockInitialize).toHaveBeenCalledWith(
      'app-1',
      'key-1',
      'https://app.zeepnotti.app',
      '0.4.0'
    );
  });

  it('initialize forwards an empty sdkVersion when the package version cannot be resolved', () => {
    jest.resetModules();
    jest.doMock('react-native-notti/package.json', () => ({}));
    const freshNotti = require('../index').Notti as typeof Notti;
    freshNotti.initialize('app-1', 'key-1', {
      baseUrl: 'https://push.example.com',
    });
    expect(mockInitialize).toHaveBeenCalledWith(
      'app-1',
      'key-1',
      'https://push.example.com',
      ''
    );
  });

  it('requestPermission calls NativeNotti.requestPermission and returns its result', async () => {
    mockRequestPermission.mockReturnValueOnce(Promise.resolve(true));
    const result = await Notti.requestPermission();
    expect(mockRequestPermission).toHaveBeenCalledWith();
    expect(result).toBe(true);
  });

  it('login calls NativeNotti.login with the externalUserId', () => {
    Notti.login('user-42');
    expect(mockLogin).toHaveBeenCalledWith('user-42');
  });

  it('logout calls NativeNotti.logout', () => {
    Notti.logout();
    expect(mockLogout).toHaveBeenCalledWith();
  });

  it('setSubscription calls NativeNotti.setSubscription with the flag', () => {
    Notti.setSubscription(true);
    expect(mockSetSubscription).toHaveBeenCalledWith(true);
  });

  it('setLocationSharingEnabled calls NativeNotti.setLocationSharingEnabled with the flag', () => {
    Notti.setLocationSharingEnabled(true);
    expect(mockSetLocationSharingEnabled).toHaveBeenCalledWith(true);
  });

  it('setLocationSharingEnabled forwards a false opt-out', () => {
    Notti.setLocationSharingEnabled(false);
    expect(mockSetLocationSharingEnabled).toHaveBeenCalledWith(false);
  });

  it('getDeviceId calls NativeNotti.getDeviceId and returns its result', () => {
    mockGetDeviceId.mockReturnValueOnce('device-123');
    const result = Notti.getDeviceId();
    expect(mockGetDeviceId).toHaveBeenCalledWith();
    expect(result).toBe('device-123');
  });

  it('getDeviceId returns null when not yet assigned', () => {
    mockGetDeviceId.mockReturnValueOnce(null);
    expect(Notti.getDeviceId()).toBeNull();
  });

  it('User.addTag funnels into NativeNotti.addTags as a single-key map', () => {
    Notti.User.addTag('plan', 'vip');
    expect(mockAddTags).toHaveBeenCalledWith({ plan: 'vip' });
  });

  it('User.addTags calls NativeNotti.addTags with the full map', () => {
    Notti.User.addTags({ plan: 'vip', region: 'br' });
    expect(mockAddTags).toHaveBeenCalledWith({ plan: 'vip', region: 'br' });
  });

  it('User.removeTag funnels into NativeNotti.removeTags as a single-key array', () => {
    Notti.User.removeTag('plan');
    expect(mockRemoveTags).toHaveBeenCalledWith(['plan']);
  });

  it('User.removeTags calls NativeNotti.removeTags with the full key list', () => {
    Notti.User.removeTags(['plan', 'region']);
    expect(mockRemoveTags).toHaveBeenCalledWith(['plan', 'region']);
  });

  it('User.setEmail delegates to NativeNotti.setEmail with the passed address', () => {
    Notti.User.setEmail('user@example.com');
    expect(mockSetEmail).toHaveBeenCalledWith('user@example.com');
  });

  it('User.clearEmail calls NativeNotti.clearEmail', () => {
    Notti.User.clearEmail();
    expect(mockClearEmail).toHaveBeenCalledWith();
  });

  it('User.setPhone delegates to NativeNotti.setPhone with the passed number', () => {
    Notti.User.setPhone('+5511999999999');
    expect(mockSetPhone).toHaveBeenCalledWith('+5511999999999');
  });

  it('User.clearPhone calls NativeNotti.clearPhone', () => {
    Notti.User.clearPhone();
    expect(mockClearPhone).toHaveBeenCalledWith();
  });

  it('getInitialNotificationClick calls NativeNotti.getInitialNotificationClick and returns its result', async () => {
    const payload = { title: 'hi', body: 'there', data: {} };
    mockGetInitialNotificationClick.mockReturnValueOnce(
      Promise.resolve(payload)
    );
    const result = await Notti.getInitialNotificationClick();
    expect(mockGetInitialNotificationClick).toHaveBeenCalledWith();
    expect(result).toBe(payload);
  });

  it('getInitialNotificationClick resolves null when the app was not cold-launched by a notification', async () => {
    mockGetInitialNotificationClick.mockReturnValueOnce(Promise.resolve(null));
    const result = await Notti.getInitialNotificationClick();
    expect(result).toBeNull();
  });

  // A1 contract: both platforms deliver JS `null` (never `undefined`) for a
  // missing title/body. The facade must pass it through untouched - no
  // coercion to `undefined`/'' that would break a consumer's `=== null` check.
  it('getInitialNotificationClick passes a null title/body through unchanged', async () => {
    const payload: NotificationPayload = {
      title: null,
      body: null,
      data: { notification_id: 'n-1' },
    };
    mockGetInitialNotificationClick.mockReturnValueOnce(
      Promise.resolve(payload)
    );
    const result = await Notti.getInitialNotificationClick();
    expect(result).toBe(payload);
    expect(result?.title).toBeNull();
    expect(result?.body).toBeNull();
  });

  it('notificationReceived/notificationClicked callbacks receive a null title/body unchanged', () => {
    const received = jest.fn();
    const clicked = jest.fn();
    Notti.addEventListener('notificationReceived', received);
    Notti.addEventListener('notificationClicked', clicked);

    const nativeReceived = mockOnNotificationReceived.mock.calls[0]?.[0] as (
      p: NotificationPayload
    ) => void;
    const nativeClicked = mockOnNotificationClicked.mock.calls[0]?.[0] as (
      p: NotificationPayload
    ) => void;
    const payload: NotificationPayload = { title: null, body: null, data: {} };
    nativeReceived(payload);
    nativeClicked(payload);

    expect(received).toHaveBeenCalledWith({
      title: null,
      body: null,
      data: {},
    });
    expect(clicked).toHaveBeenCalledWith({ title: null, body: null, data: {} });
  });

  it('exposes setLocationSharingEnabled on the public facade', () => {
    expect(typeof Notti.setLocationSharingEnabled).toBe('function');
  });

  it("addEventListener('notificationReceived', cb) subscribes via NativeNotti.onNotificationReceived", () => {
    const callback = jest.fn();
    const subscription = { remove: jest.fn() };
    mockOnNotificationReceived.mockReturnValueOnce(subscription);

    const result = Notti.addEventListener('notificationReceived', callback);

    expect(mockOnNotificationReceived).toHaveBeenCalledWith(callback);
    expect(result).toBe(subscription);
  });

  it("addEventListener('notificationClicked', cb) subscribes via NativeNotti.onNotificationClicked", () => {
    const callback = jest.fn();
    const subscription = { remove: jest.fn() };
    mockOnNotificationClicked.mockReturnValueOnce(subscription);

    const result = Notti.addEventListener('notificationClicked', callback);

    expect(mockOnNotificationClicked).toHaveBeenCalledWith(callback);
    expect(result).toBe(subscription);
  });

  it("addEventListener('deviceIdChanged', cb) subscribes via NativeNotti.onDeviceIdChanged", () => {
    const callback = jest.fn();
    const subscription = { remove: jest.fn() };
    mockOnDeviceIdChanged.mockReturnValueOnce(subscription);

    const result = Notti.addEventListener('deviceIdChanged', callback);

    expect(mockOnDeviceIdChanged).toHaveBeenCalledWith(callback);
    expect(result).toBe(subscription);
  });
});
