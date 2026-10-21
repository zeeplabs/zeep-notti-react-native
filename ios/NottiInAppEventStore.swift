import Foundation

/// Event types accepted by `POST .../in-app-messages/{id}/events`.
enum InAppEventType {
  static let impression = "impression"
  static let click = "click"
  static let dismiss = "dismiss"
}

/// An In-App event waiting to be reported. `id` is local to the queue;
/// `eventId` is the UUID v4 sent to the server (idempotency key). `appId` is
/// the app the event was created for, so a change of app id never sends an
/// event to a message of another app. No token and no device id are stored:
/// both are read at send time.
struct InAppPendingEvent: Codable, Equatable {
  let id: String
  let eventId: String
  let appId: String
  let messageId: String
  let type: String
  let buttonId: String?
  let reason: String?
  let occurredAtMs: Int64
}

/// Persisted write-ahead queue of `InAppPendingEvent`, a JSON array under one
/// key of the `notti_prefs` suite. Independent of `NottiEventStore`: filling
/// one never evicts the other. Usable before any other component exists.
final class NottiInAppEventStore {

  private static let keyPendingEvents = "notti_pending_inapp_events"

  /// At most 3 events per display, so 100 covers weeks offline.
  static let maxPendingEvents = 100

  /// Events older than this (by `occurredAtMs`) are dropped.
  static let ttlMs: Int64 = 7 * 24 * 60 * 60 * 1000

  /// Process-wide lock around every read-modify-write: the main thread
  /// enqueues while the In-App queue removes flushed records, and two store
  /// instances can be built over the same suite.
  private static let lock = NSLock()

  private let defaults: UserDefaults
  private let clock: () -> Int64
  private let uuid: () -> String

  init(
    defaults: UserDefaults,
    clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
    uuid: @escaping () -> String = { UUID().uuidString.lowercased() }
  ) {
    self.defaults = defaults
    self.clock = clock
    self.uuid = uuid
  }

  /// Appends a new event, persisting immediately. Events already expired are
  /// dropped first, then the oldest are dropped past `maxPendingEvents`.
  @discardableResult
  func enqueue(
    appId: String,
    messageId: String,
    type: String,
    buttonId: String? = nil,
    reason: String? = nil
  ) -> InAppPendingEvent {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    let now = clock()
    let event = InAppPendingEvent(
      id: uuid(),
      eventId: uuid(),
      appId: appId,
      messageId: messageId,
      type: type,
      buttonId: buttonId,
      reason: reason,
      occurredAtMs: now
    )
    var live = readLocked().filter { !Self.isExpired($0, now: now) }
    live.append(event)
    if live.count > Self.maxPendingEvents {
      live.removeFirst(live.count - Self.maxPendingEvents)
    }
    writeLocked(live)
    return event
  }

  /// Every queued event, in insertion order.
  func all() -> [InAppPendingEvent] {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    return readLocked()
  }

  /// Only the events created for `forApp`, in insertion order.
  func all(forApp appId: String) -> [InAppPendingEvent] {
    all().filter { $0.appId == appId }
  }

  /// Removes the event with `id`, persisting the remaining queue.
  func remove(id: String) {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    let current = readLocked()
    let kept = current.filter { $0.id != id }
    if kept.count != current.count { writeLocked(kept) }
  }

  /// Drops the events older than `ttlMs` at `now` and returns them (so the
  /// flush can log the drop). An event exactly `ttlMs` old is kept.
  @discardableResult
  func expire(now: Int64? = nil) -> [InAppPendingEvent] {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    let at = now ?? clock()
    let current = readLocked()
    let expired = current.filter { Self.isExpired($0, now: at) }
    if !expired.isEmpty { writeLocked(current.filter { !Self.isExpired($0, now: at) }) }
    return expired
  }

  /// Removes every event whose `appId` differs from `appId`, keeping the
  /// order of the rest.
  func purgeOtherApps(_ appId: String) {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    let current = readLocked()
    let kept = current.filter { $0.appId == appId }
    if kept.count != current.count { writeLocked(kept) }
  }

  private static func isExpired(_ event: InAppPendingEvent, now: Int64) -> Bool {
    now - event.occurredAtMs > ttlMs
  }

  /// Caller must hold `lock`. A stored value that is not a well-formed queue
  /// is removed so the queue self-heals to empty.
  private func readLocked() -> [InAppPendingEvent] {
    guard defaults.object(forKey: Self.keyPendingEvents) != nil else { return [] }
    guard
      let data = defaults.data(forKey: Self.keyPendingEvents),
      let events = try? JSONDecoder().decode([InAppPendingEvent].self, from: data)
    else {
      defaults.removeObject(forKey: Self.keyPendingEvents)
      return []
    }
    return events
  }

  /// Caller must hold `lock`.
  private func writeLocked(_ events: [InAppPendingEvent]) {
    if let data = try? JSONEncoder().encode(events) {
      defaults.set(data, forKey: Self.keyPendingEvents)
    }
  }
}
