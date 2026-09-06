package com.nuntis

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle
import java.util.Collections
import java.util.WeakHashMap

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
 * requires explicit forwarding per AD-002/T3). Each Intent instance is
 * emitted for at most once, so the `onActivityCreated` + `onActivityResumed`
 * pair (and any later resume/config change) can't re-fire the same tap.
 *
 * Registered exactly once per process by [NuntisInitProvider] - not by
 * [NuntisModule], which is lazily constructed after the launching Activity has
 * already read its intent (and reconstructed on every RN reload, which used to
 * stack a fresh listener per instance and multiply every click).
 */
class NuntisActivityLifecycleListener : Application.ActivityLifecycleCallbacks {

  companion object {
    private val registered = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Idempotent: repeated calls (e.g. a second provider/process init) are no-ops. */
    fun registerOnce(application: Application) {
      if (registered.compareAndSet(false, true)) {
        application.registerActivityLifecycleCallbacks(NuntisActivityLifecycleListener())
      }
    }

    /** Test-only: this is process-wide state that outlives a single test case. */
    internal fun resetRegistrationForTest() = registered.set(false)
  }

  override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = handle(activity)
  override fun onActivityStarted(activity: Activity) = Unit
  override fun onActivityResumed(activity: Activity) = handle(activity)
  override fun onActivityPaused(activity: Activity) = Unit
  override fun onActivityStopped(activity: Activity) = Unit
  override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
  override fun onActivityDestroyed(activity: Activity) = Unit

  /**
   * Identity-keyed record of the Intent instances already emitted for. This
   * used to be done by wiping the intent's extras (`replaceExtras(Bundle())`),
   * which destroyed the host app's own launch data - its deep-link/extras
   * handling reads the same intent. Weak keys so a finished Activity's intent
   * is collectable; a genuinely new tap arrives as a new Intent instance
   * (`Activity.setIntent`) and is emitted normally.
   */
  private val handledIntents: MutableSet<Intent> =
    Collections.newSetFromMap(WeakHashMap<Intent, Boolean>())

  private fun handle(activity: Activity) {
    val intent = activity.intent ?: return
    val parsed = parseClickIntentExtras(intent) ?: return
    val firstTimeForThisIntent = synchronized(handledIntents) { handledIntents.add(intent) }
    if (!firstTimeForThisIntent) return
    // Buffered when no module is attached yet - the cold-start case, where
    // this runs before the lazy TurboModule is ever constructed (P3-AC7).
    NuntisNotificationClickRelay.emit(parsed)
  }
}
