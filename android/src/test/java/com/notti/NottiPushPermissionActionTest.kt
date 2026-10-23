package com.notti

import android.net.Uri
import android.provider.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

class NottiPushPermissionActionTest {

  private class Probe(
    sdkInt: Int,
    enabled: Boolean,
    asked: Boolean,
    activity: Boolean = true,
    stateThrows: Boolean = false
  ) {
    val effects = mutableListOf<String>()
    val logs = mutableListOf<String>()
    val action = NottiPushPermissionAction(
      sdkInt = sdkInt,
      notificationsEnabled = { if (stateThrows) throw IllegalStateException("boom") else enabled },
      promptAlreadyShown = { asked },
      hasActivity = { activity },
      showPrompt = { effects += "prompt" },
      openNotificationSettings = { effects += "settings" },
      logger = { logs += it }
    )
  }

  @Test
  fun `below 33 with notifications enabled does nothing`() {
    val p = Probe(sdkInt = 32, enabled = true, asked = false)
    p.action.run()
    assertEquals(emptyList<String>(), p.effects)
  }

  @Test
  fun `below 33 with notifications disabled opens settings and never prompts`() {
    val p = Probe(sdkInt = 32, enabled = false, asked = false)
    p.action.run()
    assertEquals(listOf("settings"), p.effects)
  }

  @Test
  fun `33 and above with notifications enabled does nothing`() {
    val p = Probe(sdkInt = 33, enabled = true, asked = false)
    p.action.run()
    assertEquals(emptyList<String>(), p.effects)
  }

  @Test
  fun `33 and above disabled and never asked shows the prompt`() {
    val p = Probe(sdkInt = 34, enabled = false, asked = false)
    p.action.run()
    assertEquals(listOf("prompt"), p.effects)
  }

  @Test
  fun `33 and above disabled and asked before opens settings`() {
    val p = Probe(sdkInt = 34, enabled = false, asked = true)
    p.action.run()
    assertEquals(listOf("settings"), p.effects)
  }

  @Test
  fun `no activity does nothing in every state`() {
    listOf(
      Probe(sdkInt = 32, enabled = false, asked = false, activity = false),
      Probe(sdkInt = 34, enabled = false, asked = false, activity = false),
      Probe(sdkInt = 34, enabled = false, asked = true, activity = false)
    ).forEach {
      it.action.run()
      assertEquals(emptyList<String>(), it.effects)
    }
  }

  @Test
  fun `an unreadable state does nothing and logs only the exception type`() {
    val p = Probe(sdkInt = 34, enabled = false, asked = false, stateThrows = true)
    p.action.run()
    assertEquals(emptyList<String>(), p.effects)
    assertEquals(1, p.logs.size)
    assertTrue(p.logs[0].contains("IllegalStateException"))
    assertTrue(!p.logs[0].contains("boom"))
  }
}

/**
 * minSdk is 24 but the notification settings action exists only from 26.
 * The API level is a parameter, so one Robolectric SDK covers both branches.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NottiAppNotificationSettingsIntentTest {

  @Test
  fun `API 26 and above opens the app notification settings`() {
    listOf(26, 34).forEach { sdk ->
      val intent = appNotificationSettingsIntent(sdk, "com.example.host")
      assertEquals(Settings.ACTION_APP_NOTIFICATION_SETTINGS, intent.action)
      assertEquals("com.example.host", intent.getStringExtra(Settings.EXTRA_APP_PACKAGE))
      assertNull(intent.data)
    }
  }

  @Test
  fun `below API 26 opens the app details settings for the package`() {
    listOf(24, 25).forEach { sdk ->
      val intent = appNotificationSettingsIntent(sdk, "com.example.host")
      assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, intent.action)
      assertEquals(Uri.parse("package:com.example.host"), intent.data)
      assertNull(intent.getStringExtra(Settings.EXTRA_APP_PACKAGE))
    }
  }
}
