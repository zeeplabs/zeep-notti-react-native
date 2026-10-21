package com.notti

import android.os.Build

/**
 * Android side of the `push_permission` in-app button (IABA-06..08).
 *
 * The OS cannot tell "never asked" from "asked and permanently denied", so the
 * SDK's own `permissionRequested` flag stands in for it: set when the prompt is
 * actually shown, never otherwise. Every platform effect is injected, so each
 * row of the design table is a plain JVM test.
 *
 * | API | state | effect |
 * | --- | --- | --- |
 * | any | notifications enabled | nothing |
 * | below 33 | disabled | open the app's notification settings |
 * | 33+ | disabled, never asked | show the prompt |
 * | 33+ | disabled, asked before | open the app's notification settings |
 *
 * With no live `Activity` nothing runs. Any failure reading the state does
 * nothing and logs a generic line only.
 */
internal class NottiPushPermissionAction(
  private val sdkInt: Int,
  private val notificationsEnabled: () -> Boolean,
  private val promptAlreadyShown: () -> Boolean,
  private val hasActivity: () -> Boolean,
  private val showPrompt: () -> Unit,
  private val openNotificationSettings: () -> Unit,
  private val logger: (String) -> Unit
) : InAppPushPermissionPort {

  override fun run() {
    try {
      if (!hasActivity()) return
      if (notificationsEnabled()) return
      if (sdkInt < Build.VERSION_CODES.TIRAMISU || promptAlreadyShown()) {
        openNotificationSettings()
      } else {
        showPrompt()
      }
    } catch (e: Exception) {
      logger("Notti.inapp: push permission state unavailable (${e.javaClass.simpleName})")
    }
  }
}
