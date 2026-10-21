package com.notti

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class FakeSharedPreferencesInAppStore : SharedPreferences {
  private val values = mutableMapOf<String, Any?>()

  override fun getAll(): MutableMap<String, *> = values.toMutableMap()

  override fun getString(key: String?, defValue: String?): String? =
    values[key] as? String ?: defValue

  override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
    throw UnsupportedOperationException("not used by NottiInAppEventStore")

  override fun getInt(key: String?, defValue: Int): Int =
    values[key] as? Int ?: defValue

  override fun getLong(key: String?, defValue: Long): Long =
    values[key] as? Long ?: defValue

  override fun getFloat(key: String?, defValue: Float): Float =
    values[key] as? Float ?: defValue

  override fun getBoolean(key: String?, defValue: Boolean): Boolean =
    values[key] as? Boolean ?: defValue

  override fun contains(key: String?): Boolean = values.containsKey(key)

  override fun edit(): SharedPreferences.Editor = FakeEditor()

  override fun registerOnSharedPreferenceChangeListener(
    listener: SharedPreferences.OnSharedPreferenceChangeListener?
  ) = Unit

  override fun unregisterOnSharedPreferenceChangeListener(
    listener: SharedPreferences.OnSharedPreferenceChangeListener?
  ) = Unit

  private inner class FakeEditor : SharedPreferences.Editor {
    private val pending = mutableMapOf<String, Any?>()
    private val removals = mutableSetOf<String>()
    private var shouldClear = false

    override fun putString(key: String?, value: String?): SharedPreferences.Editor {
      pending[key!!] = value
      return this
    }

    override fun putStringSet(key: String?, values: MutableSet<String>?): SharedPreferences.Editor =
      throw UnsupportedOperationException("not used by NottiInAppEventStore")

    override fun putInt(key: String?, value: Int): SharedPreferences.Editor {
      pending[key!!] = value
      return this
    }

    override fun putLong(key: String?, value: Long): SharedPreferences.Editor {
      pending[key!!] = value
      return this
    }

    override fun putFloat(key: String?, value: Float): SharedPreferences.Editor {
      pending[key!!] = value
      return this
    }

    override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor {
      pending[key!!] = value
      return this
    }

    override fun remove(key: String?): SharedPreferences.Editor {
      removals.add(key!!)
      return this
    }

    override fun clear(): SharedPreferences.Editor {
      shouldClear = true
      return this
    }

    override fun commit(): Boolean {
      apply()
      return true
    }

    override fun apply() {
      if (shouldClear) values.clear()
      removals.forEach { values.remove(it) }
      values.putAll(pending)
    }
  }
}

class NottiInAppEventStoreTest {

  private val appId = "00000000-0000-0000-0000-0000000000a1"
  private val otherApp = "00000000-0000-0000-0000-0000000000a2"
  private val messageId = "00000000-0000-0000-0000-0000000000b1"
  private val day = 24L * 60 * 60 * 1000

  private lateinit var prefs: SharedPreferences
  private var now = 1_000_000_000_000L
  private lateinit var store: NottiInAppEventStore

  @Before
  fun setUp() {
    prefs = FakeSharedPreferencesInAppStore()
    store = NottiInAppEventStore(prefs, clock = { now })
  }

  @Test
  fun `enqueue persists the full record and no token or device id`() {
    val event = store.enqueue(appId, messageId, InAppEventType.CLICK, buttonId = "btn")

    val stored = store.all().single()
    assertEquals(event, stored)
    assertEquals(appId, stored.appId)
    assertEquals(messageId, stored.messageId)
    assertEquals("click", stored.type)
    assertEquals("btn", stored.buttonId)
    assertNull(stored.reason)
    assertEquals(now, stored.occurredAtMs)
    val raw = prefs.getString("notti_pending_inapp_events", null)!!
    assertTrue(!raw.contains("token") && !raw.contains("device"))
  }

  @Test
  fun `dismiss keeps its reason and impression has neither button nor reason`() {
    store.enqueue(appId, messageId, InAppEventType.DISMISS, reason = "close_button")
    store.enqueue(appId, messageId, InAppEventType.IMPRESSION)

    val (dismiss, impression) = store.all()
    assertEquals("close_button", dismiss.reason)
    assertNull(impression.buttonId)
    assertNull(impression.reason)
  }

