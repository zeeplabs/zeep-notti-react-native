package com.notti

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.util.TypedValue
import android.graphics.Rect
import android.os.Bundle
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Reads the default colors from the Activity theme; undefined attributes stay null (A13). */
fun readThemeColors(context: Context): InAppThemeColors {
  val night = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
    Configuration.UI_MODE_NIGHT_YES
  return InAppThemeColors(
    background = themeColor(context, android.R.attr.colorBackground),
    text = themeColor(context, android.R.attr.textColorPrimary),
    accent = themeColor(context, android.R.attr.colorAccent),
    night = night
  )
}

private fun themeColor(context: Context, attr: Int): Int? {
  val array = context.obtainStyledAttributes(intArrayOf(attr))
  return try {
    if (array.hasValue(0)) array.getColorStateList(0)?.defaultColor else null
  } catch (e: Exception) {
    null
  } finally {
    array.recycle()
  }
}

/** System bars + display cutout of [insets], in dp. */
@Suppress("DEPRECATION")
internal fun safeAreaOf(insets: WindowInsets, density: Float): InAppInsets {
  val left: Int
  val top: Int
  val right: Int
  val bottom: Int
  if (Build.VERSION.SDK_INT >= 30) {
    val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
    left = bars.left
    top = bars.top
    right = bars.right
    bottom = bars.bottom
  } else {
    val cutout = if (Build.VERSION.SDK_INT >= 28) insets.displayCutout else null
    left = max(insets.systemWindowInsetLeft, cutout?.safeInsetLeft ?: 0)
    top = max(insets.systemWindowInsetTop, cutout?.safeInsetTop ?: 0)
    right = max(insets.systemWindowInsetRight, cutout?.safeInsetRight ?: 0)
    bottom = max(insets.systemWindowInsetBottom, cutout?.safeInsetBottom ?: 0)
  }
  return InAppInsets(left / density, top / density, right / density, bottom / density)
}

/**
 * Full-size overlay added over the Activity content. Recomputes the message
 * frame on every measure (rotation, resize) from its own size and the last
 * safe area it received. Only `center`/`full` consume touches; for bars a
 * touch outside the card reaches the app (SDKIAM-17).
 */
class InAppOverlayLayout internal constructor(
  context: Context,
  private val format: InAppFormat,
  private val margin: Boolean
) : FrameLayout(context) {

  internal lateinit var card: InAppCardLayout
  internal lateinit var column: InAppColumnLayout

  var safeArea: InAppInsets = InAppInsets.ZERO
    set(value) {
      field = value
      requestLayout()
    }

  var frame: InAppFrame? = null
    private set

  override fun onApplyWindowInsets(insets: WindowInsets): WindowInsets {
    safeArea = safeAreaOf(insets, resources.displayMetrics.density)
    return insets
  }

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val density = resources.displayMetrics.density
    val width = MeasureSpec.getSize(widthMeasureSpec)
    val height = MeasureSpec.getSize(heightMeasureSpec)
    val computed = computeFrame(format, margin, width / density, height / density, safeArea)
    frame = computed
    val params = card.layoutParams as LayoutParams
    // Absolute LEFT placement: FrameLayout's CENTER_HORIZONTAL would shift the
    // card by the whole left/right margin difference on asymmetric insets.
    params.gravity = when (computed.gravity) {
      InAppGravity.TOP -> Gravity.TOP or Gravity.LEFT
      InAppGravity.BOTTOM -> Gravity.BOTTOM or Gravity.LEFT
      InAppGravity.CENTER -> Gravity.CENTER_VERTICAL or Gravity.LEFT
      InAppGravity.FILL -> Gravity.TOP or Gravity.LEFT
    }
    params.width = (computed.width * density).toInt()
    params.rightMargin = 0
    if (computed.gravity == InAppGravity.CENTER) {
      // Centered in the safe area: FrameLayout adds (top - bottom) margin to the
      // centered position, so half the inset difference goes on one side only.
      val safeWidthPx = width - ((computed.marginLeft + computed.marginRight) * density).toInt()
      params.leftMargin = (computed.marginLeft * density).toInt() + max(0, (safeWidthPx - params.width) / 2)
      val shift = ((computed.marginTop - computed.marginBottom) * density / 2).toInt()
      params.topMargin = max(0, shift)
      params.bottomMargin = max(0, -shift)
    } else {
      params.leftMargin = (computed.marginLeft * density).toInt()
      params.topMargin = (computed.marginTop * density).toInt()
      params.bottomMargin = (computed.marginBottom * density).toInt()
    }
    params.height = if (computed.gravity == InAppGravity.FILL) {
      (computed.maxHeight * density).toInt()
    } else {
      LayoutParams.WRAP_CONTENT
    }
    column.maxHeightPx = (computed.maxHeight * density).toInt()
    super.onMeasure(widthMeasureSpec, heightMeasureSpec)
  }
}

