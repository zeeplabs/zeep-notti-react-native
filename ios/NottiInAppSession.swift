import Foundation

/// The `initialize` parameters the In-App engine depends on. Kept in memory
/// only; its descriptions never print the client key.
struct InAppConfig: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  let appId: String
  let clientKey: String
  let baseUrl: String

  var description: String { "InAppConfig(appId=<redacted>, clientKey=<redacted>, baseUrl=<redacted>)" }
  var debugDescription: String { description }
}

/// The routes that log the `403` inactive warning, once per session each.
enum InAppRoute: Hashable {
  case eligible
  case events
}

/// Fetch progress of the current session. At most one `done` per session.
enum InAppFetchState: Equatable {
  case idle
  case inFlight
  case done
  case gaveUp(transient: Bool)
}

enum InAppDisplayState: Equatable {
  case preparing
  case visible
  case closed
}

/// The one message that is pending or visible. `displayId` is local and
/// identifies the callbacks of this display; it survives a session end
/// (DD-8). `clock` is nil when the message has no auto-dismiss.
final class InAppDisplay {
  let displayId: String
  let message: InAppMessage
  let clock: NottiInAppDisplayClock?
  fileprivate(set) var state: InAppDisplayState = .preparing
  fileprivate(set) var impressionRecorded = false

  fileprivate init(displayId: String, message: InAppMessage, clock: NottiInAppDisplayClock?) {
    self.displayId = displayId
    self.message = message
    self.clock = clock
  }
}

/// What the coordinator must do after a state change.
enum InAppDecision: Equatable {
  case nothing
  /// Present the display; it is already counted as shown for this session.
  case show(InAppDisplay)

  static func == (lhs: InAppDecision, rhs: InAppDecision) -> Bool {
    switch (lhs, rhs) {
    case (.nothing, .nothing): return true
    case (.show(let a), .show(let b)): return a === b
    default: return false
    }
  }
}

/// Result of `NottiInAppSession.onInitialized`.
enum InAppInitOutcome: Equatable {
  /// Same config as before (RN reload): nothing changed.
  case unchanged
  /// First config of the process.
  case first
  /// The config changed and the state was reset. `teardown` is the display
  /// to remove silently (no terminal outcome, no event); the coordinator
  /// also purges other apps' queued events.
  case changed(teardown: InAppDisplay?)

  static func == (lhs: InAppInitOutcome, rhs: InAppInitOutcome) -> Bool {
    switch (lhs, rhs) {
    case (.unchanged, .unchanged), (.first, .first): return true
    case (.changed(let a), .changed(let b)): return a === b
    default: return false
    }
  }
}

/// Pure In-App selection state, owned by the process-wide coordinator and
/// mutated only on the main thread. It decides what to show; every side
/// effect (presenting, enqueuing events, scheduling) belongs to the caller.
/// Names passed to `trackEvent` are never logged or persisted.
final class NottiInAppSession {

  /// Distinct names remembered before the held messages are known.
  static let maxPendingNames = 32

  private(set) var sessionToken: Int64 = 0
  private(set) var fetchGeneration: Int64 = 0
  private(set) var isOpen = false
  private(set) var awaitingFirstSession = false
  private(set) var config: InAppConfig?
  private(set) var fetch: InAppFetchState = .idle
  private(set) var keyRejected = false
  private(set) var display: InAppDisplay?

  /// Deadlines (monotonic ms) of a `429` pause; reset only by a config change.
  var eligiblePausedUntilMs: Int64?
  var eventsPausedUntilMs: Int64?

  private let monotonicMs: () -> Int64
  private let uuid: () -> String
  private var hasOpenedSession = false
  private var appForeground = true
  private var inactiveWarned = Set<InAppRoute>()
  private var held: [InAppMessage] = []
  private var shownIds = Set<String>()
  private var pendingNames: [String] = []

  var heldMessages: [InAppMessage] { held }
  var shown: Set<String> { shownIds }
  var pending: [String] { pendingNames }

