import Foundation

/// Device identity read at call time. Its descriptions never print either value.
struct InAppIdentity: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  let deviceId: String
  let token: String

  var description: String { "InAppIdentity(<redacted>)" }
  var debugDescription: String { description }
}

/// A click delivered to the host listener, action untouched (SDKIAM-67).
struct InAppClick: Equatable {
  let messageId: String
  let buttonId: String
  let action: InAppAction?
}

/// `reason` values of a `dismiss` event (SDKIAM-43).
enum InAppDismissReason {
  static let closeButton = "close_button"
  static let swipe = "swipe"
  static let outsideTap = "outside_tap"
  static let auto = "auto"
}

/// Background work port: the In-App queue in production, a fake in tests.
protocol InAppExecutor: AnyObject {
  func execute(_ task: @escaping () -> Void)
  func schedule(delayMs: Int64, _ task: @escaping () -> Void)
}

/// Shows and removes the overlay. Every call comes from the main thread.
/// `close` removes a display after its terminal outcome was reported;
/// `teardown` removes one silently (config change, session ended before it
/// became visible). Both must be idempotent.
protocol InAppPresenter: AnyObject {
  func present(_ display: InAppDisplay)
  func close(_ displayId: String)
  func teardown(_ display: InAppDisplay)
}

/// What the presenter reports back, from any thread.
protocol InAppDisplayEvents: AnyObject {
  func onDisplayAttached(_ displayId: String, attached: Bool)
  func onDisplayVisible(_ displayId: String)
  func onDisplayClicked(_ displayId: String, buttonId: String, action: InAppAction?)
  func onDisplayDismissed(_ displayId: String, reason: String)
  func onDisplayFailed(_ displayId: String)
}

/// What `NottiCore` tells In-App. Network and foreground/background reach the
/// coordinator straight from their observers, which also run with no core.
protocol NottiInAppHooks: AnyObject {
  /// A foreground session was opened (the process session gate flipped).
  func onSessionStarted()
  /// The device registration succeeded and the push event queue was flushed.
  func onRegistered()
}

/// Delivers a click to JS. False when no listener can receive it (SDKIAM-68).
typealias InAppClickSink = (InAppClick) -> Bool

/// Retry and pause constants of both routes, adjustable in one place.
enum InAppTiming {
  /// Requests per transient failure streak (2/4/8/16 s between them).
  static let maxAttempts = 5
  static let baseBackoffMs: Int64 = 2000

  /// `Retry-After` used when it is absent or not an integer of seconds.
  static let defaultRetryAfterSeconds = 60

  /// `eligible` 429: a `Retry-After` above this gives up for the session.
  static let eligibleGiveUpRetryAfterSeconds = 60
  static let eligibleMaxRateLimitWaits = 3

  /// Events 429: clamp of the stored pause.
  static let eventsMinRetryAfterSeconds = 1
  static let eventsMaxRetryAfterSeconds = 300

  static func backoffMs(_ failures: Int) -> Int64 {
    baseBackoffMs << Int64(min(max(failures - 1, 0), 30))
  }
}

/// Production `InAppExecutor`: one serial utility queue, delays with
/// `asyncAfter` (never a sleeping thread).
final class NottiInAppScheduler: InAppExecutor {
  private let queue = DispatchQueue(label: "app.notti.sdk.inapp", qos: .utility)

  func execute(_ task: @escaping () -> Void) {
    queue.async(execute: task)
  }

  func schedule(delayMs: Int64, _ task: @escaping () -> Void) {
    queue.asyncAfter(deadline: .now() + .milliseconds(Int(clamping: max(delayMs, 0))), execute: task)
  }
}

/// Outcome of one flush pass, computed on the executor.
enum InAppFlushOutcome: Equatable {
  case done
  case paused(retryAfterSeconds: Int?)
  case unauthorized
  case forbidden
  case failed
  /// `full` mode: the head failed `failures` times in a row; retry it after a backoff.
  case backoff(failures: Int)
}