  @Test
  fun `event ids are unique UUIDs, stable across reads and across a new instance`() {
    val first = NottiInAppEventStore(prefs, clock = { now }).enqueue(appId, messageId, "impression")
    val second = store.enqueue(appId, messageId, "impression")

    assertNotEquals(first.eventId, second.eventId)
    assertNotEquals(first.id, second.id)
    assertEquals(36, first.eventId.length)
    assertEquals('4', first.eventId[14])
    val reread = NottiInAppEventStore(prefs, clock = { now }).all()
    assertEquals(listOf(first.eventId, second.eventId), reread.map { it.eventId })
    assertEquals(store.all().map { it.eventId }, reread.map { it.eventId })
  }

  @Test
  fun `all returns insertion order and remove deletes only that record`() {
    val a = store.enqueue(appId, "m1", "impression")
    val b = store.enqueue(appId, "m2", "impression")
    val c = store.enqueue(appId, "m3", "impression")
    assertEquals(listOf(a.id, b.id, c.id), store.all().map { it.id })

    store.remove(b.id)

    assertEquals(listOf(a.id, c.id), store.all().map { it.id })
  }

  @Test
  fun `cap of 100 drops the oldest first`() {
    val ids = (0 until 101).map { store.enqueue(appId, "m$it", "impression").id }

    val stored = store.all()
    assertEquals(100, stored.size)
    assertEquals(ids.drop(1), stored.map { it.id })
  }

  @Test
  fun `expire drops only the events older than 7 days and returns them`() {
    val old = store.enqueue(appId, "old", "impression")
    now += day
    val recent = store.enqueue(appId, "recent", "impression")

    val dropped = store.expire(old.occurredAtMs + 7 * day + 1)

    assertEquals(listOf(old.id), dropped.map { it.id })
    assertEquals(listOf(recent.id), store.all().map { it.id })
  }

  @Test
  fun `an event exactly 7 days old is kept and one millisecond older is dropped`() {
    val event = store.enqueue(appId, messageId, "impression")

    assertTrue(store.expire(event.occurredAtMs + 7 * day).isEmpty())
    assertEquals(1, store.all().size)
    assertEquals(listOf(event.id), store.expire(event.occurredAtMs + 7 * day + 1).map { it.id })
    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `enqueue drops events that already expired`() {
    store.enqueue(appId, "old", "impression")
    now += 7 * day + 1

    val fresh = store.enqueue(appId, "fresh", "impression")

    assertEquals(listOf(fresh.id), store.all().map { it.id })
  }

  @Test
  fun `a corrupt blob self-heals to empty and the queue works again`() {
    prefs.edit().putString("notti_pending_inapp_events", "not json").apply()
    assertTrue(store.all().isEmpty())
    assertNull(prefs.getString("notti_pending_inapp_events", null))

    prefs.edit().putString("notti_pending_inapp_events", "[{\"id\": \"x\"}]").apply()
    assertTrue(store.all().isEmpty())

    store.enqueue(appId, messageId, "impression")
    assertEquals(1, store.all().size)
  }

  @Test
  fun `purgeOtherApps removes records of other apps and keeps the order of the rest`() {
    val a1 = store.enqueue(appId, "m1", "impression")
    store.enqueue(otherApp, "m2", "impression")
    val a2 = store.enqueue(appId, "m3", "click", buttonId = "b")
    store.enqueue(otherApp, "m4", "dismiss", reason = "auto")

    store.purgeOtherApps(appId)

    assertEquals(listOf(a1.id, a2.id), store.all().map { it.id })
  }

  @Test
  fun `all forApp never returns another app's records`() {
    val mine = store.enqueue(appId, "m1", "impression")
    store.enqueue(otherApp, "m2", "impression")

    assertEquals(listOf(mine.id), store.all(appId).map { it.id })
    assertEquals(1, store.all(otherApp).size)
    assertTrue(store.all("unknown").isEmpty())
  }

  @Test
  fun `appId round trips through a new instance`() {
    store.enqueue(otherApp, messageId, "impression")

    assertEquals(otherApp, NottiInAppEventStore(prefs, clock = { now }).all().single().appId)
  }

  @Test
  fun `filling the in-app queue never evicts the push event queue and vice versa`() {
    val push = NottiEventStore(prefs)
    push.enqueue("notif", "delivery", "received")
    repeat(101) { store.enqueue(appId, "m$it", "impression") }
    assertEquals(1, push.all().size)
    assertEquals(100, store.all().size)

    repeat(40) { push.enqueue("n$it", "d$it", "received") }
    assertEquals(32, push.all().size)
    assertEquals(100, store.all().size)
  }
}
