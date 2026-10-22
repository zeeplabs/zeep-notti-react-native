package com.notti

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Event types accepted by `POST .../in-app-messages/{id}/events`. */
object InAppEventType {
  const val IMPRESSION = "impression"
  const val CLICK = "click"
  const val DISMISS = "dismiss"
}

/**
 * An In-App event waiting to be reported. [id] is local to the queue;
 * [eventId] is the UUID v4 sent to the server (idempotency key). [appId] is
 * the app the event was created for, so a change of app id never sends an
 * event to a message of another app. No token and no device id are stored:
 * both are read at send time.
 */
data class InAppPendingEvent(
  val id: String,
  val eventId: String,
  val appId: String,
  val messageId: String,
  val type: String,
  val buttonId: String?,
  val reason: String?,
  val occurredAtMs: Long
)

/**
 * Persisted write-ahead queue of [InAppPendingEvent], a JSON array under one
 * key of `notti_prefs`. Independent of [NottiEventStore]: filling one never
 * evicts the other. Usable before any other component exists.
 */
class NottiInAppEventStore(
  private val prefs: SharedPreferences,
  private val clock: () -> Long = System::currentTimeMillis,
  private val uuid: () -> String = { UUID.randomUUID().toString() }
) {

  companion object {
    private const val KEY_PENDING_EVENTS = "notti_pending_inapp_events"

    /** At most 3 events per display, so 100 covers weeks offline. */
    const val MAX_PENDING_EVENTS = 100

    /** Events older than this (by `occurredAtMs`) are dropped. */
    const val TTL_MS = 7L * 24 * 60 * 60 * 1000

    /**
     * Process-wide lock around every read-modify-write: the main thread
     * enqueues while the in-app executor removes flushed records, and two
     * store instances can be built over the same prefs file.
     */
    private val LOCK = Any()
  }

  /**
   * Appends a new event, persisting immediately. Events already expired are
   * dropped first, then the oldest are dropped past [MAX_PENDING_EVENTS].
   */
  fun enqueue(
    appId: String,
    messageId: String,
    type: String,
    buttonId: String? = null,
    reason: String? = null
  ): InAppPendingEvent = synchronized(LOCK) {
    val now = clock()
    val event = InAppPendingEvent(
      id = uuid(),
      eventId = uuid(),
      appId = appId,
      messageId = messageId,
      type = type,
      buttonId = buttonId,
      reason = reason,
      occurredAtMs = now
    )
    val live = all().filterNot { isExpired(it, now) } + event
    write(if (live.size > MAX_PENDING_EVENTS) live.drop(live.size - MAX_PENDING_EVENTS) else live)
    event
  }

  /** Every queued event, in insertion order. */
  fun all(): List<InAppPendingEvent> = synchronized(LOCK) {
    val raw = prefs.getString(KEY_PENDING_EVENTS, null) ?: return emptyList()
    val parsed = parse(raw)
    if (parsed == null) {
      // Corrupted on disk: drop the unreadable queue so it self-heals.
      prefs.edit().remove(KEY_PENDING_EVENTS).apply()
      return emptyList()
    }
    parsed
  }

  /** Only the events created for [appId], in insertion order. */
  fun all(forApp: String): List<InAppPendingEvent> = all().filter { it.appId == forApp }

  /** Removes the event with [id], persisting the remaining queue. */
  fun remove(id: String) = synchronized(LOCK) {
    write(all().filterNot { it.id == id })
  }

  /**
   * Drops the events older than [TTL_MS] at [now] and returns them (so the
   * flush can log the drop). An event exactly [TTL_MS] old is kept.
   */
  fun expire(now: Long = clock()): List<InAppPendingEvent> = synchronized(LOCK) {
    val (expired, live) = all().partition { isExpired(it, now) }
    if (expired.isNotEmpty()) write(live)
    expired
  }

  /** Removes every event whose `appId` differs from [appId], keeping the order of the rest. */
  fun purgeOtherApps(appId: String) = synchronized(LOCK) {
    val current = all()
    val kept = current.filter { it.appId == appId }
    if (kept.size != current.size) write(kept)
  }

  private fun isExpired(event: InAppPendingEvent, now: Long): Boolean =
    now - event.occurredAtMs > TTL_MS

  /** `null` when [raw] is not a well-formed queue (caller clears it). */
  private fun parse(raw: String): List<InAppPendingEvent>? = try {
    val array = JSONArray(raw)
    buildList {
      for (i in 0 until array.length()) {
        val obj = array.getJSONObject(i)
        add(
          InAppPendingEvent(
            id = obj.getString("id"),
            eventId = obj.getString("eventId"),
            appId = obj.getString("appId"),
            messageId = obj.getString("messageId"),
            type = obj.getString("type"),
            buttonId = if (obj.has("buttonId")) obj.getString("buttonId") else null,
            reason = if (obj.has("reason")) obj.getString("reason") else null,
            occurredAtMs = obj.getLong("occurredAtMs")
          )
        )
      }
    }
  } catch (e: Exception) {
    null
  }

  private fun write(events: List<InAppPendingEvent>) {
    val array = JSONArray()
    events.forEach { event ->
      val obj = JSONObject()
        .put("id", event.id)
        .put("eventId", event.eventId)
        .put("appId", event.appId)
        .put("messageId", event.messageId)
        .put("type", event.type)
        .put("occurredAtMs", event.occurredAtMs)
      event.buttonId?.let { obj.put("buttonId", it) }
      event.reason?.let { obj.put("reason", it) }
      array.put(obj)
    }
    prefs.edit().putString(KEY_PENDING_EVENTS, array.toString()).apply()
  }
}
