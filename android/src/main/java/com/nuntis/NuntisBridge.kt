package com.nuntis

import com.google.firebase.messaging.RemoteMessage

/**
 * Public entry points for a host app that owns its own `FirebaseMessagingService`
 * and wants to forward FCM callbacks into Nuntis manually, instead of relying
 * on this library's own manifest-declared `NuntisFirebaseMessagingService`.
 * Android only delivers an FCM message to one registered service per app, so
 * an app that already has its own service (for any reason -- another push
 * provider, a shared notification pipeline, etc.) cannot also register a
 * second one from this library.
 *
 * Mirrors iOS's `NuntisBridge` (`ios/NuntisPushDelegate.swift`), which already
 * exposes its callbacks as plain `public static` methods callable from any
 * host `AppDelegate` without Nuntis owning `UNUserNotificationCenter`'s
 * delegate slot. This closes the same gap on Android: before this, the
 * equivalent logic (`NuntisModule.emitNotificationReceived`/`activeCore`) was
 * `internal`, unreachable from outside this Gradle module.
 */
object NuntisBridge {

  /** Call from your own `FirebaseMessagingService.onMessageReceived`. */
  @JvmStatic
  fun onMessageReceived(remoteMessage: RemoteMessage) {
    NuntisModule.emitNotificationReceived(parseRemoteMessage(remoteMessage).toWritableMap())
  }

  /** Call from your own `FirebaseMessagingService.onNewToken`. */
  @JvmStatic
  fun onNewToken(token: String) {
    NuntisModule.activeCore?.onTokenRefreshed(token)
  }
}
