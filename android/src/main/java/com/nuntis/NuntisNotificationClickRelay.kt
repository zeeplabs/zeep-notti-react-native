package com.nuntis

/**
 * Decouples "a notification click was detected" from "a TurboModule instance
 * exists to emit it on".
 *
 * TurboModules are lazy (`needsEagerInit = false`), so on a cold start from a
 * notification tap the host Activity's `onCreate`/`onResume` - where the
 * launch intent's extras live - run before [NuntisModule] is ever constructed
 * (spec P3-AC7, the killed-app click path). The click is therefore buffered
 * here and handed out on demand by [takePending], which backs the Spec's
 * `getInitialNotificationClick()`.
 *
 * The buffered click is deliberately *not* replayed through the event emitter
 * when a module attaches. Attaching happens while the JS bundle is still being
 * evaluated (`TurboModuleRegistry.getEnforcing` constructs the module), which
 * is strictly before any `addEventListener('notificationClicked', …)` inside a
 * `useEffect` can run - an EventEmitter has no buffering for a subscriber that
 * does not exist yet, so an auto-replay was always emitted into the void. JS
 * pulls it instead; clicks arriving while the app is already alive still go
 * out as events through [emit].
 *
 * Only one payload is buffered: a second cold-start click cannot exist without
 * a process restart, and while the app is alive the emitter is attached.
 */
object NuntisNotificationClickRelay {

  private val lock = Any()
  private var pending: ParsedNotification? = null
  private var emitter: ((ParsedNotification) -> Unit)? = null

  /** Emits now if a module is attached, otherwise buffers for the next attach. */
  fun emit(notification: ParsedNotification) {
    val target = synchronized(lock) {
      val current = emitter
      if (current == null) {
        pending = notification
      }
      current
    }
    target?.invoke(notification)
  }

  /**
   * Attaches the live module's emitter for clicks that arrive from now on. Any
   * already-buffered cold-start click stays buffered: see the class doc - no
   * JS listener can be subscribed yet at this point, so replaying it here
   * would drop it. It is delivered by [takePending] instead.
   */
  fun attach(emitter: (ParsedNotification) -> Unit) {
    synchronized(lock) { this.emitter = emitter }
  }

  /**
   * Returns the buffered cold-start click and clears it, so a second call
   * without a new cold start returns null (the Spec's
   * `getInitialNotificationClick()` contract: consumed exactly once).
   */
  fun takePending(): ParsedNotification? = synchronized(lock) {
    val buffered = pending
    pending = null
    buffered
  }

  /**
   * Detaches [emitter] if it is still the current one. Guarded by identity so
   * a torn-down module can never unhook the module that replaced it.
   */
  fun detach(emitter: (ParsedNotification) -> Unit) {
    synchronized(lock) {
      if (this.emitter === emitter) {
        this.emitter = null
      }
    }
  }

  /** Test-only: this is process-wide state that outlives a single test case. */
  internal fun reset() {
    synchronized(lock) {
      emitter = null
      pending = null
    }
  }
}