/// Process-wide In-App orchestrator. Public entry points may be called from
/// any thread: they hop to main through `postToMain`, where every state
/// change happens (DD-4). Network work runs on `executor`. It never opens a
/// URL and never logs ids, names, URLs, tokens or bodies (SDKIAM-32/54).
final class NottiInAppCoordinator: InAppDisplayEvents {

  static let inactiveWarning = "Notti.inapp: In-App is inactive on this device until the next registration"
  static let noListenerWarning = "Notti.inapp: click reported but no click listener is registered"

  let session: NottiInAppSession

  /// Set by the presentation layer; read on main only.
  var presenter: InAppPresenter?
  /// Set to the live module's emitter by the wiring; the SDK itself never opens a link (A9).
  var clickSink: InAppClickSink?

  private let store: NottiInAppEventStore
  private let clientFactory: (InAppConfig) -> NottiApiClient
  private let identity: () -> InAppIdentity?
  private let executor: InAppExecutor
  private let postToMain: (@escaping () -> Void) -> Void
  private let monotonicMs: () -> Int64
  private let logger: (String) -> Void

  private var client: NottiApiClient?
  /// Incremented on a config change: results of older work only release their flags.
  private var configEpoch: Int64 = 0
  private var flushRunning = false
  private var flushAgain = false

  init(
    store: NottiInAppEventStore,
    clientFactory: @escaping (InAppConfig) -> NottiApiClient,
    identity: @escaping () -> InAppIdentity?,
    executor: InAppExecutor,
    postToMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
    monotonicMs: @escaping () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
    logger: @escaping (String) -> Void = { _ in },
    session: NottiInAppSession? = nil
  ) {
    self.store = store
    self.clientFactory = clientFactory
    self.identity = identity
    self.executor = executor
    self.postToMain = postToMain
    self.monotonicMs = monotonicMs
    self.logger = logger
    self.session = session ?? NottiInAppSession(monotonicMs: monotonicMs)
  }

  // MARK: - Entry points (any thread)

