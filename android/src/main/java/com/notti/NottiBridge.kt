package com.notti

import com.google.firebase.messaging.RemoteMessage

/**
 * Public entry points for a host app that owns its own `FirebaseMessagingService`
 * and wants to forward FCM callbacks into Notti manually, instead of relying
 * on this library's own manifest-declared `NottiFirebaseMessagingService`.
 * Android only delivers an FCM message to one registered service per app, so
 * an app that already has its own service (for any reason -- another push
 * provider, a shared notification pipeline, etc.) cannot also register a
 * second one from this library.
 *
 * Mirrors iOS's `NottiBridge` (`ios/NottiPushDelegate.swift`), which already
 * exposes its callbacks as plain `public static` methods callable from any
 * host `AppDelegate` without Notti owning `UNUserNotificationCenter`'s
 * delegate slot. This closes the same gap on Android: before this, the
 * equivalent logic (`NottiModule.emitNotificationReceived`/`activeCore`) was
 * `internal`, unreachable from outside this Gradle module.
 */
object NottiBridge {

  /** Call from your own `FirebaseMessagingService.onMessageReceived`. */
  @JvmStatic
  fun onMessageReceived(remoteMessage: RemoteMessage) {
    NottiModule.emitNotificationReceived(parseRemoteMessage(remoteMessage).toWritableMap())
  }

  /** Call from your own `FirebaseMessagingService.onNewToken`. */
  @JvmStatic
  fun onNewToken(token: String) {
    NottiModule.activeCore?.onTokenRefreshed(token)
  }
}
