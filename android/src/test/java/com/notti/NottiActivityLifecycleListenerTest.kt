package com.notti

import android.app.Activity
import android.content.Intent
import android.content.SharedPreferences
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.JavaOnlyMap
import com.facebook.react.bridge.WritableMap
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements

/**
 * Intent/Bundle are backed by android.os.Bundle - unmockable on the plain
 * JVM without Robolectric, same reason as NottiFirebaseMessagingServiceTest.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], shadows = [ShadowArguments::class])
class NottiActivityLifecycleListenerTest {

  private lateinit var store: NottiEventStore

  @Before
  @After
  fun resetProcessWideState() {
    NottiNotificationClickRelay.reset()
    NottiActivityLifecycleListener.resetRegistrationForTest()
    // handle() routes click events through the companion singleton (the click
    // hook fires before any module exists on a cold start), which is
    // process-wide and outlives a single test - reset it and inject a store
    // backed by an in-memory fake so each case asserts against a clean queue.
    NottiModule.resetProcessWideStateForTest()
    store = NottiEventStore(FakeSharedPreferencesForLifecycle())
    NottiModule.setEventStoreForTest(store)
  }

  @Test
  fun `a cold-start click detected before any module exists is held for the JS pull, not replayed as an event`() {
    // Process start: the ContentProvider runs before any Activity, and long
    // before the lazy TurboModule is constructed (spec P3-AC7 - a tap from a
    // killed app). Nothing is attached to emit on yet.
    Robolectric.buildContentProvider(NottiInitProvider::class.java).create()

    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("plan", "vip")
    }
    Robolectric.buildActivity(Activity::class.java, intent).create().resume()

    val delivered = mutableListOf<ParsedNotification>()
    NottiNotificationClickRelay.attach { delivered.add(it) }

    // Attaching is the module being constructed during bundle evaluation -
    // still before any JS `addEventListener` has run, so an event emitted
    // here reaches nobody. The click must survive for the pull instead.
    assertEquals(emptyList<ParsedNotification>(), delivered)

    val pulled = NottiNotificationClickRelay.takePending()
    assertEquals("Hello", pulled?.title)
    assertEquals(mapOf("plan" to "vip"), pulled?.data)
    // Consumed exactly once.
    assertNull(NottiNotificationClickRelay.takePending())
  }

  @Test
  fun `registerOnce installs a single listener no matter how many times it runs`() {
    val application = RuntimeEnvironment.getApplication()
    repeat(3) { NottiActivityLifecycleListener.registerOnce(application) }

    val delivered = mutableListOf<ParsedNotification>()
    NottiNotificationClickRelay.attach { delivered.add(it) }

    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
    }
    Robolectric.buildActivity(Activity::class.java, intent).create().resume()

    // One tap, one event - repeated registration (the RN-reload shape, where
    // the module used to add a fresh listener per instance) must not multiply
    // emissions.
    assertEquals(1, delivered.size)
    assertTrue(delivered.single().title == "Hello")
  }

  @Test
  fun `the same click intent handled twice emits once and leaves the host app's extras intact`() {
    val delivered = mutableListOf<ParsedNotification>()
    NottiNotificationClickRelay.attach { delivered.add(it) }

    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("deep_link", "app://orders/42")
    }
    val activity = Robolectric.buildActivity(Activity::class.java, intent).create().get()
    val listener = NottiActivityLifecycleListener()

    listener.onActivityResumed(activity)
    listener.onActivityResumed(activity)

    // Exactly once per tap (spec SDK-18)...
    assertEquals(1, delivered.size)
    // ...without destroying the launching Intent the host app reads too: the
    // SDK used to wipe every extra to dedup, breaking the host's own
    // deep-link/extras handling.
    assertEquals("app://orders/42", activity.intent.getStringExtra("deep_link"))
    assertEquals("msg-1", activity.intent.getStringExtra("google.message_id"))
  }

  @Test
  fun `a second tap delivering a new intent to the same activity emits again`() {
    val delivered = mutableListOf<ParsedNotification>()
    NottiNotificationClickRelay.attach { delivered.add(it) }

    val activity = Robolectric.buildActivity(
      Activity::class.java,
      Intent().apply {
        putExtra("google.message_id", "msg-1")
        putExtra("gcm.n.title", "First")
      }
    ).create().get()
    val listener = NottiActivityLifecycleListener()
    listener.onActivityResumed(activity)

    // A real second tap arrives as a new Intent instance (onNewIntent /
    // setIntent) - dedup must not swallow it.
    activity.intent = Intent().apply {
      putExtra("google.message_id", "msg-2")
      putExtra("gcm.n.title", "Second")
    }
    listener.onActivityResumed(activity)

    assertEquals(listOf("First", "Second"), delivered.map { it.title })
  }

  @Test
  fun `parseClickIntentExtras extracts the payload when google message_id is present`() {
    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("gcm.n.body", "World")
      putExtra("plan", "vip")
    }

    val parsed = parseClickIntentExtras(intent)

    assertEquals(ParsedNotification(title = "Hello", body = "World", data = mapOf("plan" to "vip")), parsed)
  }

  @Test
  fun `parseClickIntentExtras keeps FCM's analytics labels out of the integrator's data`() {
    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      // FCM Analytics labels the SDK injects into the launch Intent. The
      // closed reserved-key list never named these, so they leaked into
      // payload.data on Android while iOS' prefix filter already dropped them.
      putExtra("google.c.a.e", "1")
      putExtra("google.c.a.c_id", "10123456789")
      putExtra("google.c.a.c_l", "campaign-label")
      putExtra("google.c.a.ts", "1717171717")
      putExtra("google.c.a.udt", "0")
      putExtra("google.c.a.m_l", "")
      putExtra("google.c.fid", "fid-token")
      putExtra("gcm.notification.e", "1")
      putExtra("from", "1234567890")
      putExtra("collapse_key", "com.example.app")
      // The integrator's own data - the only thing payload.data is for.
      putExtra("orderId", "42")
      putExtra("deep_link", "app://orders/42")
    }

    val parsed = parseClickIntentExtras(intent)

    assertEquals(
      mapOf("orderId" to "42", "deep_link" to "app://orders/42"),
      parsed?.data
    )
  }

  @Test
  fun `parseClickIntentExtras falls back to data title and body when gcm n title and gcm n body are absent`() {
    // FCM does not re-inject the notification block into the click Intent
    // once the system tray has already auto-displayed it for a combined
    // notification+data message - only `data` survives. Notti duplicates
    // title/body into `data` for this case.
    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("title", "Hello")
      putExtra("body", "World")
      putExtra("plan", "vip")
    }

    val parsed = parseClickIntentExtras(intent)

    assertEquals(
      ParsedNotification(title = "Hello", body = "World", data = mapOf("title" to "Hello", "body" to "World", "plan" to "vip")),
      parsed
    )
  }

  @Test
  fun `parseClickIntentExtras prefers gcm n title and gcm n body over data when both are present`() {
    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "From notification block")
      putExtra("gcm.n.body", "From notification block body")
      putExtra("title", "From data")
      putExtra("body", "From data body")
    }

    val parsed = parseClickIntentExtras(intent)

    assertEquals("From notification block", parsed?.title)
    assertEquals("From notification block body", parsed?.body)
  }

  @Test
  fun `parseClickIntentExtras returns null for a null intent or one with no extras at all`() {
    assertNull(parseClickIntentExtras(null))
    assertNull(parseClickIntentExtras(Intent()))
  }

  @Test
  fun `parseClickIntentExtras returns null on an unrelated launch even with other extras present`() {
    val intent = Intent().apply {
      putExtra("some_unrelated_key", "value")
    }

    assertNull(parseClickIntentExtras(intent))
  }

  @Test
  fun `parseClickIntentExtras skips a malformed null-valued extra without crashing`() {
    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("badKey", null as String?)
      putExtra("plan", "vip")
    }

    val parsed = parseClickIntentExtras(intent)

    assertEquals(mapOf("plan" to "vip"), parsed?.data)
  }

  @Test
  fun `a clicked notification carrying the SDK ids enqueues a clicked event`() {
    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("notification_id", "notif-1")
      putExtra("delivery_id", "delivery-1")
    }
    val activity = Robolectric.buildActivity(Activity::class.java, intent).create().get()
    val listener = NottiActivityLifecycleListener()

    listener.onActivityResumed(activity)

    val stored = store.all().single()
    assertEquals("notif-1", stored.notificationId)
    assertEquals("delivery-1", stored.deliveryId)
    assertEquals("clicked", stored.type)
  }

  @Test
  fun `a clicked notification without the SDK ids is not enqueued`() {
    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("plan", "vip")
    }
    val activity = Robolectric.buildActivity(Activity::class.java, intent).create().get()
    val listener = NottiActivityLifecycleListener()

    listener.onActivityResumed(activity)

    assertTrue(store.all().isEmpty())
  }

  // MARK: A1 (pre-release review round 3): click replay on Activity recreation

  @Test
  fun `onActivityCreated with a non-null savedInstanceState does not replay the click as a new event`() {
    val delivered = mutableListOf<ParsedNotification>()
    NottiNotificationClickRelay.attach { delivered.add(it) }

    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("notification_id", "notif-1")
      putExtra("delivery_id", "delivery-1")
    }
    val activity = Robolectric.buildActivity(Activity::class.java, intent).create().get()
    val listener = NottiActivityLifecycleListener()

    // A process restored from a system-initiated kill (not a real second
    // tap) redelivers the same launch Intent's extras to a *new* Activity
    // instance, so the identity-keyed Intent dedup below does not catch it -
    // `savedInstanceState != null` is the signal that this is a restore, not
    // a fresh tap.
    listener.onActivityCreated(activity, android.os.Bundle())

    assertTrue("a restored process must not inflate CTR with a phantom click", delivered.isEmpty())
    assertTrue("a restored process must not report a duplicate clicked event", store.all().isEmpty())
  }

  @Test
  fun `onActivityCreated with FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY does not replay the click as a new event`() {
    val delivered = mutableListOf<ParsedNotification>()
    NottiNotificationClickRelay.attach { delivered.add(it) }

    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("notification_id", "notif-1")
      putExtra("delivery_id", "delivery-1")
      addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
    }
    val activity = Robolectric.buildActivity(Activity::class.java, intent).create().get()
    val listener = NottiActivityLifecycleListener()

    // Reopening the host app from Android's Recents redelivers the same
    // launch Intent object/extras with this flag set, not a new user tap.
    listener.onActivityCreated(activity, null)

    assertTrue("reopening from Recents must not inflate CTR with a phantom click", delivered.isEmpty())
    assertTrue("reopening from Recents must not report a duplicate clicked event", store.all().isEmpty())
  }

  @Test
  fun `a real cold-start tap with no saved state and no history flag is still delivered via onActivityCreated`() {
    val delivered = mutableListOf<ParsedNotification>()
    NottiNotificationClickRelay.attach { delivered.add(it) }

    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("notification_id", "notif-1")
      putExtra("delivery_id", "delivery-1")
    }
    val activity = Robolectric.buildActivity(Activity::class.java, intent).create().get()
    val listener = NottiActivityLifecycleListener()

    listener.onActivityCreated(activity, null)

    assertEquals(1, delivered.size)
    assertEquals(1, store.all().size)
  }
}

/**
 * In-memory fake of [SharedPreferences] so the detection-site tests can inject
 * a store on the plain JVM without a real Android runtime - same shape as the
 * per-file fakes in NottiDeviceStoreTest/NottiEventStoreTest/NottiCoreTest,
 * renamed to avoid confusion.
 */
private class FakeSharedPreferencesForLifecycle : SharedPreferences {
  private val values = mutableMapOf<String, Any?>()

  override fun getAll(): MutableMap<String, *> = values.toMutableMap()

  override fun getString(key: String?, defValue: String?): String? =
    values[key] as? String ?: defValue

  override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
    throw UnsupportedOperationException("not used by the lifecycle tests")

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
      throw UnsupportedOperationException("not used by the lifecycle tests")

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

/**
 * `Arguments.createMap()` normally returns a JNI-backed `WritableNativeMap`,
 * which needs a real native library that isn't available on the plain JVM
 * Robolectric runs on - it would crash `handle()`'s `toWritableMap()` call
 * before ever reaching the dedup logic under test. This shadow swaps it for
 * `JavaOnlyMap`, RN's own pure-Java `WritableMap` implementation meant
 * exactly for this (unit tests with no native bridge), so the real
 * `NottiActivityLifecycleListener.handle()` can run end to end.
 */
@Implements(Arguments::class)
class ShadowArguments {
  companion object {
    @Implementation
    @JvmStatic
    fun createMap(): WritableMap = JavaOnlyMap()
  }
}