/**
 * Scrollable content first, fixed part (buttons) below it, never taller than
 * [maxHeightPx]: the buttons stay reachable and the text scrolls
 * (SDKIAM-24). With [fill] the content takes all the height, so the buttons
 * are pinned to the bottom (`full`).
 */
class InAppColumnLayout internal constructor(context: Context, private val fill: Boolean) : ViewGroup(context) {

  var maxHeightPx: Int = Int.MAX_VALUE

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val width = MeasureSpec.getSize(widthMeasureSpec)
    var limit = maxHeightPx
    if (MeasureSpec.getMode(heightMeasureSpec) != MeasureSpec.UNSPECIFIED) {
      limit = min(limit, MeasureSpec.getSize(heightMeasureSpec))
    }
    val innerWidth = max(0, width - paddingLeft - paddingRight)
    val exactWidth = MeasureSpec.makeMeasureSpec(innerWidth, MeasureSpec.EXACTLY)
    var fixedHeight = 0
    for (i in 1 until childCount) {
      val child = getChildAt(i)
      if (child.visibility == GONE) continue
      child.measure(exactWidth, MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
      fixedHeight += child.measuredHeight
    }
    val available = max(0, limit - paddingTop - paddingBottom - fixedHeight)
    val content = getChildAt(0)
    content.measure(
      exactWidth,
      MeasureSpec.makeMeasureSpec(available, if (fill) MeasureSpec.EXACTLY else MeasureSpec.AT_MOST)
    )
    val total = paddingTop + paddingBottom + content.measuredHeight + fixedHeight
    setMeasuredDimension(width, total)
  }

  override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
    var y = paddingTop
    for (i in 0 until childCount) {
      val child = getChildAt(i)
      if (child.visibility == GONE) continue
      child.layout(paddingLeft, y, paddingLeft + child.measuredWidth, y + child.measuredHeight)
      y += child.measuredHeight
    }
  }
}

/**
 * Buttons side by side when each fits half the width on one line, else one
 * per row (SDKIAM-23). Measured, never guessed.
 */
class InAppButtonRow internal constructor(context: Context, private val spacingPx: Int) : ViewGroup(context) {

  var stacked: Boolean = false
    private set

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val width = MeasureSpec.getSize(widthMeasureSpec)
    val unspecified = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
    val half = (width - spacingPx * (childCount - 1)) / max(1, childCount)
    stacked = childCount > 1 && (0 until childCount).any {
      val child = getChildAt(it)
      child.measure(unspecified, unspecified)
      child.measuredWidth > half
    }
    var height = 0
    if (stacked || childCount == 1) {
      for (i in 0 until childCount) {
        val child = getChildAt(i)
        child.measure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY), unspecified)
        height += child.measuredHeight + if (i > 0) spacingPx else 0
      }
    } else {
      for (i in 0 until childCount) {
        val child = getChildAt(i)
        child.measure(MeasureSpec.makeMeasureSpec(half, MeasureSpec.EXACTLY), unspecified)
        height = max(height, child.measuredHeight)
      }
      // Same height for both, so the row reads as one control group.
      for (i in 0 until childCount) {
        val child = getChildAt(i)
        child.measure(
          MeasureSpec.makeMeasureSpec(half, MeasureSpec.EXACTLY),
          MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY)
        )
      }
    }
    // The padding is part of the row (it is the gap above the buttons); without
    // it here, `clipToPadding` would crop that much off the top of every button.
    setMeasuredDimension(width, height + paddingTop + paddingBottom)
  }

  override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
    var x = 0
    var y = paddingTop
    for (i in 0 until childCount) {
      val child = getChildAt(i)
      child.layout(x, y, x + child.measuredWidth, y + child.measuredHeight)
      if (stacked || childCount == 1) y += child.measuredHeight + spacingPx else x += child.measuredWidth + spacingPx
    }
  }
}

