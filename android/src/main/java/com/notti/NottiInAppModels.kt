package com.notti

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Layout chosen by the server. An unknown value renders as [CENTER]. */
enum class InAppFormat { TOP, CENTER, BOTTOM, FULL }

enum class InAppTextAlign { LEFT, CENTER, RIGHT }

/**
 * A link the integrator handles (the SDK never opens it). [type] is `url` or
 * `deeplink`; [value] is exactly what the server sent, never rewritten.
 */
data class InAppAction(val type: String, val value: String)

/**
 * Look tokens of a message. Colors are opaque ARGB ints, `null` meaning "use
 * the SDK default" (an absent or unparseable token). `style: null` in the
 * payload yields the defaults of this class.
 */
data class InAppStyle(
  val backgroundColor: Int? = null,
  val textColor: Int? = null,
  val buttonColor: Int? = null,
  val buttonTextColor: Int? = null,
  val textAlign: InAppTextAlign = InAppTextAlign.LEFT,
  val margin: Boolean = true
)

sealed class InAppTrigger {
  object SessionStart : InAppTrigger()

  /** [name] is never empty and is matched byte for byte against `trackEvent`. */
  data class Event(val name: String) : InAppTrigger()

  /** Unknown trigger type, or an `event` trigger without a name. */
  object Unsupported : InAppTrigger()
}

/** [action] is `null` when the payload had an unknown or malformed action. */
data class InAppButton(val id: String, val label: String, val action: InAppAction?)

/**
 * A message from the `eligible` response. [renderable] is false when the SDK
 * must skip it (no impression, no event): empty id, no title and no body, or
 * an unsupported trigger.
 */
data class InAppMessage(
  val id: String,
  val format: InAppFormat,
  val title: String,
  val body: String,
  val imageUrl: String?,
  val imageAction: InAppAction?,
  val style: InAppStyle,
  val dismissAfterSeconds: Int?,
  val trigger: InAppTrigger,
  val buttons: List<InAppButton>,
  val renderable: Boolean
)

private const val MAX_BUTTONS = 2
private const val MIN_DISMISS_SECONDS = 1
private const val MAX_DISMISS_SECONDS = 300
private val HEX_COLOR = Regex("^#[0-9A-Fa-f]{6}$")

/**
 * Parses an `eligible` 200 body tolerantly. Returns `null` (a transient
 * failure for the caller) when the body is not a JSON object or has no
 * `messages` array. Otherwise returns the parsed messages in server order:
 * unknown fields are ignored, an entry that is not an object is skipped
 * without affecting the others, and an empty array is a valid result.
 * Never throws.
 */
fun parseEligibleResponse(body: String): List<InAppMessage>? {
  val root = try {
    JSONObject(body)
  } catch (e: JSONException) {
    return null
  }
  val entries = root.opt("messages") as? JSONArray ?: return null
  val messages = ArrayList<InAppMessage>(entries.length())
  for (i in 0 until entries.length()) {
    val entry = entries.opt(i) as? JSONObject ?: continue
    messages.add(parseMessage(entry))
  }
  return messages
}

/**
 * `#RRGGBB` (either case) to an opaque ARGB int; anything else (`#RGB`,
 * alpha form, no `#`, non-hex, blank, `null`) yields `null`. Never throws.
 */
fun parseHexColor(value: String?): Int? {
  if (value == null || !HEX_COLOR.matches(value)) return null
  return (0xFF shl 24) or value.substring(1).toInt(16)
}

private fun parseMessage(obj: JSONObject): InAppMessage {
  val id = obj.stringOrEmpty("id")
  val title = obj.stringOrEmpty("title")
  val body = obj.stringOrEmpty("body")
  val imageUrl = (obj.opt("image_url") as? String)?.takeIf(::isHttpsUrl)
  val trigger = parseTrigger(obj.opt("trigger") as? JSONObject)
  return InAppMessage(
    id = id,
    format = parseFormat(obj.opt("format") as? String),
    title = title,
    body = body,
    imageUrl = imageUrl,
    imageAction = if (imageUrl != null) parseAction(obj.opt("image_action")) else null,
    style = parseStyle(obj.opt("style") as? JSONObject),
    dismissAfterSeconds = parseDismissSeconds(obj.opt("dismiss_after_seconds")),
    trigger = trigger,
    buttons = parseButtons(obj.opt("buttons") as? JSONArray),
    renderable = id.isNotEmpty() &&
      (title.trim().isNotEmpty() || body.trim().isNotEmpty()) &&
      trigger !is InAppTrigger.Unsupported
  )
}

private fun JSONObject.stringOrEmpty(key: String): String = opt(key) as? String ?: ""

private fun isHttpsUrl(value: String): Boolean =
  value.length > "https://".length && value.startsWith("https://", ignoreCase = true)

private fun parseFormat(value: String?): InAppFormat = when (value) {
  "top" -> InAppFormat.TOP
  "bottom" -> InAppFormat.BOTTOM
  "full" -> InAppFormat.FULL
  else -> InAppFormat.CENTER
}

private fun parseTrigger(obj: JSONObject?): InAppTrigger {
  if (obj == null) return InAppTrigger.Unsupported
  return when (obj.opt("type") as? String) {
    "session_start" -> InAppTrigger.SessionStart
    "event" -> {
      val name = obj.stringOrEmpty("name")
      if (name.isEmpty()) InAppTrigger.Unsupported else InAppTrigger.Event(name)
    }
    else -> InAppTrigger.Unsupported
  }
}

private fun parseAction(raw: Any?): InAppAction? {
  val obj = raw as? JSONObject ?: return null
  val type = obj.opt("type") as? String
  if (type != "url" && type != "deeplink") return null
  val value = obj.stringOrEmpty("value")
  if (value.isEmpty()) return null
  return InAppAction(type, value)
}

private fun parseButtons(entries: JSONArray?): List<InAppButton> {
  if (entries == null) return emptyList()
  val buttons = ArrayList<InAppButton>(MAX_BUTTONS)
  for (i in 0 until entries.length()) {
    if (buttons.size == MAX_BUTTONS) break
    val obj = entries.opt(i) as? JSONObject ?: continue
    val id = obj.stringOrEmpty("id")
    val label = obj.stringOrEmpty("label")
    if (id.isEmpty() || label.isEmpty()) continue
    buttons.add(InAppButton(id, label, parseAction(obj.opt("action"))))
  }
  return buttons
}

private fun parseStyle(obj: JSONObject?): InAppStyle {
  if (obj == null) return InAppStyle()
  return InAppStyle(
    backgroundColor = parseHexColor(obj.opt("background_color") as? String),
    textColor = parseHexColor(obj.opt("text_color") as? String),
    buttonColor = parseHexColor(obj.opt("button_color") as? String),
    buttonTextColor = parseHexColor(obj.opt("button_text_color") as? String),
    textAlign = when (obj.opt("text_align") as? String) {
      "center" -> InAppTextAlign.CENTER
      "right" -> InAppTextAlign.RIGHT
      else -> InAppTextAlign.LEFT
    },
    margin = obj.opt("margin") as? Boolean ?: true
  )
}

private fun parseDismissSeconds(raw: Any?): Int? {
  val number = raw as? Number ?: return null
  val seconds = number.toDouble()
  if (seconds != Math.floor(seconds)) return null
  if (seconds < MIN_DISMISS_SECONDS || seconds > MAX_DISMISS_SECONDS) return null
  return seconds.toInt()
}
