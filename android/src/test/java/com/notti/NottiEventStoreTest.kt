package com.notti

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * In-memory fake of [SharedPreferences] so [NottiEventStore] can be tested
 * on the plain JVM without Robolectric or a real Android runtime - the
 * interfaces exercised here (SharedPreferences/Editor) have no android.jar
 * stub bodies to throw at test time, only a HashMap-backed fake
 * implementation is needed.
 */
private class FakeSharedPreferencesEventStore : SharedPreferences {
  private val values = mutableMapOf<String, Any?>()

  override fun getAll(): MutableMap<String, *> = values.toMutableMap()

  override fun getString(key: String?, defValue: String?): String? =
    values[key] as? String ?: defValue

  override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
    throw UnsupportedOperationException("not used by NottiEventStore")

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
      throw UnsupportedOperationException("not used by NottiEventStore")

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

class NottiEventStoreTest {

  private lateinit var prefs: SharedPreferences
  private lateinit var store: NottiEventStore

  @Before
  fun setUp() {
    prefs = FakeSharedPreferencesEventStore()
    store = NottiEventStore(prefs)
  }

  @Test
  fun `enqueue then all returns the stored record`() {
    val event = store.enqueue("notif-1", "delivery-1", "received")

    val stored = store.all().single()
    assertEquals(event.id, stored.id)
    assertEquals("notif-1", stored.notificationId)
    assertEquals("delivery-1", stored.deliveryId)
    assertEquals("received", stored.type)
  }

  @Test
  fun `remove then all no longer contains the removed record`() {
    val event = store.enqueue("notif-1", "delivery-1", "clicked")

    store.remove(event.id)

    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `enqueue past the cap drops the oldest records first`() {
    val ids = (0 until 33).map { store.enqueue("notif-$it", "delivery-$it", "received").id }

    val all = store.all()
    assertEquals(32, all.size)
    assertTrue(all.none { it.id == ids.first() })
    assertTrue(all.any { it.id == ids.last() })
    assertEquals("notif-32", all.last().notificationId)
  }

  @Test
  fun `a fresh store over the same SharedPreferences sees previously enqueued events`() {
    store.enqueue("notif-1", "delivery-1", "clicked")
    store.enqueue("notif-2", "delivery-2", "received")

    val freshStore = NottiEventStore(prefs)

    val all = freshStore.all()
    assertEquals(2, all.size)
    assertEquals("notif-1", all[0].notificationId)
    assertEquals("notif-2", all[1].notificationId)
  }

  @Test
  fun `corrupted JSON on disk yields an empty queue and is cleared, never a throw`() {
    prefs.edit().putString("notti_pending_events", "{not json").apply()

    assertTrue(store.all().isEmpty())
    // Cleared, so a later enqueue starts from a clean queue instead of
    // re-failing the parse forever.
    assertEquals(null, prefs.getString("notti_pending_events", null))
    store.enqueue("notif-1", "delivery-1", "clicked")
    assertEquals(1, store.all().size)
  }

  @Test
  fun `a record missing a required field is treated as corruption, not a throw`() {
    prefs.edit().putString("notti_pending_events", """[{"id":"x"}]""").apply()

    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `concurrent enqueue and remove never lose an event`() {
    // Widen the read-modify-write window so an unsynchronized all()+write()
    // loses updates deterministically rather than by luck.
    val slowPrefs = SlowThreadSafePrefs()
    val racingStore = NottiEventStore(slowPrefs)
    val seed = (0 until 8).map { racingStore.enqueue("seed-$it", "d-$it", "received") }

    val start = java.util.concurrent.CountDownLatch(1)
    val enqueuer = Thread {
      start.await()
      repeat(16) { racingStore.enqueue("new-$it", "d-$it", "clicked") }
    }
    val remover = Thread {
      start.await()
      seed.forEach { racingStore.remove(it.id) }
    }
    enqueuer.start(); remover.start()
    start.countDown()
    enqueuer.join(10_000); remover.join(10_000)

    val remaining = racingStore.all()
    assertEquals(16, remaining.size)
    assertTrue(remaining.all { it.notificationId.startsWith("new-") })
  }
}

/** Thread-safe in-memory prefs whose reads yield, to expose lost updates. */
private class SlowThreadSafePrefs : SharedPreferences {
  private val values = java.util.concurrent.ConcurrentHashMap<String, Any>()
  override fun getAll(): MutableMap<String, *> = HashMap(values)
  override fun getString(key: String?, defValue: String?): String? {
    val v = values[key] as? String
    Thread.sleep(2)
    return v ?: defValue
  }
  override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? = defValues
  override fun getInt(key: String?, defValue: Int) = values[key] as? Int ?: defValue
  override fun getLong(key: String?, defValue: Long) = values[key] as? Long ?: defValue
  override fun getFloat(key: String?, defValue: Float) = values[key] as? Float ?: defValue
  override fun getBoolean(key: String?, defValue: Boolean) = values[key] as? Boolean ?: defValue
  override fun contains(key: String?) = values.containsKey(key)
  override fun edit(): SharedPreferences.Editor = Editor()
  override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
  override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

  private inner class Editor : SharedPreferences.Editor {
    private val pending = mutableMapOf<String, Any?>()
    private val removals = mutableSetOf<String>()
    override fun putString(key: String?, value: String?) = apply { pending[key!!] = value }
    override fun putStringSet(key: String?, v: MutableSet<String>?) = apply { pending[key!!] = v }
    override fun putInt(key: String?, value: Int) = apply { pending[key!!] = value }
    override fun putLong(key: String?, value: Long) = apply { pending[key!!] = value }
    override fun putFloat(key: String?, value: Float) = apply { pending[key!!] = value }
    override fun putBoolean(key: String?, value: Boolean) = apply { pending[key!!] = value }
    override fun remove(key: String?) = apply { removals.add(key!!) }
    override fun clear() = apply { removals.addAll(values.keys) }
    override fun commit(): Boolean { apply(); return true }
    override fun apply() {
      removals.forEach { values.remove(it) }
      pending.forEach { (k, v) -> if (v == null) values.remove(k) else values[k] = v }
    }
  }
}
