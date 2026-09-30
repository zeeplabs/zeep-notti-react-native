package com.notti

import android.content.SharedPreferences
import android.os.Bundle
import com.google.firebase.messaging.RemoteMessage
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * [RemoteMessage] is backed by [android.os.Bundle], which throws "not
 * mocked" on the plain JVM without Robolectric - this is the one test class
 * in the module that needs it, scoped narrowly per the class-level
 * [RunWith] rather than applied repo-wide.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NottiFirebaseMessagingServiceTest {

  private lateinit var store: NottiEventStore

  @Before
  @After
  fun resetProcessWideState() {
    // onMessageReceived routes through the companion singleton (the detection
    // sites fire before any module exists), which is process-wide and outlives
    // a single test - reset it and inject a store backed by an in-memory fake
    // so each case asserts against a clean queue.
    NottiModule.resetProcessWideStateForTest()
    store = NottiEventStore(FakeSharedPreferencesForMessaging())
    NottiModule.setEventStoreForTest(store)
  }

  @Test
  fun `parseRemoteMessage extracts title, body, and custom data`() {
    val bundle = Bundle().apply {
      putString("gcm.n.e", "1")
      putString("gcm.n.title", "Hello")
      putString("gcm.n.body", "World")
      putString("plan", "vip")
    }

    val parsed = parseRemoteMessage(RemoteMessage(bundle))

    assertEquals("Hello", parsed.title)
    assertEquals("World", parsed.body)
    assertEquals(mapOf("plan" to "vip"), parsed.data)
  }

  @Test
  fun `parseRemoteMessage handles a data-only message with no notification block`() {
    val bundle = Bundle().apply {
      putString("plan", "vip")
      putString("cohort", "beta")
    }

    val parsed = parseRemoteMessage(RemoteMessage(bundle))

    assertNull(parsed.title)
    assertNull(parsed.body)
    assertEquals(mapOf("plan" to "vip", "cohort" to "beta"), parsed.data)
  }

  @Test
  fun `parseRemoteMessage handles an empty message with no notification and no data`() {
    val parsed = parseRemoteMessage(RemoteMessage(Bundle()))

    assertNull(parsed.title)
    assertNull(parsed.body)
    assertEquals(emptyMap<String, String>(), parsed.data)
  }

  @Test
  fun `onMessageReceived enqueues a received event when notification_id and delivery_id are present`() {
    val service = NottiFirebaseMessagingService()
    val bundle = Bundle().apply {
      putString("gcm.n.e", "1")
      putString("gcm.n.title", "Hello")
      putString("notification_id", "notif-1")
      putString("delivery_id", "delivery-1")
      putString("plan", "vip")
    }

    service.onMessageReceived(RemoteMessage(bundle))

    val stored = store.all().single()
    assertEquals("notif-1", stored.notificationId)
    assertEquals("delivery-1", stored.deliveryId)
    assertEquals("received", stored.type)
  }

  @Test
  fun `onMessageReceived skips enqueue when the SDK ids are absent`() {
    val service = NottiFirebaseMessagingService()
    val bundle = Bundle().apply {
      putString("gcm.n.title", "Hello")
      putString("plan", "vip")
    }

    service.onMessageReceived(RemoteMessage(bundle))

    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `onMessageReceived skips enqueue when only one of the SDK ids is present`() {
    val service = NottiFirebaseMessagingService()
    val bundle = Bundle().apply {
      putString("notification_id", "notif-1")
    }

    service.onMessageReceived(RemoteMessage(bundle))

    assertTrue(store.all().isEmpty())
  }
}

/**
 * In-memory fake of [SharedPreferences] so the detection-site tests can inject
 * a store on the plain JVM without a real Android runtime - same shape as the
 * per-file fakes in NottiDeviceStoreTest/NottiEventStoreTest/NottiCoreTest,
 * renamed to avoid confusion.
 */
private class FakeSharedPreferencesForMessaging : SharedPreferences {
  private val values = mutableMapOf<String, Any?>()

  override fun getAll(): MutableMap<String, *> = values.toMutableMap()

  override fun getString(key: String?, defValue: String?): String? =
    values[key] as? String ?: defValue

  override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
    throw UnsupportedOperationException("not used by the messaging tests")

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
      throw UnsupportedOperationException("not used by the messaging tests")

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
