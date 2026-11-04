package com.notti

import com.google.firebase.messaging.RemoteMessage

/**
 * Deprecated 0.8.0 entry points for a host app that owns its own
 * `FirebaseMessagingService` (android-native-sdk G2, ANSDK-11). Same JVM
 * signatures as 0.8.0, so existing Kotlin and Java services still compile;
 * each call forwards to the native SDK's `com.zeeplabs.notti.NottiBridge`,
 * which runs the same code as the SDK's own service.
 *
 * Difference from 0.8.0: [onMessageReceived] now also queues the `received`
 * event for delivery reporting (0.8.0's bridge only emitted the JS event).
 *
 * A host that keeps its own service must remove the SDK's with
 * `tools:node="remove"` on `com.zeeplabs.notti.NottiFirebaseMessagingService`
 * (the 0.8.0 `com.notti` class no longer exists). Removal no earlier than 1.0
 * (design OQ-7).
 */
@Deprecated(
  message = "Use com.zeeplabs.notti.NottiBridge, which this object forwards to.",
  replaceWith = ReplaceWith("NottiBridge", "com.zeeplabs.notti.NottiBridge"),
  level = DeprecationLevel.WARNING
)
object NottiBridge {

  /** Where the calls go; the native bridge in production, a fake in tests. */
  internal interface Target {
    fun onMessageReceived(remoteMessage: RemoteMessage)
    fun onNewToken(token: String)
  }

  internal object NativeTarget : Target {
    override fun onMessageReceived(remoteMessage: RemoteMessage) =
      com.zeeplabs.notti.NottiBridge.onMessageReceived(remoteMessage)

    override fun onNewToken(token: String) = com.zeeplabs.notti.NottiBridge.onNewToken(token)
  }

  @Volatile
  internal var target: Target = NativeTarget

  /** Call from your own `FirebaseMessagingService.onMessageReceived`. */
  @Deprecated(
    message = "Use com.zeeplabs.notti.NottiBridge.onMessageReceived.",
    replaceWith = ReplaceWith("NottiBridge.onMessageReceived(remoteMessage)", "com.zeeplabs.notti.NottiBridge"),
    level = DeprecationLevel.WARNING
  )
  @JvmStatic
  fun onMessageReceived(remoteMessage: RemoteMessage) {
    target.onMessageReceived(remoteMessage)
  }

  /** Call from your own `FirebaseMessagingService.onNewToken`. */
  @Deprecated(
    message = "Use com.zeeplabs.notti.NottiBridge.onNewToken.",
    replaceWith = ReplaceWith("NottiBridge.onNewToken(token)", "com.zeeplabs.notti.NottiBridge"),
    level = DeprecationLevel.WARNING
  )
  @JvmStatic
  fun onNewToken(token: String) {
    target.onNewToken(token)
  }
}
