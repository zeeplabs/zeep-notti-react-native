package com.notti

import java.util.UUID

/**
 * The `initialize` parameters the In-App engine depends on. Kept in memory
 * only; [toString] never prints the client key.
 */
data class InAppConfig(val appId: String, val clientKey: String, val baseUrl: String) {
  override fun toString(): String = "InAppConfig(appId=<redacted>, clientKey=<redacted>, baseUrl=<redacted>)"
}

/** The routes that log the `403` inactive warning, once per session each. */
enum class InAppRoute { ELIGIBLE, EVENTS }

/** Fetch progress of the current session. At most one `Done` per session. */
sealed class InAppFetchState {
  object Idle : InAppFetchState()
  object InFlight : InAppFetchState()
  object Done : InAppFetchState()
  data class GaveUp(val transient: Boolean) : InAppFetchState()
}

enum class InAppDisplayState { PREPARING, VISIBLE, CLOSED }

/**
 * The one message that is pending or visible. [displayId] is local and
 * identifies the callbacks of this display; it survives a session end
 * (DD-8). [clock] is null when the message has no auto-dismiss.
 */
class InAppDisplay internal constructor(
  val displayId: String,
  val message: InAppMessage,
  val clock: NottiInAppDisplayClock?
) {
  var state: InAppDisplayState = InAppDisplayState.PREPARING
    internal set
  var impressionRecorded: Boolean = false
    internal set
}

/** What the coordinator must do after a state change. */
sealed class InAppDecision {
  object None : InAppDecision()

  /** Present [display]; it is already counted as shown for this session. */
  data class Show(val display: InAppDisplay) : InAppDecision()
}

/** Result of [NottiInAppSession.onInitialized]. */
sealed class InAppInitOutcome {
  /** Same config as before (RN reload): nothing changed. */
  object Unchanged : InAppInitOutcome()

  /** First config of the process. */
  object First : InAppInitOutcome()

  /**
   * The config changed and the state was reset. [teardown] is the display
   * to remove silently (no terminal outcome, no event); the coordinator
   * also purges other apps' queued events.
   */
  data class Changed(val teardown: InAppDisplay?) : InAppInitOutcome()
}

/**
 * Pure In-App selection state, owned by the process-wide coordinator and
 * mutated only on the main thread. It decides what to show; every side
 * effect (presenting, enqueuing events, scheduling) belongs to the caller.
 * Names passed to [trackEvent] are never logged or persisted.
 */
