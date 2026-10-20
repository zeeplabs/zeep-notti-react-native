package com.notti

import android.content.Context
import android.os.Build
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import java.util.Locale

/**
 * Accessibility of an in-app display (SDKIAM-63). The close label is the only
 * text the SDK owns: an in-code table, no `res/` strings (A18).
 */
object NottiInAppAccessibility {

  private const val CLOSE_EN = "Close"
  private val CLOSE_LABELS = mapOf("pt" to "Fechar")

  /** Close label for [locale]: Portuguese or English, any other language falls back to English (A18). */
  fun closeLabel(locale: Locale): String = CLOSE_LABELS[locale.language.lowercase(Locale.ROOT)] ?: CLOSE_EN

  fun closeLabel(context: Context): String {
    val locales = context.resources.configuration.locales
    return closeLabel(if (locales.isEmpty) Locale.getDefault() else locales[0])
  }

  /** Static semantics of a built display: labels, roles and the heading. */
  internal fun apply(views: InAppMessageViews, imageTappable: Boolean) {
    views.close.contentDescription = closeLabel(views.close.context)
    asButton(views.close)
    views.buttons.forEach {
      it.contentDescription = it.text
      asButton(it)
    }
    if (Build.VERSION.SDK_INT >= 28) views.title.isAccessibilityHeading = true
    views.image?.let { image ->
      if (imageTappable) {
        // Author text only: the SDK has no string of its own for the image.
        image.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        image.contentDescription = views.title.text.takeIf { it.isNotBlank() }
        asButton(image)
      }
    }
  }

  /** Text announced for a bar, which never takes focus away from the app. */
  fun announcement(views: InAppMessageViews): String =
    listOf(views.title.text, views.body.text).filter { it.isNotBlank() }.joinToString(". ")

  /**
   * Called by the presenter once the display is attached: a bar is announced,
   * a `center`/`full` message gets the accessibility focus on its title.
   */
  @Suppress("DEPRECATION")
  fun onShown(views: InAppMessageViews, format: InAppFormat) {
    when (format) {
      InAppFormat.TOP, InAppFormat.BOTTOM -> views.root.announceForAccessibility(announcement(views))
      InAppFormat.CENTER, InAppFormat.FULL -> {
        val target = if (views.title.visibility == View.VISIBLE) views.title else views.card
        target.sendAccessibilityEvent(AccessibilityEvent.TYPE_VIEW_FOCUSED)
      }
    }
  }

  /**
   * Hides every other child of [container] from accessibility while [overlay]
   * is shown (`center`/`full` modality). [InAppSiblingRestore.restore] puts the
   * previous values back exactly; it is idempotent. Risk R3: these are host
   * views, so nothing else about them is touched.
   */
  fun hideSiblings(container: ViewGroup, overlay: View): InAppSiblingRestore {
    val saved = ArrayList<Pair<View, Int>>(container.childCount)
    for (i in 0 until container.childCount) {
      val child = container.getChildAt(i)
      if (child === overlay) continue
      saved.add(child to child.importantForAccessibility)
      child.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }
    return InAppSiblingRestore(saved)
  }

  private fun asButton(view: View) {
    view.accessibilityDelegate = object : View.AccessibilityDelegate() {
      override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(host, info)
        info.className = Button::class.java.name
      }
    }
  }
}

/** Previous accessibility values of the host views hidden by a modal display. */
class InAppSiblingRestore internal constructor(private var saved: List<Pair<View, Int>>) {
  fun restore() {
    saved.forEach { (view, value) -> view.importantForAccessibility = value }
    saved = emptyList()
  }
}
