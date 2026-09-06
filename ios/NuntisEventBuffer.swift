import Foundation

public enum NuntisNotificationEvent: String {
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
/// Events emitted with no handler attached are buffered here and replayed, in
/// order, the moment the TurboModule wires its emitter up (`NuntisImpl`'s
/// `emitReceivedHandler`/`emitClickedHandler` setters). Delivery is deduped by
/// the notification's stable identifier, so a payload that also reaches the
/// direct delegate path is never delivered twice.
public final class NuntisEventBuffer {

  public static let shared = NuntisEventBuffer()

  /// Enough to cover a cold start; a stuck bridge cannot grow this unbounded.
  private static let maxBufferedEvents = 10
  private static let maxRememberedDeliveries = 50

  private struct BufferedEvent {
    let event: NuntisNotificationEvent
    let key: String
    let payload: [String: Any]
  }

  private let lock = NSLock()
  private var handlers: [NuntisNotificationEvent: ([String: Any]) -> Void] = [:]
  private var buffered: [BufferedEvent] = []
  private var deliveredKeys: Set<String> = []
  private var deliveredOrder: [String] = []

  init() {}

  /// Attaches (or clears) the emitter for one event kind and immediately
  /// replays whatever was buffered for it.
  public func setHandler(_ event: NuntisNotificationEvent, _ handler: (([String: Any]) -> Void)?) {
    guard let handler = handler else {
      lock.lock()
      handlers.removeValue(forKey: event)
      lock.unlock()
      return
    }

    lock.lock()
    handlers[event] = handler
    let replay = buffered.filter { $0.event == event }
    buffered.removeAll { $0.event == event }
    replay.forEach { markDeliveredLocked($0.key) }
    lock.unlock()

    // Handlers run outside the lock: they hop into the RN bridge and must not
    // be able to deadlock a concurrent emit.
    replay.forEach { handler($0.payload) }
  }

  /// Emits `payload` to the attached handler, or buffers it when nothing is
  /// listening yet. `identifier` is the notification's stable id
  /// (`UNNotificationRequest.identifier`); pass nil only when there is none,
  /// in which case no dedupe is possible.
  public func emit(_ event: NuntisNotificationEvent, identifier: String?, payload: [String: Any]) {
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
