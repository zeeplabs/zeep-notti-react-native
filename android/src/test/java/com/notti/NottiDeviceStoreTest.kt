package com.notti

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * In-memory fake of [SharedPreferences] so [NottiDeviceStore] can be tested
 * on the plain JVM without Robolectric or a real Android runtime — the
 * interfaces exercised here (SharedPreferences/Editor) have no
 * android.jar stub bodies to throw at test time, only a HashMap-backed
 * fake implementation is needed.
 */
private class FakeSharedPreferences : SharedPreferences {
  private val values = mutableMapOf<String, Any?>()

  /** Keys written through a synchronous `commit()` (vs fire-and-forget `apply()`). */
  val committedKeys = mutableSetOf<String>()

  override fun getAll(): MutableMap<String, *> = values.toMutableMap()

  override fun getString(key: String?, defValue: String?): String? =
    values[key] as? String ?: defValue

  override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
    throw UnsupportedOperationException("not used by NottiDeviceStore")

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
      throw UnsupportedOperationException("not used by NottiDeviceStore")

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
      committedKeys.addAll(pending.keys)
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

class NottiDeviceStoreTest {

  private lateinit var prefs: FakeSharedPreferences
  private lateinit var store: NottiDeviceStore

  @Before
  fun setUp() {
    prefs = FakeSharedPreferences()
    store = NottiDeviceStore(prefs)
  }

  @Test
  fun `empty never-initialized state has no values`() {
    val state = store.getState()

    assertNull(state.deviceId)
    assertNull(state.lastToken)
    assertNull(state.externalUserId)
    assertFalse(state.subscribed)
    assertTrue(state.tags.isEmpty())
  }

  @Test
  fun `setTags persists and getTags returns the added tags`() {
    store.setTags(mapOf("plan" to "vip", "cohort" to "beta"))

    assertEquals(mapOf("plan" to "vip", "cohort" to "beta"), store.getTags())
  }

  @Test
  fun `setTags with a key removed from a prior call is no longer present`() {
    store.setTags(mapOf("plan" to "vip", "cohort" to "beta"))
    store.setTags(mapOf("cohort" to "beta"))

    assertEquals(mapOf("cohort" to "beta"), store.getTags())
  }

  @Test
  fun `mergeTags adds, removes, and last-operation-wins on overlapping add plus remove`() {
    val current = mapOf("plan" to "vip", "cohort" to "beta")

    val added = NottiDeviceStore.mergeTags(current, add = mapOf("region" to "br"))
    assertEquals(mapOf("plan" to "vip", "cohort" to "beta", "region" to "br"), added)

    val removed = NottiDeviceStore.mergeTags(current, remove = listOf("plan"))
    assertEquals(mapOf("cohort" to "beta"), removed)

    // Same key both added and removed in one call: add wins (documented rule).
    val overlap = NottiDeviceStore.mergeTags(
      current,
      add = mapOf("plan" to "enterprise"),
      remove = listOf("plan")
    )
    assertEquals(mapOf("plan" to "enterprise", "cohort" to "beta"), overlap)
  }

  @Test
  fun `deviceId and lastToken round-trip through SharedPreferences`() {
    store.setDeviceId("device-123")
    store.setLastToken("fcm-token-abc")

    assertEquals("device-123", store.getDeviceId())
    assertEquals("fcm-token-abc", store.getLastToken())
  }

  @Test
  fun `externalUserId and subscribed round-trip through SharedPreferences`() {
    store.setExternalUserId("user-42")
    store.setSubscribed(true)

    val state = store.getState()
    assertEquals("user-42", state.externalUserId)
    assertTrue(state.subscribed)
  }

  @Test
  fun `telemetry fields round-trip through SharedPreferences`() {
    store.setAppVersion("1.2.3")
    store.setFirstSessionAtMs(1_000L)
    store.setLastSessionAtMs(31_000L)
    store.setSessionCount(2)
    store.setSessionTimeMs(45_000L)
    store.setSessionStartedAtMs(90_000L)
    store.setLocationSharingEnabled(true)

    val state = store.getState()
    assertEquals("1.2.3", state.appVersion)
    assertEquals(1_000L, state.firstSessionAtMs)
    assertEquals(31_000L, state.lastSessionAtMs)
    assertEquals(2, state.sessionCount)
    assertEquals(45_000L, state.sessionTimeMs)
    assertEquals(90_000L, state.sessionStartedAtMs)
    assertTrue(state.locationSharingEnabled)
  }