/** Swipe distance that dismisses a bar: a third of its height, at most 48 dp (SDKIAM-22). */
internal fun swipeThresholdPx(barHeightPx: Int, density: Float): Float =
  min(barHeightPx / 3f, InAppMetrics.CLOSE_TARGET_DP * density)

/**
 * The message card. On a bar it owns the swipe and the body tap, observing the
 * touch stream before its children so the scroll container cannot swallow
 * them: a vertical drag in [dismissDirection] (-1 up, 1 down, 0 none) that the
 * content cannot scroll becomes a swipe, and a tap outside the [excluded]
 * controls is a body tap. Touches never leave the card's frame.
 */
class InAppCardLayout internal constructor(context: Context, private val dismissDirection: Int) : FrameLayout(context) {

  internal var onSwipe: (() -> Unit)? = null
  internal var onBodyTap: (() -> Unit)? = null
  internal var excluded: List<View> = emptyList()
  internal var scroll: View? = null

  private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
  private var downX = 0f
  private var downY = 0f
  private var dragging = false
  private var decided = false
  private var tapCandidate = false

  override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
    when (ev.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        // Raw coordinates: the card's own translation moves during a drag.
        downX = ev.rawX
        downY = ev.rawY
        dragging = false
        decided = false
        tapCandidate = onBodyTap != null && excluded.none { hits(it, ev) }
      }
      MotionEvent.ACTION_MOVE -> {
        val dx = ev.rawX - downX
        val dy = ev.rawY - downY
        if (dragging) {
          translationY = dragOffset(dy)
          return true
        }
        if (!decided && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
          // Decided once per gesture: a drag the text scroll took never turns
          // into a swipe halfway, when the scroll reaches its edge.
          decided = true
          tapCandidate = false
          if (startsSwipe(dx, dy)) {
            dragging = true
            cancelChildren(ev)
            translationY = dragOffset(dy)
            return true
          }
        }
      }
      MotionEvent.ACTION_UP -> {
        if (dragging) {
          dragging = false
          val distance = (ev.rawY - downY) * dismissDirection
          if (distance >= swipeThresholdPx(height, resources.displayMetrics.density)) {
            onSwipe?.invoke()
          } else {
            translationY = 0f
          }
          return true
        }
        if (tapCandidate) {
          tapCandidate = false
          super.dispatchTouchEvent(ev)
          onBodyTap?.invoke()
          return true
        }
      }
      MotionEvent.ACTION_CANCEL -> {
        if (dragging) translationY = 0f
        dragging = false
        decided = false
        tapCandidate = false
      }
    }
    return super.dispatchTouchEvent(ev)
  }

  // The card consumes touches so they never reach the backdrop, but it is only
  // an accessibility action when the body tap exists (bars with a button).
  override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
    super.onInitializeAccessibilityNodeInfo(info)
    if (onBodyTap == null) {
      info.isClickable = false
      info.removeAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_CLICK)
    }
  }

  override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
    if (action == AccessibilityNodeInfo.ACTION_CLICK) {
      val tap = onBodyTap ?: return false
      tap()
      return true
    }
    return super.performAccessibilityAction(action, arguments)
  }

  private fun startsSwipe(dx: Float, dy: Float): Boolean {
    if (dismissDirection == 0 || onSwipe == null) return false
    if (abs(dy) <= abs(dx) || dy * dismissDirection <= 0) return false
    // Let the text scroll first: a finger moving up scrolls the content down.
    return scroll?.canScrollVertically(-dismissDirection) != true
  }

  private fun dragOffset(dy: Float): Float = if (dismissDirection < 0) min(0f, dy) else max(0f, dy)

  private fun cancelChildren(ev: MotionEvent) {
    val cancel = MotionEvent.obtain(ev)
    cancel.action = MotionEvent.ACTION_CANCEL
    super.dispatchTouchEvent(cancel)
    cancel.recycle()
  }

  private fun hits(view: View, ev: MotionEvent): Boolean {
    if (view.visibility != VISIBLE || view.parent == null) return false
    val rect = Rect()
    view.getDrawingRect(rect)
    offsetDescendantRectToMyCoords(view, rect)
    return rect.contains(ev.x.toInt(), ev.y.toInt())
  }
}