  init(
    monotonicMs: @escaping () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
    uuid: @escaping () -> String = { UUID().uuidString }
  ) {
    self.monotonicMs = monotonicMs
    self.uuid = uuid
  }

  func onInitialized(_ newConfig: InAppConfig) -> InAppInitOutcome {
    let previous = config
    if previous == newConfig { return .unchanged }
    config = newConfig
    awaitingFirstSession = !hasOpenedSession
    if previous == nil { return .first }

    fetchGeneration += 1
    held.removeAll()
    pendingNames.removeAll()
    shownIds.removeAll()
    fetch = .idle
    eligiblePausedUntilMs = nil
    eventsPausedUntilMs = nil
    keyRejected = false
    inactiveWarned.removeAll()
    let teardown = display
    display = nil
    teardown?.state = .closed
    return .changed(teardown: teardown)
  }

  func onSessionStarted() {
    sessionToken += 1
    fetchGeneration += 1
    isOpen = true
    hasOpenedSession = true
    awaitingFirstSession = false
    keyRejected = false
    inactiveWarned.removeAll()
    fetch = .idle
    held.removeAll()
    shownIds.removeAll()
    if let current = display { shownIds.insert(current.message.id) }
  }

  /// Ends the session. A visible display is kept (DD-8); a display that never
  /// became visible is dropped and returned so the caller removes it silently.
  @discardableResult
  func onSessionEnded() -> InAppDisplay? {
    fetchGeneration += 1
    held.removeAll()
    if isOpen { pendingNames.removeAll() }
    isOpen = false
    fetch = .idle
    guard let current = display, current.state != .visible else { return nil }
    display = nil
    current.state = .closed
    return current
  }

  func isCurrentSession(_ token: Int64) -> Bool { isOpen && token == sessionToken }

  /// Starts the session fetch, returning the generation the request must
  /// carry, or nil when no fetch may start (no session, key rejected, already
  /// in flight or done, or a non-transient give-up).
  func tryStartFetch() -> Int64? {
    guard isOpen, !keyRejected else { return nil }
    switch fetch {
    case .idle, .gaveUp(transient: true): break
    default: return nil
    }
    fetch = .inFlight
    return fetchGeneration
  }

  func onFetchGaveUp(generation: Int64, transient: Bool) {
    guard generation == fetchGeneration, isOpen else { return }
    fetch = .gaveUp(transient: transient)
  }

  /// Processes an `eligible` response. A stale `generation` (session ended,
  /// new session, config change) is discarded: nothing shown, nothing held.
  func onFetched(generation: Int64, messages: [InAppMessage]) -> InAppDecision {
    guard generation == fetchGeneration, isOpen else { return .nothing }
    fetch = .done
    var decision = InAppDecision.nothing

    let renderable = messages.filter(\.renderable)
    held = renderable.filter {
      if case .event = $0.trigger { return true }
      return false
    }
    if display == nil,
      let first = renderable.first(where: { $0.trigger == .sessionStart && !shownIds.contains($0.id) })
    {
      decision = select(first)
    }

    let names = pendingNames
    pendingNames.removeAll()
    for name in names {
      let replayed = matchHeld(name)
      if case .show = replayed { decision = replayed }
    }
    return decision
  }

  func trackEvent(_ name: String) -> InAppDecision {
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || config == nil { return .nothing }
    if !isOpen && !awaitingFirstSession { return .nothing }
    if awaitingFirstSession || fetch != .done {
      if !pendingNames.contains(name) && pendingNames.count < Self.maxPendingNames {
        pendingNames.append(name)
      }
      return .nothing
    }
    return matchHeld(name)
  }

  /// Marks the display visible. True exactly once per display: the caller
  /// enqueues the impression only then. Starts the auto-dismiss clock.
  func markVisible(_ displayId: String) -> Bool {
    guard let current = display, current.displayId == displayId, !current.impressionRecorded,
      current.state == .preparing
    else {
      return false
    }
    current.state = .visible
    current.impressionRecorded = true
    current.clock?.start()
    return true
  }

