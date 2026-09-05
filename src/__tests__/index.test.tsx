import { beforeEach, describe, expect, it, jest } from '@jest/globals';

const mockInitialize = jest.fn();
const mockRequestPermission = jest.fn();
const mockLogin = jest.fn();
const mockLogout = jest.fn();
const mockAddTags = jest.fn();
const mockRemoveTags = jest.fn();
const mockSetSubscription = jest.fn();
const mockOnNotificationReceived = jest.fn();
const mockOnNotificationClicked = jest.fn();

jest.mock('../NativeNuntis', () => ({
  __esModule: true,
  default: {
    initialize: (...args: unknown[]) => mockInitialize(...args),
    requestPermission: (...args: unknown[]) => mockRequestPermission(...args),
    login: (...args: unknown[]) => mockLogin(...args),
    logout: (...args: unknown[]) => mockLogout(...args),
    addTags: (...args: unknown[]) => mockAddTags(...args),
    removeTags: (...args: unknown[]) => mockRemoveTags(...args),
    setSubscription: (...args: unknown[]) => mockSetSubscription(...args),
    onNotificationReceived: (...args: unknown[]) =>
      mockOnNotificationReceived(...args),
    onNotificationClicked: (...args: unknown[]) =>
      mockOnNotificationClicked(...args),
  },
}));

import { Nuntis } from '../index';

describe('Nuntis facade', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('initialize calls NativeNuntis.initialize with appId, clientKey, baseUrl', () => {
    Nuntis.initialize('app-1', 'key-1', 'https://push.example.com');
    expect(mockInitialize).toHaveBeenCalledWith(
      'app-1',
      'key-1',
      'https://push.example.com'
    );
  });

  it('requestPermission calls NativeNuntis.requestPermission and returns its result', async () => {
    mockRequestPermission.mockReturnValueOnce(Promise.resolve(true));
    const result = await Nuntis.requestPermission();
    expect(mockRequestPermission).toHaveBeenCalledWith();
    expect(result).toBe(true);
  });

  it('login calls NativeNuntis.login with the externalUserId', () => {
    Nuntis.login('user-42');
    expect(mockLogin).toHaveBeenCalledWith('user-42');
  });

  it('logout calls NativeNuntis.logout', () => {
    Nuntis.logout();
    expect(mockLogout).toHaveBeenCalledWith();
  });

  it('setSubscription calls NativeNuntis.setSubscription with the flag', () => {
    Nuntis.setSubscription(true);
    expect(mockSetSubscription).toHaveBeenCalledWith(true);
  });

  it('User.addTag funnels into NativeNuntis.addTags as a single-key map', () => {
    Nuntis.User.addTag('plan', 'vip');
    expect(mockAddTags).toHaveBeenCalledWith({ plan: 'vip' });
  });

  it('User.addTags calls NativeNuntis.addTags with the full map', () => {
    Nuntis.User.addTags({ plan: 'vip', region: 'br' });
    expect(mockAddTags).toHaveBeenCalledWith({ plan: 'vip', region: 'br' });
  });

  it('User.removeTag funnels into NativeNuntis.removeTags as a single-key array', () => {
    Nuntis.User.removeTag('plan');
    expect(mockRemoveTags).toHaveBeenCalledWith(['plan']);
  });

  it('User.removeTags calls NativeNuntis.removeTags with the full key list', () => {
    Nuntis.User.removeTags(['plan', 'region']);
    expect(mockRemoveTags).toHaveBeenCalledWith(['plan', 'region']);
  });

  it("addEventListener('notificationReceived', cb) subscribes via NativeNuntis.onNotificationReceived", () => {
    const callback = jest.fn();
    const subscription = { remove: jest.fn() };
    mockOnNotificationReceived.mockReturnValueOnce(subscription);

    const result = Nuntis.addEventListener('notificationReceived', callback);

    expect(mockOnNotificationReceived).toHaveBeenCalledWith(callback);
    expect(result).toBe(subscription);
  });

  it("addEventListener('notificationClicked', cb) subscribes via NativeNuntis.onNotificationClicked", () => {
    const callback = jest.fn();
    const subscription = { remove: jest.fn() };
    mockOnNotificationClicked.mockReturnValueOnce(subscription);

    const result = Nuntis.addEventListener('notificationClicked', callback);

    expect(mockOnNotificationClicked).toHaveBeenCalledWith(callback);
    expect(result).toBe(subscription);
  });
});