/** Display outcomes reported by the views; the presenter forwards them to the coordinator. */
interface InAppViewListener {
  fun onClose(reason: String)
  /** [buttonId] is a button id or `image`; [action] is passed untouched. */
  fun onAction(buttonId: String, action: InAppAction?)
}

/** The built tree of one display. Rebuilt on every attach; holds no state. */
class InAppMessageViews internal constructor(
  val root: InAppOverlayLayout,
  val card: InAppCardLayout,
  val title: TextView,
  val body: TextView,
  val image: ImageView?,
  val buttons: List<TextView>,
  val buttonRow: InAppButtonRow?,
  val close: TextView,
  val style: InAppResolvedStyle
)

/**
 * Builds the native views of a message and, with [NottiInAppViewFactory.bind],
 * its gestures and taps. Text is always plain: the raw string goes to
 * `setText`, no HTML, no links, no spans (SDKIAM-31).
 */
object NottiInAppViewFactory {

  private const val TITLE_SP = 17f
  private const val BODY_SP = 15f
  private const val BUTTON_SP = 15f
  private const val CORNER_DP = 12f
  private const val BUTTON_CORNER_DP = 8f
  private const val PADDING_DP = 16f
  private const val SPACING_DP = 8f
  private const val ELEVATION_DP = 6f
  private const val IMAGE_MAX_HEIGHT_DP = 180f
  // Keeps the 48 dp close target (and its scrim chip) fully inside the rounded card corner.
  private const val CLOSE_INSET_DP = 8f
  private const val CLOSE_GLYPH = "✕"
  private const val SCRIM = 0x66000000

  fun build(context: Context, message: InAppMessage, image: Bitmap? = null): InAppMessageViews {
    val style = resolveStyle(message.style, resolvePalette(readThemeColors(context)), message.buttons.size)
    val density = context.resources.displayMetrics.density
    fun px(dp: Float) = (dp * density + 0.5f).toInt()
    val bar = message.format == InAppFormat.TOP || message.format == InAppFormat.BOTTOM
    val full = message.format == InAppFormat.FULL

    val root = InAppOverlayLayout(context, message.format, style.margin)
    root.layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    when (message.format) {
      InAppFormat.CENTER -> root.setBackgroundColor(InAppColors.BACKDROP)
      else -> Unit
    }
    if (!bar) {
      root.isClickable = true
      // The backdrop is not an accessibility element; the close control is the way out.
      root.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    val dismissDirection = when (message.format) {
      InAppFormat.TOP -> -1
      InAppFormat.BOTTOM -> 1
      else -> 0
    }
    val card = InAppCardLayout(context, dismissDirection).apply {
      background = GradientDrawable().apply {
        setColor(style.background)
        cornerRadius = if (full && !style.margin) 0f else CORNER_DP * density
      }
      elevation = ELEVATION_DP * density
      clipToOutline = true
      isClickable = true
    }
    root.addView(card, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT))
    root.card = card

    val column = InAppColumnLayout(context, fill = full).apply {
      val p = px(PADDING_DP)
      setPadding(p, p, p, p)
    }
    root.column = column
    card.addView(column, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))

