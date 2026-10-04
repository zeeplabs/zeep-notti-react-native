package com.notti

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * A single push-notification event record queued for reporting to the
 * backend. `id` is a local UUID assigned at enqueue time and never sent to
 * the backend - it only identifies the record inside the local queue so it
 * can be removed once reported. `type` is one of [NottiEventType].
 */
data class PendingEvent(
  val id: String,
  val notificationId: String,
  val deliveryId: String,
  val type: String,
  val createdAtMs: Long
)

/**
 * Event types accepted by `POST .../notifications/{id}/events`.
 *
 * - [RECEIVED]: the notification arrived while the app was in the foreground.
 * - [OPENED]: the user tapped the notification body (the app was opened from it).
 * - [CLICKED]: the user tapped the notification body (sent together with
 *   [OPENED]) or an action button. Android has no SDK-rendered action
 *   buttons yet, so here it always comes from the body tap.
 *
 * The backend counts a delivery as opened when it has an `opened` or a
 * `clicked` event, and as clicked only with a `clicked` event
 * (`.specs/features/opened-event-reporting/spec.md`).
 */
object NottiEventType {
  const val RECEIVED = "received"
  const val OPENED = "opened"
  const val CLICKED = "clicked"
}

/**
 * Persisted disk queue of [PendingEvent] records, backed by
 * [SharedPreferences]. Mirrors [NottiDeviceStore]'s persistence style: the
 * whole queue is encoded as a JSON array under a single key and rewritten
 * via `edit().apply()` on every mutation, so no query needs are introduced
 * for a bounded list.
 *
 * This store is a standalone primitive that must be usable before
 * [NottiCore] exists - event reporting (received/opened/clicked) queues offline
 * without depending on `NottiCore`, `NottiApiClient`, or
 * `NottiDeviceStore`. The reporting task composes this store with the rest
 * of the SDK.
 */
class NottiEventStore(private val prefs: SharedPreferences) {

  companion object {
    private const val KEY_PENDING_EVENTS = "notti_pending_events"

    /**
     * Bound on the queue, mirroring `NottiCore.MAX_PENDING_MUTATIONS`: an
     * offline device can accumulate events indefinitely, and an unbounded
     * queue would grow for the life of the install. When full the oldest
     * record (first in insertion order) is dropped.
     */
    private const val MAX_PENDING_EVENTS = 32

    /**
     * Process-wide lock around every read-modify-write of the queue. The
     * detection sites (FCM service thread, main thread for clicks) enqueue
     * while `notti-io` removes flushed records; each mutation is an
     * `all()` + `write()` pair, so without a lock two of them interleave and
     * the later `write()` silently discards the other's change (a lost event
     * or a resurrected one). Static rather than per-instance because
     * `NottiModule.getEventStore` can briefly build two instances over the
     * same `notti_prefs` file on a startup race.
     */
    private val LOCK = Any()
  }

  /**
   * Appends a new [PendingEvent] to the queue, persisting immediately.
   * Returns the stored record, whose [PendingEvent.id] is the local UUID to
   * pass to [remove] once the event has been reported.
   */
  fun enqueue(notificationId: String, deliveryId: String, type: String): PendingEvent = synchronized(LOCK) {
    val event = PendingEvent(
      id = UUID.randomUUID().toString(),
      notificationId = notificationId,
      deliveryId = deliveryId,
      type = type,
      createdAtMs = System.currentTimeMillis()
    )
    val events = all() + event
    val trimmed = if (events.size > MAX_PENDING_EVENTS) {
      events.drop(events.size - MAX_PENDING_EVENTS)
    } else {
      events
    }
    write(trimmed)
    event
  }

  /** Every not-yet-removed event, in insertion order. */
  fun all(): List<PendingEvent> = synchronized(LOCK) {
    val raw = prefs.getString(KEY_PENDING_EVENTS, null) ?: return emptyList()
    val parsed = parse(raw)
    if (parsed == null) {
      // Corrupted on disk (partial write, manual edit, schema drift): an
      // exception here would escape into the FCM service / flush path on
      // every call, forever. Drop the unreadable queue so it self-heals.
      prefs.edit().remove(KEY_PENDING_EVENTS).apply()
      return emptyList()
    }
    parsed
  }

  /** Removes the event with [id], persisting the remaining queue. */
  fun remove(id: String) = synchronized(LOCK) {
    write(all().filterNot { it.id == id })
  }

  /** `null` when [raw] is not a well-formed queue (caller clears it). */
  private fun parse(raw: String): List<PendingEvent>? = try {
    parseOrThrow(raw)
  } catch (e: Exception) {
    null
  }

  private fun parseOrThrow(raw: String): List<PendingEvent> {
    val array = JSONArray(raw)
    return buildList {
      for (i in 0 until array.length()) {
        val obj = array.getJSONObject(i)
        add(
          PendingEvent(
            id = obj.getString("id"),
            notificationId = obj.getString("notificationId"),
            deliveryId = obj.getString("deliveryId"),
            type = obj.getString("type"),
            createdAtMs = obj.getLong("createdAtMs")
          )
        )
      }
    }
  }

  private fun write(events: List<PendingEvent>) {
    val array = JSONArray()
    events.forEach { event ->
      array.put(
        JSONObject()
          .put("id", event.id)
          .put("notificationId", event.notificationId)
          .put("deliveryId", event.deliveryId)
          .put("type", event.type)
          .put("createdAtMs", event.createdAtMs)
      )
    }
    prefs.edit().putString(KEY_PENDING_EVENTS, array.toString()).apply()
  }
}