class NottiInAppSession(
  private val monotonicMs: () -> Long = { System.nanoTime() / 1_000_000 },
  private val uuid: () -> String = { UUID.randomUUID().toString() }
) {

  companion object {
    /** Distinct names remembered before the held messages are known. */
    const val MAX_PENDING_NAMES = 32
  }

  var sessionToken: Long = 0
    private set
  var fetchGeneration: Long = 0
    private set
  var isOpen: Boolean = false
    private set
  var awaitingFirstSession: Boolean = false
    private set
  var config: InAppConfig? = null
    private set
  var fetch: InAppFetchState = InAppFetchState.Idle
    private set
  var keyRejected: Boolean = false
    private set

  /**
   * The device registered in this process (A6): only then are `device_id`
   * and the token fresh enough for `eligible`. Survives session ends; reset
   * by a config change, whose new core registers again.
   */
  var registeredInProcess: Boolean = false
    private set
  var display: InAppDisplay? = null
    private set

  /** Deadlines (monotonic ms) of a `429` pause; reset only by a config change. */
  var eligiblePausedUntilMs: Long? = null
  var eventsPausedUntilMs: Long? = null

  private var hasOpenedSession = false
  private var appForeground = true
  private val inactiveWarned = HashSet<InAppRoute>()
  private val held = ArrayList<InAppMessage>()
  private val shownIds = HashSet<String>()
  private val pendingNames = LinkedHashSet<String>()

  internal val heldMessages: List<InAppMessage> get() = held.toList()
  internal val shown: Set<String> get() = shownIds.toSet()
  internal val pending: List<String> get() = pendingNames.toList()

  fun onInitialized(newConfig: InAppConfig): InAppInitOutcome {
    val previous = config
    if (previous == newConfig) return InAppInitOutcome.Unchanged
    config = newConfig
    awaitingFirstSession = !hasOpenedSession
    if (previous == null) return InAppInitOutcome.First

    fetchGeneration++
    held.clear()
    pendingNames.clear()
    shownIds.clear()
    fetch = InAppFetchState.Idle
    eligiblePausedUntilMs = null
    eventsPausedUntilMs = null
    keyRejected = false
    registeredInProcess = false
    inactiveWarned.clear()
    val teardown = display
    display = null
    teardown?.state = InAppDisplayState.CLOSED
    return InAppInitOutcome.Changed(teardown)
  }

  fun onSessionStarted() {
    sessionToken++
    fetchGeneration++
    isOpen = true
    hasOpenedSession = true
    awaitingFirstSession = false
    keyRejected = false
    inactiveWarned.clear()
    fetch = InAppFetchState.Idle
    held.clear()
    shownIds.clear()
    display?.let { shownIds.add(it.message.id) }
  }

  /**
   * Ends the session. A visible display is kept (DD-8); a display that never
   * became visible is dropped and returned so the caller removes it silently.
   */
  fun onSessionEnded(): InAppDisplay? {
    fetchGeneration++
    held.clear()
    if (isOpen) pendingNames.clear()
    isOpen = false
    fetch = InAppFetchState.Idle
    val current = display ?: return null
    if (current.state == InAppDisplayState.VISIBLE) return null
    display = null
    current.state = InAppDisplayState.CLOSED
    return current
  }

  fun isCurrentSession(token: Long): Boolean = isOpen && token == sessionToken

  /**
   * Starts the session fetch, returning the generation the request must
   * carry, or null when no fetch may start (no session, key rejected, already
   * in flight or done, or a non-transient give-up).
   */
  fun tryStartFetch(): Long? {
    if (!isOpen || keyRejected) return null
    val state = fetch
    val allowed = state == InAppFetchState.Idle ||
      (state is InAppFetchState.GaveUp && state.transient)
    if (!allowed) return null
    fetch = InAppFetchState.InFlight
    return fetchGeneration
  }

  fun onFetchGaveUp(generation: Long, transient: Boolean) {
    if (generation != fetchGeneration || !isOpen) return
    fetch = InAppFetchState.GaveUp(transient)
  }

  /**
   * Processes an `eligible` response. A stale [generation] (session ended,
   * new session, config change) is discarded: nothing shown, nothing held.
   */
  fun onFetched(generation: Long, messages: List<InAppMessage>): InAppDecision {
    if (generation != fetchGeneration || !isOpen) return InAppDecision.None
    fetch = InAppFetchState.Done
    var decision: InAppDecision = InAppDecision.None

    val renderable = messages.filter { it.renderable }
    held.clear()
    held.addAll(renderable.filter { it.trigger is InAppTrigger.Event })
    if (display == null) {
      val first = renderable.firstOrNull {
        it.trigger == InAppTrigger.SessionStart && it.id !in shownIds
      }
      if (first != null) decision = select(first)
    }

    val names = pendingNames.toList()
    pendingNames.clear()
    for (name in names) {
      val replayed = matchHeld(name)
      if (replayed is InAppDecision.Show) decision = replayed
    }
    return decision
  }

  fun trackEvent(name: String): InAppDecision {
    if (name.isBlank() || config == null) return InAppDecision.None
    if (!isOpen && !awaitingFirstSession) return InAppDecision.None
    if (awaitingFirstSession || fetch != InAppFetchState.Done) {
      if (pendingNames.size < MAX_PENDING_NAMES || name in pendingNames) pendingNames.add(name)
      return InAppDecision.None
    }
    return matchHeld(name)
  }

  /**
   * Marks the display visible. True exactly once per display: the caller
   * enqueues the impression only then. Starts the auto-dismiss clock.
   */
  fun markVisible(displayId: String): Boolean {
    val current = display ?: return false
    if (current.displayId != displayId || current.impressionRecorded) return false
    if (current.state != InAppDisplayState.PREPARING) return false
    current.state = InAppDisplayState.VISIBLE
    current.impressionRecorded = true
    current.clock?.start()
    return true
  }

  /**
   * Closes a visible display. True exactly once: the caller then enqueues
   * one terminal event (click or dismiss). False before visible or after
   * the display was already closed or replaced.
   */
  fun markClosed(displayId: String): Boolean {
    val current = display ?: return false
    if (current.displayId != displayId || current.state != InAppDisplayState.VISIBLE) return false
    current.state = InAppDisplayState.CLOSED
    display = null
    return true
  }

  /** Drops a display that never became visible (presentation failed). */
  fun dropPreparing(displayId: String): Boolean {
    val current = display ?: return false
    if (current.displayId != displayId || current.state != InAppDisplayState.PREPARING) return false
    current.state = InAppDisplayState.CLOSED
    display = null
    return true
  }

  fun setAppForeground(foreground: Boolean) {
    appForeground = foreground
    display?.clock?.setForeground(foreground)
  }

  fun markRegistered() {
    registeredInProcess = true
  }

  fun markKeyRejected() {
    keyRejected = true
  }

  /** True the first time per session for [route]: log the `403` warning then. */
  fun shouldWarnInactive(route: InAppRoute): Boolean = inactiveWarned.add(route)

  private fun matchHeld(name: String): InAppDecision {
    if (display != null) return InAppDecision.None
    val match = held.firstOrNull {
      val trigger = it.trigger
      trigger is InAppTrigger.Event && trigger.name == name && it.id !in shownIds
    } ?: return InAppDecision.None
    return select(match)
  }

  private fun select(message: InAppMessage): InAppDecision {
    val clock = NottiInAppDisplayClock.create(message.dismissAfterSeconds, monotonicMs)
    clock?.setForeground(appForeground)
    val created = InAppDisplay(uuid(), message, clock)
    display = created
    shownIds.add(message.id)
    return InAppDecision.Show(created)
  }
}

