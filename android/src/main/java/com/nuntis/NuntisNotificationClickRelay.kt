package com.nuntis

/**
 * Decouples "a notification click was detected" from "a TurboModule instance
 * exists to emit it on".
 *
 * TurboModules are lazy (`needsEagerInit = false`), so on a cold start from a
 * notification tap the host Activity's `onCreate`/`onResume` - where the
 * launch intent's extras live - run before [NuntisModule] is ever constructed
 * (spec P3-AC7, the killed-app click path). The click is therefore buffered
 * here and delivered as soon as a module attaches, in the shape of
 * `getInitialNotification()`-style patterns in other push SDKs, except that
 * the replay is automatic rather than requiring a JS pull.
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

  /** Attaches the live module's emitter and drains any buffered cold-start click. */
  fun attach(emitter: (ParsedNotification) -> Unit) {
    val buffered = synchronized(lock) {
      this.emitter = emitter
      val buffered = pending
      pending = null
      buffered
    }
    buffered?.let(emitter)
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
