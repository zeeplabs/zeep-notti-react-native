package com.notti

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle
import java.util.Collections
import java.util.WeakHashMap

private const val GOOGLE_MESSAGE_ID_KEY = "google.message_id"

/**
 * Transport metadata FCM injects into the launch Intent, which must never
 * reach `payload.data` - that map is the integrator's own custom data and
 * nothing else. Filtered by prefix rather than by an enumerated list, which
 * is what iOS does (`ios/NottiNotificationParsing.swift`): FCM's Analytics
 * labels (`google.c.a.e`, `google.c.a.c_id`, `google.c.a.c_l`,
 * `google.c.a.ts`, `google.c.a.udt`, `google.c.a.m_l`, `google.c.fid`, …)
 * are added and renamed by the FCM SDK over time, so any closed list leaks
 * whatever Google ships next. `aps.` is iOS/APNs-only and has no meaning
 * here, so it is deliberately not part of the Android policy.
 */
private val INTERNAL_EXTRA_PREFIXES = listOf("gcm.", "google.")
private val INTERNAL_EXTRA_KEYS = setOf("from", "collapse_key")

private fun isInternalExtraKey(key: String): Boolean =
  key in INTERNAL_EXTRA_KEYS || INTERNAL_EXTRA_PREFIXES.any { key.startsWith(it) }

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
      isInternalExtraKey(key) -> Unit
      else -> data[key] = value
    }
  }
  // `gcm.n.title`/`gcm.n.body` only exist when FCM re-injects the notification
  // block into the click Intent, which it does not do for a combined
  // notification+data message once the system tray already auto-displayed it
  // (see NottiFirebaseMessagingService's doc comment). Notti duplicates
  // title/body into `data` for exactly this case - fall back to that so the
  // click payload isn't null when the only source left is `data`. Left in
  // `data` too, matching the foreground shape (parseRemoteMessage doesn't
  // strip them out of `remoteMessage.data` either).
  return ParsedNotification(title = title ?: data["title"], body = body ?: data["body"], data = data)
}

/**
 * Detects a notification click that launched (cold start) or resumed
 * (background) the host Activity, without requiring integrator code -
 * Android's equivalent of the zero-`AppDelegate`-code goal (contrast: iOS
 * requires explicit forwarding per AD-002/T3). Each Intent instance is
 * emitted for at most once, so the `onActivityCreated` + `onActivityResumed`
 * pair (and any later resume/config change) can't re-fire the same tap.
 *
 * Registered exactly once per process by [NottiInitProvider] - not by
 * [NottiModule], which is lazily constructed after the launching Activity has
 * already read its intent (and reconstructed on every RN reload, which used to
 * stack a fresh listener per instance and multiply every click).
 */
class NottiActivityLifecycleListener : Application.ActivityLifecycleCallbacks {

  companion object {
    private val registered = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Idempotent: repeated calls (e.g. a second provider/process init) are no-ops. */
    fun registerOnce(application: Application) {
      if (registered.compareAndSet(false, true)) {
        application.registerActivityLifecycleCallbacks(NottiActivityLifecycleListener())
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
    NottiNotificationClickRelay.emit(parsed)
  }
}
