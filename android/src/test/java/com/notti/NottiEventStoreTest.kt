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
}