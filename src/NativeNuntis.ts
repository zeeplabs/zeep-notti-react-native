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

  readonly onNotificationReceived: CodegenTypes.EventEmitter<NotificationPayload>;
  readonly onNotificationClicked: CodegenTypes.EventEmitter<NotificationPayload>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Nuntis');