  @Test
  fun `a fresh store over the same SharedPreferences sees persisted telemetry values`() {
    val prefs = FakeSharedPreferences()
    NottiDeviceStore(prefs).apply {
      setAppVersion("1.2.3")
      setFirstSessionAtMs(1_000L)
      setLastSessionAtMs(31_000L)
      setSessionCount(3)
      setSessionTimeMs(60_000L)
      setSessionStartedAtMs(90_000L)
      setLocationSharingEnabled(true)
    }

    // A second store over the same backing prefs proves real persistence,
    // not just in-memory round-tripping.
    val state = NottiDeviceStore(prefs).getState()
    assertEquals("1.2.3", state.appVersion)
    assertEquals(1_000L, state.firstSessionAtMs)
    assertEquals(31_000L, state.lastSessionAtMs)
    assertEquals(3, state.sessionCount)
    assertEquals(60_000L, state.sessionTimeMs)
    assertEquals(90_000L, state.sessionStartedAtMs)
    assertTrue(state.locationSharingEnabled)
  }

  @Test
  fun `telemetry fields default to null-zero-false when absent`() {
    val state = store.getState()

    assertNull(state.appVersion)
    assertNull(state.firstSessionAtMs)
    assertNull(state.lastSessionAtMs)
    assertEquals(0, state.sessionCount)
    assertEquals(0L, state.sessionTimeMs)
    assertNull(state.sessionStartedAtMs)
    assertFalse(state.locationSharingEnabled)
  }

  @Test
  fun `opt-out flags are written with a synchronous commit so they survive process death`() {
    val prefs = FakeSharedPreferences()
    val durable = NottiDeviceStore(prefs)

    durable.setLocationSharingEnabled(false)
    durable.setPendingCountryClear(true)

    assertTrue(prefs.committedKeys.contains("notti_location_sharing_enabled"))
    assertTrue(prefs.committedKeys.contains("notti_pending_country_clear"))
    assertTrue(durable.getPendingCountryClear())
  }

  // ---------------------------------------------------------------------
  // Device profile fields (device-profile-fields, T2)
  // ---------------------------------------------------------------------

  @Test
  fun `profile field ack migration clears the six last-synced values exactly once`() {
    // Simulates an install upgraded from SDK <= 0.5.0, which marked these as
    // synced on any 2xx (unacked).
    store.setAppVersion("1.2.3")
    store.setLastSyncedDeviceOs("15.0")
    store.setLastSyncedDeviceModel("Pixel 8")
    store.setLastSyncedSdkVersion("0.5.0")
    store.setLastSyncedTimezoneId("America/Sao_Paulo")
    store.setLastSyncedLanguage("pt")
    store.setLastSyncedPermissionStatus("granted")

    store.migrateProfileFieldAckIfNeeded()

    assertNull(store.getAppVersion())
    assertNull(store.getLastSyncedDeviceOs())
    assertNull(store.getLastSyncedDeviceModel())
    assertNull(store.getLastSyncedSdkVersion())
    assertNull(store.getLastSyncedTimezoneId())
    assertNull(store.getLastSyncedLanguage())
    // Not an echo-acked field - untouched.
    assertEquals("granted", store.getLastSyncedPermissionStatus())

    // Values acked after the migration survive every later call.
    store.setLastSyncedDeviceOs("16.0")
    store.migrateProfileFieldAckIfNeeded()
    NottiDeviceStore(prefs).migrateProfileFieldAckIfNeeded()
    assertEquals("16.0", store.getLastSyncedDeviceOs())
  }

  @Test
  fun `device profile fields round-trip through SharedPreferences`() {
    store.setLastSyncedDeviceOs("15.0")
    store.setLastSyncedDeviceModel("Pixel 8")
    store.setLastSyncedSdkVersion("0.5.0")
    store.setLastSyncedTimezoneId("America/Sao_Paulo")
    store.setLastSyncedLanguage("pt")
    store.setLastSyncedPermissionStatus("granted")
    store.setLastUnsubscribedAtMs(1_700_000_000_000L)
    store.setEmail("user@example.com")
    store.setPhone("+5511999999999")

    val state = store.getState()
    assertEquals("15.0", state.lastSyncedDeviceOs)
    assertEquals("Pixel 8", state.lastSyncedDeviceModel)
    assertEquals("0.5.0", state.lastSyncedSdkVersion)
    assertEquals("America/Sao_Paulo", state.lastSyncedTimezoneId)
    assertEquals("pt", state.lastSyncedLanguage)
    assertEquals("granted", state.lastSyncedPermissionStatus)
    assertEquals(1_700_000_000_000L, state.lastUnsubscribedAtMs)
    assertEquals("user@example.com", state.email)
    assertEquals("+5511999999999", state.phone)
  }

