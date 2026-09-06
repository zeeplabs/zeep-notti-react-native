#import <NuntisSpec/NuntisSpec.h>
// Nuntis-Swift.h (imported by Nuntis.mm, generated from NuntisPushDelegate's
// UNUserNotificationCenterDelegate conformance) references UserNotifications
// types without importing the framework itself - it must already be visible
// by the time that generated header is parsed.
#import <UserNotifications/UserNotifications.h>

@interface Nuntis : NativeNuntisSpecBase <NativeNuntisSpec>

@end
