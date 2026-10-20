package com.notti

import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/** Device identity read at call time. [toString] never prints either value. */
data class InAppIdentity(val deviceId: String, val token: String) {
  override fun toString(): String = "InAppIdentity(<redacted>)"
}

/** A click delivered to the host listener, action untouched (SDKIAM-67). */
data class InAppClick(val messageId: String, val buttonId: String, val action: InAppAction?)

/** `reason` values of a `dismiss` event (SDKIAM-43). */
object InAppDismissReason {
  const val CLOSE_BUTTON = "close_button"
  const val SWIPE = "swipe"
  const val OUTSIDE_TAP = "outside_tap"
  const val AUTO = "auto"
}

/** Background work port: the in-app executor in production, a fake in tests. */
interface InAppExecutor {
  fun execute(task: () -> Unit)
  fun schedule(delayMs: Long, task: () -> Unit)
}

/**
 * Shows and removes the overlay. Every call comes from the main thread.
 * [close] removes a display after its terminal outcome was reported;
 * [teardown] removes one silently (config change, session ended before it
 * became visible). Both must be idempotent.
 */
interface InAppPresenter {
  fun present(display: InAppDisplay)
  fun close(displayId: String)
  fun teardown(display: InAppDisplay)
}

/** Delivers a click to JS. False when no listener can receive it (SDKIAM-68). */
fun interface InAppClickSink {
  fun deliver(click: InAppClick): Boolean
}

/** Retry and pause constants of both routes, adjustable in one place. */
object InAppTiming {
  /** Requests per transient failure streak (2/4/8/16 s between them). */
  const val MAX_ATTEMPTS = 5
  const val BASE_BACKOFF_MS = 2000L

  /** `Retry-After` used when it is absent or not an integer of seconds. */
  const val DEFAULT_RETRY_AFTER_SECONDS = 60

  /** `eligible` 429: a `Retry-After` above this gives up for the session. */
  const val ELIGIBLE_GIVE_UP_RETRY_AFTER_SECONDS = 60
  const val ELIGIBLE_MAX_RATE_LIMIT_WAITS = 3

  /** Events 429: clamp of the stored pause. */
  const val EVENTS_MIN_RETRY_AFTER_SECONDS = 1
  const val EVENTS_MAX_RETRY_AFTER_SECONDS = 300

  fun backoffMs(failures: Int): Long = BASE_BACKOFF_MS shl (failures - 1).coerceIn(0, 30)
}

/** Production [InAppExecutor]: one daemon thread, so pending waits never keep the process alive. */
class NottiInAppScheduler : InAppExecutor {
  private val service: ScheduledExecutorService =
    Executors.newSingleThreadScheduledExecutor { runnable ->
      Thread(runnable, "notti-inapp").apply { isDaemon = true }
    }

  override fun execute(task: () -> Unit) {
    service.execute(task)
  }

  override fun schedule(delayMs: Long, task: () -> Unit) {
    service.schedule(task, delayMs, TimeUnit.MILLISECONDS)
  }
}

/** Outcome of one flush pass, computed on the executor. */
internal sealed class InAppFlushOutcome {
  object Done : InAppFlushOutcome()
  data class Paused(val retryAfterSeconds: Int?) : InAppFlushOutcome()
  object Unauthorized : InAppFlushOutcome()
  object Forbidden : InAppFlushOutcome()
  object Failed : InAppFlushOutcome()

  /** `full` mode: the head failed [failures] times in a row; retry it after a backoff. */
  data class Backoff(val failures: Int) : InAppFlushOutcome()
}

/**
 * Process-wide In-App orchestrator. Public entry points may be called from
 * any thread: they hop to main through [postToMain], where every state
 * change happens (DD-4). Network work runs on [executor]. It never opens a
 * URL and never logs ids, names, URLs, tokens or bodies (SDKIAM-32/54).
 */