  func onInitialized(appId: String, clientKey: String, baseUrl: String) {
    let config = InAppConfig(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    postToMain { self.handleInitialized(config) }
  }

  func onSessionStarted() {
    postToMain {
      self.session.onSessionStarted()
      self.maybeFetch(allowTransientRetry: false)
    }
  }

  func onSessionEnded() {
    postToMain {
      if let dropped = self.session.onSessionEnded() { self.presenter?.teardown(dropped) }
    }
  }

  func onRegistered() {
    postToMain {
      self.requestFlush()
      self.maybeFetch(allowTransientRetry: false)
    }
  }

  func onNetworkAvailable() {
    postToMain {
      self.requestFlush()
      self.maybeFetch(allowTransientRetry: true)
    }
  }

  func onAppForegrounded() {
    postToMain {
      self.session.setAppForeground(true)
      self.scheduleClockCheck()
      self.requestFlush()
    }
  }

  func onAppBackgrounded() {
    postToMain { self.session.setAppForeground(false) }
  }

  /// Never traps, never sends or logs `name` (SDKIAM-10, SDKIAM-59).
  func trackEvent(_ name: String) {
    postToMain { self.present(self.session.trackEvent(name)) }
  }

  // MARK: - Presenter callbacks (any thread)

  func onDisplayAttached(_ displayId: String, attached: Bool) {
    postToMain {
      guard let display = self.session.display, display.displayId == displayId else { return }
      display.clock?.setAttached(attached)
      self.scheduleClockCheck()
    }
  }

  /// First layout while attached and in the foreground: one impression per display (SDKIAM-40).
  func onDisplayVisible(_ displayId: String) {
    postToMain {
      guard let display = self.session.display, self.session.markVisible(displayId) else { return }
      self.enqueue(messageId: display.message.id, type: InAppEventType.impression)
      self.scheduleClockCheck()
      self.requestFlush()
    }
  }

  /// A button, the image or a bar body was tapped (SDKIAM-33/42): `click`
  /// enqueued, then delivered, then the display closed with no `dismiss`.
  func onDisplayClicked(_ displayId: String, buttonId: String, action: InAppAction?) {
    postToMain {
      guard let display = self.session.display, self.session.markClosed(displayId) else { return }
      let messageId = display.message.id
      self.enqueue(messageId: messageId, type: InAppEventType.click, buttonId: buttonId)
      let delivered = self.clickSink?(InAppClick(messageId: messageId, buttonId: buttonId, action: action)) ?? false
      if !delivered { self.logger(Self.noListenerWarning) }
      self.presenter?.close(displayId)
      self.requestFlush()
    }
  }

  func onDisplayDismissed(_ displayId: String, reason: String) {
    postToMain { self.dismiss(displayId, reason: reason) }
  }

  /// The display could not be presented; it is dropped with no event.
  func onDisplayFailed(_ displayId: String) {
    postToMain { _ = self.session.dropPreparing(displayId) }
  }

  // MARK: - Main-thread handlers

  private func handleInitialized(_ config: InAppConfig) {
    switch session.onInitialized(config) {
    case .unchanged:
      break
    case .first:
      client = clientFactory(config)
    case .changed(let teardown):
      configEpoch += 1
      client = clientFactory(config)
      if let teardown = teardown { presenter?.teardown(teardown) }
      let appId = config.appId
      let store = self.store
      executor.execute { store.purgeOtherApps(appId) }
    }
  }

  private func present(_ decision: InAppDecision) {
    guard case .show(let display) = decision else { return }
    guard let target = presenter else {
      _ = session.dropPreparing(display.displayId)
      return
    }
    target.present(display)
  }

  private func dismiss(_ displayId: String, reason: String) {
    guard let display = session.display, session.markClosed(displayId) else { return }
    enqueue(messageId: display.message.id, type: InAppEventType.dismiss, reason: reason)
    presenter?.close(displayId)
    requestFlush()
  }

  private func enqueue(messageId: String, type: String, buttonId: String? = nil, reason: String? = nil) {
    guard let appId = session.config?.appId else { return }
    store.enqueue(appId: appId, messageId: messageId, type: type, buttonId: buttonId, reason: reason)
  }

  private func scheduleClockCheck() {
    guard let display = session.display, let clock = display.clock, clock.isRunning else { return }
    let displayId = display.displayId
    executor.schedule(delayMs: clock.remainingMs()) {
      self.postToMain {
        guard let current = self.session.display, current.displayId == displayId,
          current.clock?.isExpired() == true
        else {
          return
        }
        self.dismiss(displayId, reason: InAppDismissReason.auto)
      }
    }
  }

  private func warnInactive(_ route: InAppRoute) {
    if session.shouldWarnInactive(route) { logger(Self.inactiveWarning) }
  }

  // MARK: - Session fetch

  private func maybeFetch(allowTransientRetry: Bool) {
    guard let config = session.config, let api = client else { return }
    guard session.isOpen, !session.keyRejected else { return }
    if !allowTransientRetry && session.fetch != .idle { return }
    if let pausedUntil = session.eligiblePausedUntilMs, monotonicMs() < pausedUntil { return }
    guard let id = identity(), let generation = session.tryStartFetch() else { return }
    let epoch = configEpoch
    let preFlush = !flushRunning
    if preFlush { flushRunning = true }

    executor.execute {
      if preFlush {
        let outcome = self.runFlushPass(api, appId: config.appId, id: id, singleAttempt: true, headFailures: 0)
        self.postToMain { self.handleFlushOutcome(epoch: epoch, outcome) }
        if outcome == .unauthorized {
          // A rejected key ends every In-App request of the session (A16).
          self.postToMain { self.session.onFetchGaveUp(generation: generation, transient: false) }
          return
        }
      }
      self.sendEligible(api, id: id, generation: generation, transientFailures: 0, waits: 0)
    }
  }

  /// Executor: one `eligible` request; the result hops to main.
  private func sendEligible(
    _ api: NottiApiClient,
    id: InAppIdentity,
    generation: Int64,
    transientFailures: Int,
    waits: Int
  ) {
    let result = api.fetchEligibleInAppMessages(deviceId: id.deviceId, token: id.token)
    postToMain {
      self.handleEligibleResult(generation: generation, transientFailures: transientFailures, waits: waits, result)
    }
  }

  private func handleEligibleResult(
    generation: Int64,
    transientFailures: Int,
    waits: Int,
    _ result: InAppEligibleResult
  ) {
    // Session ended, a new one started or the config changed: discard (SDKIAM-15).
    guard generation == session.fetchGeneration, session.isOpen else { return }
    switch result {
    case .messages(let messages):
      present(session.onFetched(generation: generation, messages: messages))
    case .rateLimited(let seconds):
      logger("Notti.inapp: eligible failed (HTTP 429)")
      let tooLong = seconds.map { $0 > InAppTiming.eligibleGiveUpRetryAfterSeconds } ?? false
      if tooLong || waits >= InAppTiming.eligibleMaxRateLimitWaits {
        session.onFetchGaveUp(generation: generation, transient: false)
        return
      }
      let delayMs = Int64(max(1, seconds ?? InAppTiming.defaultRetryAfterSeconds)) * 1000
      session.eligiblePausedUntilMs = monotonicMs() + delayMs
      scheduleEligibleRetry(generation: generation, delayMs: delayMs, transientFailures: transientFailures, waits: waits + 1)
    case .transient:
      logger("Notti.inapp: eligible failed (network or server error)")
      let failures = transientFailures + 1
      if failures >= InAppTiming.maxAttempts {
        session.onFetchGaveUp(generation: generation, transient: true)
      } else {
        scheduleEligibleRetry(
          generation: generation, delayMs: InAppTiming.backoffMs(failures), transientFailures: failures, waits: waits)
      }
    case .unauthorized:
      logger("Notti.inapp: eligible failed (HTTP 401)")
      session.markKeyRejected()
      session.onFetchGaveUp(generation: generation, transient: false)
    case .forbidden:
      warnInactive(.eligible)
      session.onFetchGaveUp(generation: generation, transient: false)
    case .terminal(let status):
      logger("Notti.inapp: eligible failed (HTTP \(status))")
      session.onFetchGaveUp(generation: generation, transient: false)
    }
  }

  private func scheduleEligibleRetry(generation: Int64, delayMs: Int64, transientFailures: Int, waits: Int) {
    executor.schedule(delayMs: delayMs) {
      self.postToMain {
        guard generation == self.session.fetchGeneration, self.session.isOpen, !self.session.keyRejected else { return }
        guard self.session.fetch == .inFlight, let api = self.client else { return }
        guard let id = self.identity() else {
          self.session.onFetchGaveUp(generation: generation, transient: true)
          return
        }
        self.executor.execute {
          self.sendEligible(api, id: id, generation: generation, transientFailures: transientFailures, waits: waits)
        }
      }
    }
  }

  // MARK: - Event flush

  /// Single-flight and coalesced: a trigger during a run asks for one more pass.
  private func requestFlush() {
    guard session.config != nil, client != nil, !session.keyRejected else { return }
    if let pausedUntil = session.eventsPausedUntilMs, monotonicMs() < pausedUntil { return }
    if flushRunning {
      flushAgain = true
      return
    }
    startFlush(headFailures: 0)
  }

  private func startFlush(headFailures: Int) {
    guard let config = session.config, let api = client, let id = identity() else {
      flushRunning = false
      return
    }
    flushRunning = true
    let epoch = configEpoch
    executor.execute {
      let outcome = self.runFlushPass(api, appId: config.appId, id: id, singleAttempt: false, headFailures: headFailures)
      self.postToMain { self.handleFlushOutcome(epoch: epoch, outcome) }
    }
  }

  private func handleFlushOutcome(epoch: Int64, _ outcome: InAppFlushOutcome) {
    let current = epoch == configEpoch
    if case .backoff(let failures) = outcome, current {
      // Still running: retry the same head (same event_id) after the backoff.
      executor.schedule(delayMs: InAppTiming.backoffMs(failures)) {
        self.postToMain {
          if epoch == self.configEpoch && !self.session.keyRejected {
            self.startFlush(headFailures: failures)
          } else {
            self.finishFlush()
          }
        }
      }
      return
    }
    flushRunning = false
    if current {
      switch outcome {
      case .paused(let retryAfter):
        let seconds = min(
          max(retryAfter ?? InAppTiming.defaultRetryAfterSeconds, InAppTiming.eventsMinRetryAfterSeconds),
          InAppTiming.eventsMaxRetryAfterSeconds)
        let delayMs = Int64(seconds) * 1000
        logger("Notti.inapp: events failed (HTTP 429)")
        session.eventsPausedUntilMs = monotonicMs() + delayMs
        executor.schedule(delayMs: delayMs) { self.postToMain { self.requestFlush() } }
      case .unauthorized:
        logger("Notti.inapp: events failed (HTTP 401)")
        session.markKeyRejected()
      case .forbidden:
        warnInactive(.events)
      case .failed:
        logger("Notti.inapp: events failed (network or server error)")
      case .done, .backoff:
        break
      }
    }
    if flushAgain {
      flushAgain = false
      requestFlush()
    }
  }

  private func finishFlush() {
    flushRunning = false
    if flushAgain {
      flushAgain = false
      requestFlush()
    }
  }

  /// Executor: sends the queue of `appId` oldest first, one request at a
  /// time. `singleAttempt` stops at the first failure; otherwise a transient
  /// failure returns `.backoff` until `InAppTiming.maxAttempts`.
  private func runFlushPass(
    _ api: NottiApiClient,
    appId: String,
    id: InAppIdentity,
    singleAttempt: Bool,
    headFailures: Int
  ) -> InAppFlushOutcome {
    store.purgeOtherApps(appId)
    if !store.expire().isEmpty { logger("Notti.inapp: expired events dropped") }
    var failures = headFailures
    while true {
      guard let head = store.all(forApp: appId).first else { return .done }
      switch api.reportInAppEvent(head, deviceId: id.deviceId, token: id.token) {
      case .recorded:
        store.remove(id: head.id)
        failures = 0
      case .drop:
        logger("Notti.inapp: event rejected by the server, dropped")
        store.remove(id: head.id)
        failures = 0
      case .rateLimited(let seconds):
        return .paused(retryAfterSeconds: seconds)
      case .unauthorized:
        return .unauthorized
      case .forbidden:
        return .forbidden
      case .transient:
        failures += 1
        if singleAttempt || failures >= InAppTiming.maxAttempts { return .failed }
        return .backoff(failures: failures)
      }
    }
  }
}

/// Process-wide holder: the coordinator outlives RN reloads and module
/// re-creation, like the process session gate (design "Session state").
enum NottiInApp {
  private static let lock = NSLock()
  private static var instance: NottiInAppCoordinator?

  /// Installs `coordinator` unless one exists; returns the installed one.
  @discardableResult
  static func install(_ coordinator: NottiInAppCoordinator) -> NottiInAppCoordinator {
    lock.lock()
    defer { lock.unlock() }
    if let existing = instance { return existing }
    instance = coordinator
    return coordinator
  }

  static func get() -> NottiInAppCoordinator? {
    lock.lock()
    defer { lock.unlock() }
    return instance
  }

  /// Passed to every `NottiCore`; forwards to whichever coordinator is installed.
  static let coreHooks: NottiInAppHooks = CoreHooks()

  private final class CoreHooks: NottiInAppHooks {
    func onSessionStarted() { NottiInApp.get()?.onSessionStarted() }
    func onRegistered() { NottiInApp.get()?.onRegistered() }
  }

  static func resetForTests() {
    lock.lock()
    defer { lock.unlock() }
    instance = nil
  }
}
