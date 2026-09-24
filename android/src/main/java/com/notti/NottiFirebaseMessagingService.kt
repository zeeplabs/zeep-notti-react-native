package com.notti

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableMap
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/** Pure, unit-testable parse of a [RemoteMessage] into the SDK's [NotificationPayload] shape. */
data class ParsedNotification(val title: String?, val body: String?, val data: Map<String, String>)

fun parseRemoteMessage(remoteMessage: RemoteMessage): ParsedNotification = ParsedNotification(
  title = remoteMessage.notification?.title,
  body = remoteMessage.notification?.body,
  data = remoteMessage.data
)

internal fun ParsedNotification.toWritableMap(): WritableMap {
  val map = Arguments.createMap()
  map.putString("title", title)
  map.putString("body", body)
  val dataMap = Arguments.createMap()
  data.forEach { (key, value) -> dataMap.putString(key, value) }
  map.putMap("data", dataMap)
  return map
}

/**
 * Receives FCM token refresh and foreground data/notification messages
 * (design.md). Notti always sends a `notification` payload, so Android's
 * system tray auto-displays it while backgrounded/killed -
 * [onMessageReceived] only fires reliably in the foreground; background/
 * killed-state click detection is handled separately (T10, via the launch
 * Intent's extras), not here.
 */
class NottiFirebaseMessagingService : FirebaseMessagingService() {

  override fun onNewToken(token: String) {
    NottiModule.activeCore?.onTokenRefreshed(token)
  }

  override fun onMessageReceived(remoteMessage: RemoteMessage) {
    NottiModule.emitNotificationReceived(parseRemoteMessage(remoteMessage).toWritableMap())
  }
}