    val title = plainText(context, message.title, TITLE_SP, style).apply {
      setTypeface(typeface, Typeface.BOLD)
      visibility = if (message.title.isBlank()) View.GONE else View.VISIBLE
    }
    val body = plainText(context, message.body, BODY_SP, style).apply {
      visibility = if (message.body.isBlank()) View.GONE else View.VISIBLE
    }
    val textBlock = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      addView(title)
      addView(body)
    }

    val imageHeightCap = px(IMAGE_MAX_HEIGHT_DP)
    val imageView = image?.let { bitmap ->
      // Full width; height follows the aspect ratio up to the cap, and a taller
      // image is center-cropped to it (same rule as iOS and the bar thumbnail).
      // In `full` the image also takes the room the text leaves free (contained,
      // never cropped): an exact height handed down by the layout wins over the cap.
      object : ImageView(context) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
          val width = MeasureSpec.getSize(widthMeasureSpec)
          if (MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.EXACTLY) {
            setMeasuredDimension(width, MeasureSpec.getSize(heightMeasureSpec))
            return
          }
          val ratioHeight = if (bitmap.width > 0) (width.toLong() * bitmap.height / bitmap.width).toInt() else 0
          setMeasuredDimension(width, minOf(imageHeightCap, ratioHeight))
        }
      }.apply {
        setImageBitmap(bitmap)
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
      }
    }

    val scrollContent = LinearLayout(context).apply { orientation = if (bar) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL }
    val closeReserve = px(InAppMetrics.CLOSE_TARGET_DP - PADDING_DP + CLOSE_INSET_DP)
    if (bar) {
      imageView?.let {
        it.scaleType = ImageView.ScaleType.CENTER_CROP
        scrollContent.addView(
          it,
          LinearLayout.LayoutParams(px(InAppMetrics.THUMBNAIL_DP), px(InAppMetrics.THUMBNAIL_DP)).apply { marginEnd = px(12f) }
        )
      }
      textBlock.setPaddingRelative(0, 0, closeReserve, 0)
      scrollContent.addView(textBlock, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    } else {
      imageView?.let {
        // `full` shows the whole picture inside the free area (no crop); the card crops to its 180 dp cap.
        it.scaleType = if (full) ImageView.ScaleType.FIT_CENTER else ImageView.ScaleType.CENTER_CROP
        scrollContent.addView(
          it,
          if (full) {
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f).apply { bottomMargin = px(12f) }
          } else {
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
              bottomMargin = px(12f)
            }
          }
        )
      }
      // Without an image the title sits next to the close control: keep it clear.
      if (imageView == null) textBlock.setPaddingRelative(0, 0, closeReserve, 0)
      scrollContent.addView(textBlock, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    }
    val scroll = ScrollView(context).apply {
      isFillViewport = full
      addView(scrollContent)
    }
    column.addView(scroll)
    card.scroll = scroll

    val buttonViews = message.buttons.mapIndexed { index, button ->
      val look = style.buttons[index]
      TextView(context).apply {
        text = button.label
        setTextSize(TypedValue.COMPLEX_UNIT_SP, BUTTON_SP)
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(look.text)
        gravity = Gravity.CENTER
        isAllCaps = false
        autoLinkMask = 0
        minHeight = px(InAppMetrics.CLOSE_TARGET_DP)
        setPadding(px(PADDING_DP), px(SPACING_DP), px(PADDING_DP), px(SPACING_DP))
        background = GradientDrawable().apply {
          setColor(look.background)
          cornerRadius = BUTTON_CORNER_DP * density
        }
        isClickable = true
        isFocusable = true
      }
    }
    val buttonRow = if (buttonViews.isEmpty()) null else InAppButtonRow(context, px(SPACING_DP)).apply {
      setPadding(0, px(12f), 0, 0)
      buttonViews.forEach { addView(it) }
    }
    buttonRow?.let { column.addView(it) }

    val overImage = imageView != null && !bar
    val close = TextView(context).apply {
      text = CLOSE_GLYPH
      gravity = Gravity.CENTER
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
      setTextColor(if (overImage) InAppColors.WHITE else style.text)
      minWidth = px(InAppMetrics.CLOSE_TARGET_DP)
      minHeight = px(InAppMetrics.CLOSE_TARGET_DP)
      if (overImage) {
        // Scrim chip: the glyph stays legible over any image (SDKIAM-21).
        background = GradientDrawable().apply {
          shape = GradientDrawable.OVAL
          setColor(SCRIM)
        }
      }
      isClickable = true
      isFocusable = true
    }
    val closeSize = px(InAppMetrics.CLOSE_TARGET_DP)
    card.addView(
      close,
      FrameLayout.LayoutParams(closeSize, closeSize, Gravity.TOP or Gravity.END).apply {
        topMargin = px(CLOSE_INSET_DP)
        marginEnd = px(CLOSE_INSET_DP)
      }
    )

    return InAppMessageViews(root, card, title, body, imageView, buttonViews, buttonRow, close, style)
  }

  /**
   * Wires the dismiss gestures and the taps of [views] to [listener] and sets
   * the accessibility semantics (SDKIAM-22, 33-35, 63). Only the first outcome
   * is delivered: a second tap or a swipe on a closing display is ignored.
   * Back is not handled here: the presenter owns it (DD-10).
   */
  fun bind(views: InAppMessageViews, message: InAppMessage, listener: InAppViewListener) {
    var done = false
    fun close(reason: String) {
      if (done) return
      done = true
      listener.onClose(reason)
    }
    fun action(buttonId: String, action: InAppAction?) {
      if (done) return
      done = true
      listener.onAction(buttonId, action)
    }

    views.close.setOnClickListener { close(InAppDismissReason.CLOSE_BUTTON) }
    views.buttons.forEachIndexed { index, view ->
      val button = message.buttons[index]
      view.setOnClickListener { action(button.id, button.action) }
    }
    // A failed image is never built, so a tappable image is always a loaded one.
    val imageTappable = views.image != null && message.imageAction != null
    if (imageTappable) {
      views.image?.isClickable = true
      views.image?.setOnClickListener { action(IMAGE_BUTTON_ID, message.imageAction) }
    }

    when (message.format) {
      InAppFormat.TOP, InAppFormat.BOTTOM -> {
        views.card.onSwipe = { close(InAppDismissReason.SWIPE) }
        message.buttons.firstOrNull()?.let { first ->
          views.card.onBodyTap = { action(first.id, first.action) }
        }
        views.card.excluded = listOfNotNull(views.close, views.image?.takeIf { imageTappable }) + views.buttons
      }
      InAppFormat.CENTER -> views.root.setOnClickListener { close(InAppDismissReason.OUTSIDE_TAP) }
      // The close control is the only way out of `full` (A19).
      InAppFormat.FULL -> Unit
    }

    NottiInAppAccessibility.apply(views, imageTappable)
  }

  /** `button_id` of an image click (SDKIAM-35). */
  const val IMAGE_BUTTON_ID = "image"

  private fun plainText(context: Context, value: String, sizeSp: Float, style: InAppResolvedStyle): TextView =
    TextView(context).apply {
      autoLinkMask = 0
      linksClickable = false
      movementMethod = null
      setTextIsSelectable(false)
      // A String, never a Spanned: rendered verbatim, newlines kept.
      text = value
      setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
      setTextColor(style.text)
      gravity = when (style.textAlign) {
        // Absolute sides: the author picked left or right, not start or end.
        InAppTextAlign.LEFT -> Gravity.LEFT
        InAppTextAlign.CENTER -> Gravity.CENTER_HORIZONTAL
        InAppTextAlign.RIGHT -> Gravity.RIGHT
      }
      textAlignment = View.TEXT_ALIGNMENT_GRAVITY
    }
}
