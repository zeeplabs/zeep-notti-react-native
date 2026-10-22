package com.notti

import android.app.Activity
import android.app.Application
import android.content.res.Resources
import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.annotation.RequiresApi
import java.lang.ref.WeakReference

/** What the presenter reports about a display. The coordinator implements it; every call is made on main. */
interface InAppDisplayEvents {
  fun onDisplayAttached(displayId: String, attached: Boolean)
  fun onDisplayVisible(displayId: String)
  fun onDisplayClicked(displayId: String, buttonId: String, action: InAppAction?)
  fun onDisplayDismissed(displayId: String, reason: String)
  fun onDisplayFailed(displayId: String)
}

/**
 * Tracks the resumed Activity (weakly) and forwards resume/pause/destroy to
 * [listener]. Registered once per process, before the first Activity, so a
 * cold start already knows the resumed Activity.
 */
class NottiInAppActivityTracker : Application.ActivityLifecycleCallbacks {

  interface Listener {
    fun onActivityResumed(activity: Activity)
    fun onActivityGone(activity: Activity)
  }

  private var resumedRef: WeakReference<Activity>? = null

  var listener: Listener? = null

  val resumed: Activity? get() = resumedRef?.get()

  override fun onActivityResumed(activity: Activity) {
    resumedRef = WeakReference(activity)
    listener?.onActivityResumed(activity)
  }

  override fun onActivityPaused(activity: Activity) = gone(activity)

  override fun onActivityDestroyed(activity: Activity) = gone(activity)

  override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
  override fun onActivityStarted(activity: Activity) = Unit
  override fun onActivityStopped(activity: Activity) = Unit
  override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

  private fun gone(activity: Activity) {
    if (resumedRef?.get() === activity) resumedRef = null
    listener?.onActivityGone(activity)
  }
}

/**
 * Shows the current display over the resumed Activity's content view. The
 * views are disposable and rebuilt on every attach; the [InAppDisplay] is
 * not, so recreation or an Activity change never raises a second impression
 * (DD-6). Main thread only. Owns the Back handling of `center`/`full` (DD-10).
 */