/**
 * Visible-time accounting for `dismiss_after_seconds`. Time runs only after
 * [start] and while the display is attached and the app is in the
 * foreground; pausing keeps the remaining time. The caller schedules a check
 * at [remainingMs] whenever [isRunning] and closes the display when
 * [isExpired].
 */
class NottiInAppDisplayClock private constructor(
  durationMs: Long,
  private val monotonicMs: () -> Long
) {

  companion object {
    private const val MIN_SECONDS = 1
    private const val MAX_SECONDS = 300

    /** Null when [seconds] is absent or outside 1..300 (no auto-dismiss). */
    fun create(seconds: Int?, monotonicMs: () -> Long): NottiInAppDisplayClock? {
      if (seconds == null || seconds < MIN_SECONDS || seconds > MAX_SECONDS) return null
      return NottiInAppDisplayClock(seconds * 1000L, monotonicMs)
    }
  }

  private var remainingAtPauseMs = durationMs
  private var runningSinceMs: Long? = null
  private var started = false
  private var attached = false
  private var foreground = true

  val isRunning: Boolean get() = runningSinceMs != null

  fun start() {
    started = true
    update()
  }

  fun setAttached(value: Boolean) {
    attached = value
    update()
  }

  fun setForeground(value: Boolean) {
    foreground = value
    update()
  }

  fun remainingMs(): Long {
    val since = runningSinceMs ?: return remainingAtPauseMs
    return (remainingAtPauseMs - (monotonicMs() - since)).coerceAtLeast(0)
  }

  fun isExpired(): Boolean = remainingMs() == 0L

  private fun update() {
    val shouldRun = started && attached && foreground
    val since = runningSinceMs
    if (shouldRun && since == null) {
      runningSinceMs = monotonicMs()
    } else if (!shouldRun && since != null) {
      remainingAtPauseMs = (remainingAtPauseMs - (monotonicMs() - since)).coerceAtLeast(0)
      runningSinceMs = null
    }
  }
}
