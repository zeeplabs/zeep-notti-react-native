import { beforeEach, describe, expect, it, jest } from '@jest/globals';

const mockInitialize = jest.fn();
const mockRequestPermission = jest.fn();
const mockLogin = jest.fn();
const mockLogout = jest.fn();
const mockAddTags = jest.fn();
const mockRemoveTags = jest.fn();
const mockSetSubscription = jest.fn();
const mockGetInitialNotificationClick = jest.fn();
const mockOnNotificationReceived = jest.fn();
const mockOnNotificationClicked = jest.fn();

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
    getInitialNotificationClick: (...args: unknown[]) =>
      mockGetInitialNotificationClick(...args),
    onNotificationReceived: (...args: unknown[]) =>
      mockOnNotificationReceived(...args),
    onNotificationClicked: (...args: unknown[]) =>
      mockOnNotificationClicked(...args),
  },
}));

import { Notti } from '../index';

describe('Notti facade', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('initialize calls NativeNotti.initialize with appId, clientKey, baseUrl', () => {
    Notti.initialize('app-1', 'key-1', {
      baseUrl: 'https://push.example.com',
    });
    expect(mockInitialize).toHaveBeenCalledWith(
      'app-1',
      'key-1',
      'https://push.example.com'
    );
  });

  it('initialize defaults baseUrl to the SaaS instance when not passed', () => {
    Notti.initialize('app-1', 'key-1');
    expect(mockInitialize).toHaveBeenCalledWith(
      'app-1',
      'key-1',
      'https://app.zeepnotti.app'
    );
  });

  it('initialize defaults baseUrl to the SaaS instance when options omit it', () => {
    Notti.initialize('app-1', 'key-1', {});
    expect(mockInitialize).toHaveBeenCalledWith(
      'app-1',
      'key-1',
      'https://app.zeepnotti.app'
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
});