class NottiInAppOverlayPresenter(
  private val tracker: NottiInAppActivityTracker,
  private val events: InAppDisplayEvents,
  private val images: InAppImageSource? = null
) : InAppPresenter, NottiInAppActivityTracker.Listener {

  companion object {
    /** Longest wait for the image before the message shows without it (A11). */
    const val IMAGE_WAIT_MS = 3_000L
  }

  private class Attachment(
    val activity: WeakReference<Activity>,
    val views: InAppMessageViews,
    val siblings: InAppSiblingRestore?,
    val releaseBack: (() -> Unit)?
  ) {
    var layoutListener: ViewTreeObserver.OnGlobalLayoutListener? = null
  }

  private var display: InAppDisplay? = null
  private var attachment: Attachment? = null
  private val main = Handler(Looper.getMainLooper())

  /** False while the image of [display] is awaited; the overlay is built only once it is true. */
  private var prepared = false
  /** Chosen once per display: every attach reuses it, a late image is never inserted. */
  private var image: Bitmap? = null
  private var imageWait: Runnable? = null

  /** Display id whose `onVisible` was already raised by this presenter. */
  private var visibleRaisedFor: String? = null

  init {
    tracker.listener = this
  }

  /** True while an overlay is in a view hierarchy. */
  val isAttached: Boolean get() = attachment != null

  override fun present(display: InAppDisplay) {
    val current = this.display
    if (current === display) return
    if (current != null) teardownSilently()
    this.display = display
    prepare(display)
  }

  /** Waits at most [IMAGE_WAIT_MS] for the image, then attaches with or without it (SDKIAM-20/57). */
  private fun prepare(target: InAppDisplay) {
    val url = target.message.imageUrl
    val source = images
    if (url == null || source == null) {
      ready(target, null)
      return
    }
    val wait = Runnable { ready(target, null) }
    imageWait = wait
    main.postDelayed(wait, IMAGE_WAIT_MS)
    val maxSide = Resources.getSystem().displayMetrics.let { maxOf(it.widthPixels, it.heightPixels) }
    try {
      source.load(url, maxSide) { bitmap -> main.post { ready(target, bitmap) } }
    } catch (e: Exception) {
      ready(target, null)
    }
  }

  /** First outcome wins: the image, its failure or the wait; anything later is ignored. */
  private fun ready(target: InAppDisplay, bitmap: Bitmap?) {
    if (display !== target || prepared) return
    cancelImageWait()
    prepared = true
    image = bitmap
    attachIfPossible()
  }

  private fun cancelImageWait() {
    imageWait?.let { main.removeCallbacks(it) }
    imageWait = null
  }

  private fun forget() {
    cancelImageWait()
    display = null
    prepared = false
    image = null
  }

  override fun close(displayId: String) {
    if (display?.displayId != displayId) return
    detach(report = false)
    forget()
  }

  override fun teardown(display: InAppDisplay) {
    if (this.display === display) teardownSilently()
  }

  /** Removes the overlay, stops reporting and restores the host; no event (SDKIAM-70). */
  fun teardownSilently() {
    detach(report = false)
    forget()
  }

  override fun onActivityResumed(activity: Activity) {
    val current = attachment
    if (current != null && current.activity.get() !== activity) detach(report = true)
    attachIfPossible()
  }

  override fun onActivityGone(activity: Activity) {
    if (attachment?.activity?.get() === activity) detach(report = true)
  }

  private fun attachIfPossible() {
    val target = display ?: return
    if (!prepared || attachment != null || target.state == InAppDisplayState.CLOSED) return
    // No resumed Activity: the display stays Preparing until one resumes.
    val activity = tracker.resumed ?: return
    if (activity.isFinishing) return
    val container = activity.findViewById<ViewGroup>(android.R.id.content) ?: return
    val displayId = target.displayId

    val views = try {
      NottiInAppViewFactory.build(activity, target.message, image).also {
        NottiInAppViewFactory.bind(it, target.message, viewListener(displayId))
      }
    } catch (e: Exception) {
      // A visible display keeps its slot and is retried on the next resume.
      if (target.state == InAppDisplayState.PREPARING) {
        forget()
        events.onDisplayFailed(displayId)
      }
      return
    }

    container.addView(views.root, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    val modal = target.message.format == InAppFormat.CENTER || target.message.format == InAppFormat.FULL
    val siblings = if (modal) NottiInAppAccessibility.hideSiblings(container, views.root) else null
    val releaseBack = if (modal) consumeBack(activity, views.root) else null
    val created = Attachment(WeakReference(activity), views, siblings, releaseBack)
    attachment = created
    events.onDisplayAttached(displayId, true)
    views.root.requestApplyInsets()

    val listener = object : ViewTreeObserver.OnGlobalLayoutListener {
      override fun onGlobalLayout() {
        views.root.viewTreeObserver.removeOnGlobalLayoutListener(this)
        created.layoutListener = null
        if (attachment !== created) return
        if (visibleRaisedFor != displayId) {
          visibleRaisedFor = displayId
          events.onDisplayVisible(displayId)
        }
        NottiInAppAccessibility.onShown(views, target.message.format)
      }
    }
    created.layoutListener = listener
    views.root.viewTreeObserver.addOnGlobalLayoutListener(listener)
  }

  private fun detach(report: Boolean) {
    val current = attachment ?: return
    attachment = null
    current.layoutListener?.let { current.views.root.viewTreeObserver.removeOnGlobalLayoutListener(it) }
    current.releaseBack?.invoke()
    current.siblings?.restore()
    (current.views.root.parent as? ViewGroup)?.removeView(current.views.root)
    val target = display
    if (report && target != null) events.onDisplayAttached(target.displayId, false)
  }

  private fun viewListener(displayId: String) = object : InAppViewListener {
    override fun onClose(reason: String) = events.onDisplayDismissed(displayId, reason)
    override fun onAction(buttonId: String, action: InAppAction?) =
      events.onDisplayClicked(displayId, buttonId, action)
  }

  /**
   * Back is consumed as a no-op while a `center`/`full` display is attached
   * (DD-10, A19): never a dismiss, never the host's navigation. Returns the
   * release of whatever was registered.
   */
  private fun consumeBack(activity: Activity, root: View): () -> Unit {
    if (activity is ComponentActivity) {
      // AndroidX forwards an enabled callback to OnBackInvokedDispatcher on API 33+.
      val callback = object : OnBackPressedCallback(true) {
        override fun handleOnBackPressed() = Unit
      }
      activity.onBackPressedDispatcher.addCallback(callback)
      return { callback.remove() }
    }
    // Not a ComponentActivity: the platform callback covers the opted-in
    // path on API 33+; without the opt-in Back still arrives as KEYCODE_BACK,
    // so the key listener is registered on every API level.
    val releaseInvoked = if (Build.VERSION.SDK_INT >= 33) consumeBackInvoked(activity) else null
    root.isFocusable = true
    root.isFocusableInTouchMode = true
    root.requestFocus()
    root.setOnKeyListener { _, keyCode, _ -> keyCode == KeyEvent.KEYCODE_BACK }
    return {
      releaseInvoked?.invoke()
      root.setOnKeyListener(null)
    }
  }

  @RequiresApi(33)
  private fun consumeBackInvoked(activity: Activity): () -> Unit {
    val callback = OnBackInvokedCallback { }
    val dispatcher = activity.onBackInvokedDispatcher
    dispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_OVERLAY, callback)
    return { dispatcher.unregisterOnBackInvokedCallback(callback) }
  }
}