class NottiInAppCoordinator(
  private val store: NottiInAppEventStore,
  private val clientFactory: (InAppConfig) -> NottiApiClient,
  private val identity: () -> InAppIdentity?,
  private val executor: InAppExecutor,
  private val postToMain: (() -> Unit) -> Unit,
  private val monotonicMs: () -> Long = { System.nanoTime() / 1_000_000 },
  private val logger: (String) -> Unit = {},
  val session: NottiInAppSession = NottiInAppSession(monotonicMs)
) : InAppDisplayEvents {

  companion object {
    const val INACTIVE_WARNING = "Notti.inapp: In-App is inactive on this device until the next registration"
    const val NO_LISTENER_WARNING = "Notti.inapp: click reported but no click listener is registered"
  }

  /** Set by the module/presentation layer; read on main only. */
  var presenter: InAppPresenter? = null
  /** Defaults to the live module's emitter; the SDK itself never opens a link (A9). */
  var clickSink: InAppClickSink? = InAppClickSink { NottiModule.emitInAppClick(it) }

  private var client: NottiApiClient? = null

  /** Incremented on a config change: results of older work only release their flags. */
  private var configEpoch = 0L
  private var flushRunning = false
  private var flushAgain = false

  // Entry points (any thread)

  fun onInitialized(appId: String, clientKey: String, baseUrl: String) =
    onMain { handleInitialized(InAppConfig(appId, clientKey, baseUrl)) }

  fun onSessionStarted() = onMain {
    session.onSessionStarted()
    maybeFetch(allowTransientRetry = false)
  }

  fun onSessionEnded() = onMain {
    session.onSessionEnded()?.let { presenter?.teardown(it) }
  }

  fun onRegistered() = onMain {
    requestFlush()
    maybeFetch(allowTransientRetry = false)
  }

  fun onNetworkAvailable() = onMain {
    requestFlush()
    maybeFetch(allowTransientRetry = true)
  }

  fun onAppForegrounded() = onMain {
    session.setAppForeground(true)
    scheduleClockCheck()
    requestFlush()
  }

  fun onAppBackgrounded() = onMain { session.setAppForeground(false) }

  /** Never throws, never sends or logs [name] (SDKIAM-10, SDKIAM-59). */
  fun trackEvent(name: String) = onMain { present(session.trackEvent(name)) }

  // Presenter callbacks (any thread)

  override fun onDisplayAttached(displayId: String, attached: Boolean) = onMain {
    val display = session.display?.takeIf { it.displayId == displayId } ?: return@onMain
    display.clock?.setAttached(attached)
    scheduleClockCheck()
  }

  /** First layout while attached and in the foreground: one impression per display (SDKIAM-40). */
  override fun onDisplayVisible(displayId: String) = onMain {
    val display = session.display ?: return@onMain
    if (!session.markVisible(displayId)) return@onMain
    enqueue(display.message.id, InAppEventType.IMPRESSION)
    scheduleClockCheck()
    requestFlush()
  }

  /**
   * A button, the image or a bar body was tapped (SDKIAM-33/42): `click`
   * enqueued, then delivered, then the display closed with no `dismiss`.
   */
  override fun onDisplayClicked(displayId: String, buttonId: String, action: InAppAction?) = onMain {
    val display = session.display ?: return@onMain
    if (!session.markClosed(displayId)) return@onMain
    val messageId = display.message.id
    enqueue(messageId, InAppEventType.CLICK, buttonId = buttonId)
    val delivered = try {
      clickSink?.deliver(InAppClick(messageId, buttonId, action)) ?: false
    } catch (e: Exception) {
      false
    }
    if (!delivered) logger(NO_LISTENER_WARNING)
    presenter?.close(displayId)
    requestFlush()
  }

  override fun onDisplayDismissed(displayId: String, reason: String) = onMain { dismiss(displayId, reason) }

  /** The display could not be presented; it is dropped with no event. */
  override fun onDisplayFailed(displayId: String) = onMain { session.dropPreparing(displayId) }

  // Main-thread handlers

  private fun onMain(block: () -> Unit) {
    postToMain {
      try {
        block()
      } catch (e: Exception) {
        logger("Notti.inapp: internal error (${e.javaClass.simpleName})")
      }
    }
  }

  private fun handleInitialized(config: InAppConfig) {
    when (val outcome = session.onInitialized(config)) {
      InAppInitOutcome.Unchanged -> Unit
      InAppInitOutcome.First -> client = clientFactory(config)
      is InAppInitOutcome.Changed -> {
        configEpoch++
        client = clientFactory(config)
        outcome.teardown?.let { presenter?.teardown(it) }
        val appId = config.appId
        executor.execute { store.purgeOtherApps(appId) }
      }
    }
  }

  private fun present(decision: InAppDecision) {
    if (decision !is InAppDecision.Show) return
    val target = presenter
    if (target == null) {
      session.dropPreparing(decision.display.displayId)
      return
    }
    target.present(decision.display)
  }

  private fun dismiss(displayId: String, reason: String) {
    val display = session.display ?: return
    if (!session.markClosed(displayId)) return
    enqueue(display.message.id, InAppEventType.DISMISS, reason = reason)
    presenter?.close(displayId)
    requestFlush()
  }

  private fun enqueue(messageId: String, type: String, buttonId: String? = null, reason: String? = null) {
    val appId = session.config?.appId ?: return
    store.enqueue(appId, messageId, type, buttonId = buttonId, reason = reason)
  }

  private fun scheduleClockCheck() {
    val display = session.display ?: return
    val clock = display.clock ?: return
    if (!clock.isRunning) return
    val displayId = display.displayId
    executor.schedule(clock.remainingMs()) {
      onMain {
        val current = session.display
        if (current?.displayId == displayId && current.clock?.isExpired() == true) {
          dismiss(displayId, InAppDismissReason.AUTO)
        }
      }
    }
  }

  private fun warnInactive(route: InAppRoute) {
    if (session.shouldWarnInactive(route)) logger(INACTIVE_WARNING)
  }

  // Session fetch

  private fun maybeFetch(allowTransientRetry: Boolean) {
    val config = session.config ?: return
    val api = client ?: return
    if (!session.isOpen || session.keyRejected) return
    if (!allowTransientRetry && session.fetch != InAppFetchState.Idle) return
    val pausedUntil = session.eligiblePausedUntilMs
    if (pausedUntil != null && monotonicMs() < pausedUntil) return
    val id = identity() ?: return
    val generation = session.tryStartFetch() ?: return
    val epoch = configEpoch
    val preFlush = !flushRunning
    if (preFlush) flushRunning = true

    executor.execute {
      if (preFlush) {
        val outcome = runFlushPass(api, config.appId, id, singleAttempt = true, headFailures = 0)
        postToMain { onMainSafe { handleFlushOutcome(epoch, outcome) } }
        if (outcome == InAppFlushOutcome.Unauthorized) {
          // A rejected key ends every In-App request of the session (A16).
          postToMain { onMainSafe { session.onFetchGaveUp(generation, transient = false) } }
          return@execute
        }
      }
      sendEligible(api, id, generation, transientFailures = 0, waits = 0)
    }
  }

  /** Executor: one `eligible` request; the result hops to main. */
  private fun sendEligible(
    api: NottiApiClient,
    id: InAppIdentity,
    generation: Long,
    transientFailures: Int,
    waits: Int
  ) {
    val result = try {
      api.fetchEligibleInAppMessages(id.deviceId, id.token)
    } catch (e: Exception) {
      InAppEligibleResult.Transient
    }
    postToMain { onMainSafe { handleEligibleResult(generation, transientFailures, waits, result) } }
  }

  private fun handleEligibleResult(
    generation: Long,
    transientFailures: Int,
    waits: Int,
    result: InAppEligibleResult
  ) {
    // Session ended, a new one started or the config changed: discard (SDKIAM-15).
    if (generation != session.fetchGeneration || !session.isOpen) return
    when (result) {
      is InAppEligibleResult.Messages -> present(session.onFetched(generation, result.messages))
      is InAppEligibleResult.RateLimited -> {
        logger("Notti.inapp: eligible failed (HTTP 429)")
        val seconds = result.retryAfterSeconds
        val tooLong = seconds != null && seconds > InAppTiming.ELIGIBLE_GIVE_UP_RETRY_AFTER_SECONDS
        if (tooLong || waits >= InAppTiming.ELIGIBLE_MAX_RATE_LIMIT_WAITS) {
          session.onFetchGaveUp(generation, transient = false)
          return
        }
        val delayMs = maxOf(1, seconds ?: InAppTiming.DEFAULT_RETRY_AFTER_SECONDS) * 1000L
        session.eligiblePausedUntilMs = monotonicMs() + delayMs
        scheduleEligibleRetry(generation, delayMs, transientFailures, waits + 1)
      }
      InAppEligibleResult.Transient -> {
        logger("Notti.inapp: eligible failed (network or server error)")
        val failures = transientFailures + 1
        if (failures >= InAppTiming.MAX_ATTEMPTS) {
          session.onFetchGaveUp(generation, transient = true)
        } else {
          scheduleEligibleRetry(generation, InAppTiming.backoffMs(failures), failures, waits)
        }
      }
      InAppEligibleResult.Unauthorized -> {
        logger("Notti.inapp: eligible failed (HTTP 401)")
        session.markKeyRejected()
        session.onFetchGaveUp(generation, transient = false)
      }
      InAppEligibleResult.Forbidden -> {
        warnInactive(InAppRoute.ELIGIBLE)
        session.onFetchGaveUp(generation, transient = false)
      }
      is InAppEligibleResult.Terminal -> {
        logger("Notti.inapp: eligible failed (HTTP ${result.status})")
        session.onFetchGaveUp(generation, transient = false)
      }
    }
  }

  private fun scheduleEligibleRetry(generation: Long, delayMs: Long, transientFailures: Int, waits: Int) {
    executor.schedule(delayMs) {
      onMain {
        if (generation != session.fetchGeneration || !session.isOpen || session.keyRejected) return@onMain
        if (session.fetch != InAppFetchState.InFlight) return@onMain
        val api = client ?: return@onMain
        val id = identity()
        if (id == null) {
          session.onFetchGaveUp(generation, transient = true)
          return@onMain
        }
        executor.execute { sendEligible(api, id, generation, transientFailures, waits) }
      }
    }
  }

  // Event flush

  /** Single-flight and coalesced: a trigger during a run asks for one more pass. */
  private fun requestFlush() {
    if (session.config == null || client == null || session.keyRejected) return
    val pausedUntil = session.eventsPausedUntilMs
    if (pausedUntil != null && monotonicMs() < pausedUntil) return
    if (flushRunning) {
      flushAgain = true
      return
    }
    startFlush(headFailures = 0)
  }

  private fun startFlush(headFailures: Int) {
    val config = session.config
    val api = client
    val id = identity()
    if (config == null || api == null || id == null) {
      flushRunning = false
      return
    }
    flushRunning = true
    val epoch = configEpoch
    executor.execute {
      val outcome = runFlushPass(api, config.appId, id, singleAttempt = false, headFailures = headFailures)
      postToMain { onMainSafe { handleFlushOutcome(epoch, outcome) } }
    }
  }

  private fun handleFlushOutcome(epoch: Long, outcome: InAppFlushOutcome) {
    val current = epoch == configEpoch
    if (outcome is InAppFlushOutcome.Backoff && current) {
      // Still running: retry the same head (same event_id) after the backoff.
      executor.schedule(InAppTiming.backoffMs(outcome.failures)) {
        onMain {
          if (epoch == configEpoch && !session.keyRejected) startFlush(outcome.failures) else finishFlush()
        }
      }
      return
    }
    flushRunning = false
    if (current) {
      when (outcome) {
        is InAppFlushOutcome.Paused -> {
          val seconds = (outcome.retryAfterSeconds ?: InAppTiming.DEFAULT_RETRY_AFTER_SECONDS)
            .coerceIn(InAppTiming.EVENTS_MIN_RETRY_AFTER_SECONDS, InAppTiming.EVENTS_MAX_RETRY_AFTER_SECONDS)
          val delayMs = seconds * 1000L
          logger("Notti.inapp: events failed (HTTP 429)")
          session.eventsPausedUntilMs = monotonicMs() + delayMs
          executor.schedule(delayMs) { onMain { requestFlush() } }
        }
        InAppFlushOutcome.Unauthorized -> {
          logger("Notti.inapp: events failed (HTTP 401)")
          session.markKeyRejected()
        }
        InAppFlushOutcome.Forbidden -> warnInactive(InAppRoute.EVENTS)
        InAppFlushOutcome.Failed -> logger("Notti.inapp: events failed (network or server error)")
        else -> Unit
      }
    }
    if (flushAgain) {
      flushAgain = false
      requestFlush()
    }
  }

  private fun finishFlush() {
    flushRunning = false
    if (flushAgain) {
      flushAgain = false
      requestFlush()
    }
  }

  /**
   * Executor: sends the queue of [appId] oldest first, one request at a
   * time. `singleAttempt` stops at the first failure; otherwise a transient
   * failure returns [InAppFlushOutcome.Backoff] until [InAppTiming.MAX_ATTEMPTS].
   */
  private fun runFlushPass(
    api: NottiApiClient,
    appId: String,
    id: InAppIdentity,
    singleAttempt: Boolean,
    headFailures: Int
  ): InAppFlushOutcome {
    store.purgeOtherApps(appId)
    if (store.expire().isNotEmpty()) logger("Notti.inapp: expired events dropped")
    var failures = headFailures
    while (true) {
      val head = store.all(appId).firstOrNull() ?: return InAppFlushOutcome.Done
      val result = try {
        api.reportInAppEvent(head, id.deviceId, id.token)
      } catch (e: Exception) {
        InAppEventResult.Transient
      }
      when (result) {
        InAppEventResult.Recorded -> {
          store.remove(head.id)
          failures = 0
        }
        InAppEventResult.Drop -> {
          logger("Notti.inapp: event rejected by the server, dropped")
          store.remove(head.id)
          failures = 0
        }
        is InAppEventResult.RateLimited -> return InAppFlushOutcome.Paused(result.retryAfterSeconds)
        InAppEventResult.Unauthorized -> return InAppFlushOutcome.Unauthorized
        InAppEventResult.Forbidden -> return InAppFlushOutcome.Forbidden
        InAppEventResult.Transient -> {
          failures++
          if (singleAttempt || failures >= InAppTiming.MAX_ATTEMPTS) return InAppFlushOutcome.Failed
          return InAppFlushOutcome.Backoff(failures)
        }
      }
    }
  }

  private fun onMainSafe(block: () -> Unit) {
    try {
      block()
    } catch (e: Exception) {
      logger("Notti.inapp: internal error (${e.javaClass.simpleName})")
    }
  }
}

/**
 * Process-wide holder: the coordinator outlives RN reloads and module
 * re-creation, like the process session gate (design "Session state").
 */
object NottiInApp {
  @Volatile
  private var instance: NottiInAppCoordinator? = null

  /** Installs [coordinator] unless one exists; returns the installed one. */
  @Synchronized
  fun install(coordinator: NottiInAppCoordinator): NottiInAppCoordinator =
    instance ?: coordinator.also { instance = it }

  fun get(): NottiInAppCoordinator? = instance

  @Synchronized
  internal fun resetForTests() {
    instance = null
  }
}
