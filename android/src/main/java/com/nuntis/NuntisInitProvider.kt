package com.nuntis

import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.util.Log

/**
 * Zero-integration-code process-start hook: a manifest-declared
 * [ContentProvider]'s `onCreate` runs before `Application.onCreate` finishes
 * and, crucially, before any Activity is created - which is what the
 * cold-start notification-click path (spec P3-AC7) needs, since
 * [NuntisModule] is a lazy TurboModule that does not exist yet when the
 * launching Activity reads its intent. Same mechanism `androidx.startup` and
 * `react-native-firebase` use.
 *
 * It only registers [NuntisActivityLifecycleListener]; no SDK work, no
 * network, nothing that could slow or break host app startup.
 */
class NuntisInitProvider : ContentProvider() {

  override fun onCreate(): Boolean {
    val application = context?.applicationContext as? Application
    if (application == null) {
      Log.e(NuntisModule.NAME, "Nuntis: no Application context at startup - notification clicks from a cold start will not be detected")
      return false
    }
    NuntisActivityLifecycleListener.registerOnce(application)
    return true
  }

  override fun query(
    uri: Uri,
    projection: Array<out String>?,
    selection: String?,
    selectionArgs: Array<out String>?,
    sortOrder: String?
  ): Cursor? = null

  override fun getType(uri: Uri): String? = null

  override fun insert(uri: Uri, values: ContentValues?): Uri? = null

  override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

  override fun update(
    uri: Uri,
    values: ContentValues?,
    selection: String?,
    selectionArgs: Array<out String>?
  ): Int = 0
}
