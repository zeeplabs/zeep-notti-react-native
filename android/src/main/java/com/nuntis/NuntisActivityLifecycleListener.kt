package com.nuntis

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle

private const val GOOGLE_MESSAGE_ID_KEY = "google.message_id"
private const val NOTIFICATION_KEY_PREFIX = "gcm.n."
private val RESERVED_EXTRA_KEYS = setOf(
  "google.message_id", "google.sent_time", "google.ttl", "google.original_priority",
  "google.priority", "google.delivered_priority", "google.priority_reduced", "from",
  "collapse_key", "google.c.sender.id", "google.to"
)

/**
 * Pure parse of a launch/resume [Intent]'s extras into the SDK's
 * [NotificationPayload] shape (design.md) - mirrors T9's `parseRemoteMessage`
 * for the background/killed-state click path (`onMessageReceived` doesn't
 * fire reliably outside the foreground). Returns null unless FCM's reserved
 * `google.message_id` extra is present - a deterministic presence check, not
 * a heuristic, so this never misfires on an unrelated Activity launch/resume.
 */
fun parseClickIntentExtras(intent: Intent?): ParsedNotification? {
  val extras = intent?.extras ?: return null
  if (!extras.containsKey(GOOGLE_MESSAGE_ID_KEY)) return null

  var title: String? = null
  var body: String? = null
  val data = mutableMapOf<String, String>()
  for (key in extras.keySet()) {
    val value = extras.get(key)?.toString() ?: continue
    when {
      key == "gcm.n.title" -> title = value
      key == "gcm.n.body" -> body = value
      key.startsWith(NOTIFICATION_KEY_PREFIX) || key in RESERVED_EXTRA_KEYS -> Unit
      else -> data[key] = value
    }
  }
  return ParsedNotification(title = title, body = body, data = data)
}

/**
 * Detects a notification click that launched (cold start) or resumed
 * (background) the host Activity, without requiring integrator code -
 * Android's equivalent of the zero-`AppDelegate`-code goal (contrast: iOS
 * requires explicit forwarding per AD-002/T3). Clears the handled intent's
 * extras after firing so a later `onActivityResumed` for the same Activity
 * instance doesn't re-fire for the same tap.
 */
class NuntisActivityLifecycleListener : Application.ActivityLifecycleCallbacks {

  override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = handle(activity)
  override fun onActivityStarted(activity: Activity) = Unit
  override fun onActivityResumed(activity: Activity) = handle(activity)
  override fun onActivityPaused(activity: Activity) = Unit
  override fun onActivityStopped(activity: Activity) = Unit
  override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
  override fun onActivityDestroyed(activity: Activity) = Unit

  private fun handle(activity: Activity) {
    val intent = activity.intent
    val parsed = parseClickIntentExtras(intent) ?: return
    NuntisModule.emitNotificationClicked(parsed.toWritableMap())
    intent.replaceExtras(Bundle())
  }
}
