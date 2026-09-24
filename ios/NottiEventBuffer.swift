import Foundation

public enum NottiNotificationEvent: String {
  case received
  case clicked
}

/// Holds notification events that fire before anything is listening.
///
/// On a cold launch from a notification tap, iOS calls
/// `userNotificationCenter(_:didReceive:)` while the RN bridge is still
/// starting: the TurboModule instance (and therefore the Codegen event
/// emitter JS subscribes to) does not exist yet, so emitting right away sends
/// the click into the void and the app never learns why it was launched —
/// the gap `react-native-firebase` closes with `getInitialNotification()`.
///
/// Events emitted with no handler attached are buffered here. What happens
/// next differs by kind:
///
/// - `received` is replayed, in order, the moment the TurboModule wires its
///   emitter up (`NottiImpl.emitReceivedHandler`).
/// - `clicked` is **not** replayed. Wiring the emitter up happens while the JS
///   bundle is still being evaluated (`TurboModuleRegistry.getEnforcing`),
///   strictly before any `addEventListener('notificationClicked', ...)` in a
///   `useEffect` can run, so a replayed cold-start click reached no subscriber
///   and was lost. It stays buffered until JS pulls it with
///   `getInitialNotificationClick()` (`takeInitialClick()` here), which is the
///   same shape as `react-native-firebase`'s `getInitialNotification()`.
///   Clicks arriving while JS is alive still go out as events, unchanged.
///
/// Delivery is deduped by the notification's stable identifier, so a payload
/// that also reaches the direct delegate path is never delivered twice.
public final class NottiEventBuffer {

  public static let shared = NottiEventBuffer()

  /// Enough to cover a cold start; a stuck bridge cannot grow this unbounded.
  private static let maxBufferedEvents = 10
  private static let maxRememberedDeliveries = 50

  private struct BufferedEvent {
    let event: NottiNotificationEvent
    let key: String
    let payload: [String: Any]
  }

  private let lock = NSLock()
  private var handlers: [NottiNotificationEvent: ([String: Any]) -> Void] = [:]
  private var buffered: [BufferedEvent] = []
  private var deliveredKeys: Set<String> = []
  private var deliveredOrder: [String] = []

  init() {}

  /// Attaches (or clears) the emitter for one event kind and immediately
  /// replays whatever was buffered for it — except buffered clicks, which are
  /// held for `takeInitialClick()` (see the type doc).
  public func setHandler(_ event: NottiNotificationEvent, _ handler: (([String: Any]) -> Void)?) {
    guard let handler = handler else {
      lock.lock()
      handlers.removeValue(forKey: event)
      lock.unlock()
      return
    }

    lock.lock()
    handlers[event] = handler
    var replay: [BufferedEvent] = []
    if event != .clicked {
      replay = buffered.filter { $0.event == event }
      buffered.removeAll { $0.event == event }
      replay.forEach { markDeliveredLocked($0.key) }
    }
    lock.unlock()

    // Handlers run outside the lock: they hop into the RN bridge and must not
    // be able to deadlock a concurrent emit.
    replay.forEach { handler($0.payload) }
  }

  /// Emits `payload` to the attached handler, or buffers it when nothing is
  /// listening yet. `identifier` is the notification's stable id
  /// (`UNNotificationRequest.identifier`); pass nil only when there is none,
  /// in which case no dedupe is possible.
  public func emit(_ event: NottiNotificationEvent, identifier: String?, payload: [String: Any]) {
    let key = "\(event.rawValue):\(identifier ?? UUID().uuidString)"

    lock.lock()
    if deliveredKeys.contains(key) || buffered.contains(where: { $0.key == key }) {
      lock.unlock()
      return
    }

    guard let handler = handlers[event] else {
      if buffered.count >= Self.maxBufferedEvents {
        buffered.removeFirst()
      }
      buffered.append(BufferedEvent(event: event, key: key, payload: payload))
      lock.unlock()
      return
    }

    markDeliveredLocked(key)
    lock.unlock()
    handler(payload)
  }

  /// Hands the cold-start click to `getInitialNotificationClick()` and
  /// consumes it, so a second call with no new cold-start click returns nil.
  ///
  /// Returns the most recent buffered click and drops any older ones: the app
  /// was launched by a single tap, and there is no channel to deliver a stale
  /// one through. Consumed clicks are marked delivered, so the direct delegate
  /// path cannot emit the same notification again afterwards.
  public func takeInitialClick() -> [String: Any]? {
    lock.lock(); defer { lock.unlock() }
    let clicks = buffered.filter { $0.event == .clicked }
    guard let latest = clicks.last else { return nil }
    buffered.removeAll { $0.event == .clicked }
    clicks.forEach { markDeliveredLocked($0.key) }
    return latest.payload
  }

  /// Test hook: drops all handlers, buffered events and delivery history.
  public func reset() {
    lock.lock(); defer { lock.unlock() }
    handlers.removeAll()
    buffered.removeAll()
    deliveredKeys.removeAll()
    deliveredOrder.removeAll()
  }

  /// Caller must already hold `lock`.
  private func markDeliveredLocked(_ key: String) {
    guard deliveredKeys.insert(key).inserted else { return }
    deliveredOrder.append(key)
    if deliveredOrder.count > Self.maxRememberedDeliveries {
      deliveredKeys.remove(deliveredOrder.removeFirst())
    }
  }
}