  @Test
  fun `a fresh store over the same SharedPreferences sees persisted device profile values`() {
    val prefs = FakeSharedPreferences()
    NottiDeviceStore(prefs).apply {
      setLastSyncedDeviceOs("14.0")
      setLastSyncedDeviceModel("Pixel 7")
      setLastSyncedSdkVersion("0.4.0")
      setLastSyncedTimezoneId("America/New_York")
      setLastSyncedLanguage("en")
      setLastSyncedPermissionStatus("denied")
      setLastUnsubscribedAtMs(1_700_000_000_001L)
      setEmail("a@b.com")
      setPhone("+10000000000")
    }

    val state = NottiDeviceStore(prefs).getState()
    assertEquals("14.0", state.lastSyncedDeviceOs)
    assertEquals("Pixel 7", state.lastSyncedDeviceModel)
    assertEquals("0.4.0", state.lastSyncedSdkVersion)
    assertEquals("America/New_York", state.lastSyncedTimezoneId)
    assertEquals("en", state.lastSyncedLanguage)
    assertEquals("denied", state.lastSyncedPermissionStatus)
    assertEquals(1_700_000_000_001L, state.lastUnsubscribedAtMs)
    assertEquals("a@b.com", state.email)
    assertEquals("+10000000000", state.phone)
  }

  @Test
  fun `device profile fields default to null when absent`() {
    val state = store.getState()

    assertNull(state.lastSyncedDeviceOs)
    assertNull(state.lastSyncedDeviceModel)
    assertNull(state.lastSyncedSdkVersion)
    assertNull(state.lastSyncedTimezoneId)
    assertNull(state.lastSyncedLanguage)
    assertNull(state.lastSyncedPermissionStatus)
    assertNull(state.lastUnsubscribedAtMs)
    assertNull(state.email)
    assertNull(state.phone)
  }

  @Test
  fun `lastUnsubscribedAtMs uses the -1L sentinel so an absent value reads as null`() {
    store.setLastUnsubscribedAtMs(5_000L)
    assertEquals(5_000L, store.getLastUnsubscribedAtMs())
    store.setLastUnsubscribedAtMs(null)
    assertNull(store.getLastUnsubscribedAtMs())
  }

  // ---------------------------------------------------------------------
  // Review fixes (device-profile-fields, PR #24)
  // ---------------------------------------------------------------------

  @Test
  fun `lastSynced email and phone round-trip and are written with a synchronous commit`() {
    val prefs = FakeSharedPreferences()
    val durable = NottiDeviceStore(prefs)

    durable.setEmail(null)
    durable.setPhone(null)
    durable.setLastSyncedEmail("a@b.com")
    durable.setLastSyncedPhone("+10000000000")

    val state = NottiDeviceStore(prefs).getState()
    assertEquals("a@b.com", state.lastSyncedEmail)
    assertEquals("+10000000000", state.lastSyncedPhone)
    // A clear (held = null) and its ack must survive process death (LGPD).
    assertTrue(prefs.committedKeys.containsAll(listOf(
      "notti_email", "notti_phone", "notti_last_synced_email", "notti_last_synced_phone"
    )))

    durable.setLastSyncedEmail(null)
    assertNull(durable.getLastSyncedEmail())
  }

  @Test
  fun `subscribed tri-state reads null until a value is persisted`() {
    assertNull(store.getSubscribedOrNull())
    // The legacy accessor keeps its false default for existing callers.
    assertFalse(store.getSubscribed())

    store.setSubscribed(false)
    assertEquals(false, store.getSubscribedOrNull())
    store.setSubscribed(true)
    assertEquals(true, store.getSubscribedOrNull())
  }

  @Test
  fun `permissionRequested defaults to false and round-trips`() {
    assertFalse(store.getState().permissionRequested)
    store.setPermissionRequested(true)
    assertTrue(store.getPermissionRequested())
    assertTrue(store.getState().permissionRequested)
  }

  @Test
  fun `pending unsubscribe timestamps default to null and round-trip`() {
    assertNull(store.getPendingUnsubscribeAtMs())
    assertNull(store.getPendingPermissionUnsubscribeAtMs())

    store.setPendingUnsubscribeAtMs(1_000L)
    store.setPendingPermissionUnsubscribeAtMs(2_000L)
    assertEquals(1_000L, store.getPendingUnsubscribeAtMs())
    assertEquals(2_000L, store.getPendingPermissionUnsubscribeAtMs())

    store.setPendingUnsubscribeAtMs(null)
    store.setPendingPermissionUnsubscribeAtMs(null)
    assertNull(store.getPendingUnsubscribeAtMs())
    assertNull(store.getPendingPermissionUnsubscribeAtMs())
  }
}
