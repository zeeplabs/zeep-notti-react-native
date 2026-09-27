#import <NottiSpec/NottiSpec.h>
#import <React/RCTInvalidating.h>
// Notti-Swift.h (imported by Notti.mm, generated from NottiPushDelegate's
// UNUserNotificationCenterDelegate conformance) references UserNotifications
// types without importing the framework itself - it must already be visible
// by the time that generated header is parsed.
#import <UserNotifications/UserNotifications.h>

@interface Notti : NativeNottiSpecBase <NativeNottiSpec, RCTInvalidating>

@end