  /// Closes a visible display. True exactly once: the caller then enqueues
  /// one terminal event (click or dismiss). False before visible or after
  /// the display was already closed or replaced.
  func markClosed(_ displayId: String) -> Bool {
    guard let current = display, current.displayId == displayId, current.state == .visible else {
      return false
    }
    current.state = .closed
    display = nil
    return true
  }

  /// Drops a display that never became visible (presentation failed).
  func dropPreparing(_ displayId: String) -> Bool {
    guard let current = display, current.displayId == displayId, current.state == .preparing else {
      return false
    }
    current.state = .closed
    display = nil
    return true
  }

  func setAppForeground(_ foreground: Bool) {
    appForeground = foreground
    display?.clock?.setForeground(foreground)
  }

  func markKeyRejected() {
    keyRejected = true
  }

  /// True the first time per session for `route`: log the `403` warning then.
  func shouldWarnInactive(_ route: InAppRoute) -> Bool {
    inactiveWarned.insert(route).inserted
  }

  private func matchHeld(_ name: String) -> InAppDecision {
    guard display == nil else { return .nothing }
    let match = held.first { message in
      guard case .event(let triggerName) = message.trigger else { return false }
      return triggerName == name && !shownIds.contains(message.id)
    }
    guard let message = match else { return .nothing }
    return select(message)
  }

  private func select(_ message: InAppMessage) -> InAppDecision {
    let clock = NottiInAppDisplayClock.create(seconds: message.dismissAfterSeconds, monotonicMs: monotonicMs)
    clock?.setForeground(appForeground)
    let created = InAppDisplay(displayId: uuid(), message: message, clock: clock)
    display = created
    shownIds.insert(message.id)
    return .show(created)
  }
}

/// Visible-time accounting for `dismiss_after_seconds`. Time runs only after
/// `start()` and while the display is attached and the app is in the
/// foreground; pausing keeps the remaining time. The caller schedules a check
/// at `remainingMs()` whenever `isRunning` and closes the display when
/// `isExpired()`.
final class NottiInAppDisplayClock {

  private static let minSeconds = 1
  private static let maxSeconds = 300

  /// Nil when `seconds` is absent or outside 1..300 (no auto-dismiss).
  static func create(seconds: Int?, monotonicMs: @escaping () -> Int64) -> NottiInAppDisplayClock? {
    guard let seconds = seconds, seconds >= minSeconds, seconds <= maxSeconds else { return nil }
    return NottiInAppDisplayClock(durationMs: Int64(seconds) * 1000, monotonicMs: monotonicMs)
  }

  private let monotonicMs: () -> Int64
  private var remainingAtPauseMs: Int64
  private var runningSinceMs: Int64?
  private var started = false
  private var attached = false
  private var foreground = true

  private init(durationMs: Int64, monotonicMs: @escaping () -> Int64) {
    self.remainingAtPauseMs = durationMs
    self.monotonicMs = monotonicMs
  }

  var isRunning: Bool { runningSinceMs != nil }

  func start() {
    started = true
    update()
  }

  func setAttached(_ value: Bool) {
    attached = value
    update()
  }

  func setForeground(_ value: Bool) {
    foreground = value
    update()
  }

  func remainingMs() -> Int64 {
    guard let since = runningSinceMs else { return remainingAtPauseMs }
    return max(remainingAtPauseMs - (monotonicMs() - since), 0)
  }

  func isExpired() -> Bool { remainingMs() == 0 }

  private func update() {
    let shouldRun = started && attached && foreground
    if shouldRun, runningSinceMs == nil {
      runningSinceMs = monotonicMs()
    } else if !shouldRun, let since = runningSinceMs {
      remainingAtPauseMs = max(remainingAtPauseMs - (monotonicMs() - since), 0)
      runningSinceMs = nil
    }
  }
}
