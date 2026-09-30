import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Orchestrates init, device registration, token refresh, permission
/// requests, and tag/external-id/subscription mutations (design.md
/// NottiCore). `NottiApiClient`/`NottiDeviceStore`/`NottiEventStore` are
/// constructor-injected so each can be faked in tests; `tokenProvider` and `permissionRequester`
/// abstract the platform-specific push-token fetch and OS permission prompt
/// (owned by the concrete wiring in T14/T15 — e.g. the real APNs
/// registration flow lives in whatever concrete `tokenProvider` is wired in,
/// not here). `tokenProvider` is callback-based rather than a plain
/// synchronous getter, since APNs delivers the device token asynchronously
/// via `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` —
/// there is no synchronous "get current token" API on iOS. Mirrors
/// `NottiCore.kt`'s contract exactly (design.md's Risks & Concerns
/// parallel-platform-test-matrix mitigation).
///
/// **Threading contract**: every public method returns immediately and does
/// its real work on `workQueue`, a private serial background queue.
/// `NottiApiClient` is blocking by design (semaphore-gated `URLSession`
/// call plus `Thread.sleep` retry backoff, up to 5x15s + backoff on a dead
/// network) and is therefore *only ever* invoked from `workQueue` — never
/// from the caller's thread, which on the APNs-delegate and permission-result
/// paths is the host app's main thread (a block there means a watchdog kill,
/// 0x8badf00d). `workQueue` being serial also gives the spec's P3-AC8
/// mutation serialization for free, and makes the registration tag write and
/// `mutateTags`' read-merge-write mutually exclusive (no lost tag update).
/// All mutable state below is read/written only on `workQueue`.
public class NottiCore {

  private let deviceStore: NottiDeviceStore
  private let eventStore: NottiEventStore
  private let apiClientFactory: (_ appId: String, _ clientKey: String, _ baseUrl: String) -> NottiApiClient
  private let tokenProvider: (_ callback: @escaping (String?) -> Void) -> Void
  private let permissionRequester: (_ callback: @escaping (Bool) -> Void) -> Void
  private let versionProvider: () -> String?
  private let platform: String
  private let logger: (String) -> Void

  private let workQueue = DispatchQueue(label: "app.notti.sdk.core", qos: .utility)
  private static let workQueueKey = DispatchSpecificKey<UInt8>()

  private var appId: String?
  private var clientKey: String?
  private var baseUrl: String?
  private var apiClient: NottiApiClient?

  /// Mutations issued before device registration finished, replayed in order
  /// once it does. Bounded so a never-registering device cannot grow it
  /// without limit.
  private struct PendingMutation {
    let description: String
    let work: (_ client: NottiApiClient, _ deviceId: String, _ token: String) -> Void
  }
  private static let maxPendingMutations = 32
  private var pendingMutations: [PendingMutation] = []

  /// Outcome of the last registration attempt (workQueue-only). Drives the
  /// app-foreground retry: the retry schedule stops after 5 attempts, and
  /// spec P1-AC5 requires it to resume on the next foreground.
  private enum RegistrationState {
    case notAttempted
    case succeeded
    case failed
  }
  private var registrationState: RegistrationState = .notAttempted
  private var lastAttemptedToken: String?

  /// Notified whenever the persisted device id actually changes (first
  /// assignment, reinstall, or a re-registration that lands a different id) -
  /// never on an idempotent re-register that returns the same id already
  /// cached. Constructor-injected (not a settable var): a settable property
  /// set post-construction from Obj-C++ left a real window where
  /// `NottiPushDelegate`/`NottiBridge` could reach a published `NottiCore`
  /// through `NottiImpl.activeCore` before the handler was wired, silently
  /// dropping the first-assignment event and racing the property's own
  /// unsynchronized read/write across threads. `NottiImpl` now defers
  /// publishing itself (`activate()`) until after the handler exists (see
  /// ADR-001, docs/adr/001-expose-device-id-getter-and-change-event.md).
  /// Always invoked on `workQueue`.
  private let onDeviceIdChanged: (String) -> Void

  /// Guards against a foreground-retry storm: `didBecomeActive` can fire
  /// repeatedly (app switcher, control centre, alerts), and only one retry may
  /// be queued at a time. Touched from the notification thread, so it needs
  /// its own lock rather than the work queue.
  private let foregroundLock = NSLock()
  private var foregroundRetryQueued = false
  private var foregroundObserver: NSObjectProtocol?
  private var backgroundObserver: NSObjectProtocol?

  /// Session-transition state (workQueue-only, T8). iOS fires
  /// `didBecomeActive` repeatedly without an intervening `didEnterBackground`
  /// (app switcher peek, control centre, alert), so "becomes active" is not
  /// itself "a new foreground session". `appIsInBackground` + `hasStartedSession`
  /// distinguish a real background→foreground (or cold-start) transition — the
  /// only ones that start a session — from a repeat activation that must not
  /// falsely end+restart the current session (spec edge case: no inflated
  /// `session_count` from non-interactive wake-ups).
  private var appIsInBackground = false
  private var hasStartedSession = false

  public init(
    deviceStore: NottiDeviceStore,
    eventStore: NottiEventStore,
    apiClientFactory: @escaping (_ appId: String, _ clientKey: String, _ baseUrl: String) -> NottiApiClient,
    tokenProvider: @escaping (_ callback: @escaping (String?) -> Void) -> Void,
    permissionRequester: @escaping (_ callback: @escaping (Bool) -> Void) -> Void,
    versionProvider: @escaping () -> String? = { nil },
    platform: String = "ios",
    logger: @escaping (String) -> Void = { _ in },
    onDeviceIdChanged: @escaping (String) -> Void = { _ in }
  ) {
    self.deviceStore = deviceStore
    self.eventStore = eventStore
    self.apiClientFactory = apiClientFactory
    self.tokenProvider = tokenProvider
    self.permissionRequester = permissionRequester
    self.versionProvider = versionProvider
    self.platform = platform
    self.logger = logger
    self.onDeviceIdChanged = onDeviceIdChanged
    workQueue.setSpecific(key: Self.workQueueKey, value: 1)
    observeAppForeground()
    observeAppBackground()
  }

  deinit {
    if let observer = foregroundObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = backgroundObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Runs `block` on `workQueue`, executing it inline when the caller is
  /// already on that queue. Needed because `tokenProvider`/
  /// `permissionRequester` may invoke their callback synchronously (from the
  /// work queue itself) or asynchronously on an arbitrary thread, and the
  /// synchronous case must keep running as part of the *current* work item
  /// rather than being re-enqueued behind whatever landed in the meantime.
  private func onWorkQueue(_ block: @escaping () -> Void) {
    if DispatchQueue.getSpecific(key: Self.workQueueKey) != nil {
      block()
    } else {
      workQueue.async(execute: block)
    }
  }

  public func initialize(appId: String, clientKey: String, baseUrl: String) {
    workQueue.async { [weak self] in
      self?.initializeOnQueue(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    }
  }

  public func onTokenRefreshed(_ newToken: String) {
    workQueue.async { [weak self] in
      guard let self = self, let client = self.apiClient else { return }
      self.registerDevice(client, newToken)
    }
  }

  public func requestPermission(_ callback: @escaping (Bool) -> Void) {
    workQueue.async { [weak self] in
      guard let self = self else { return }
      guard let client = self.apiClient else {
        self.logger("Notti.requestPermission: called before initialize - not prompting")
        callback(false)
        return
      }

      self.permissionRequester { granted in
        // The OS prompt result can arrive on any thread; hop back onto the
        // work queue so the PATCH below never runs on the caller's (main)
        // thread. The callback fires first so the JS Promise resolves as
        // soon as the user answered, instead of waiting out a possibly
        // minutes-long retry cycle on a dead network.
        //
        // A4 (found in pre-release review): that Promise reports the OS
        // *dialog* result, not whether the backend actually persisted it - a
        // failed PATCH here used to fail completely silently, with nothing
        // logged and no reconciliation path (the foreground retry only
        // covers registration, never mutations). Changing the Promise to
        // depend on the PATCH outcome would be a breaking API change;
        // logging the failure is the fix that fits this pass without that
        // risk.
        self.onWorkQueue {
          callback(granted)
          self.performOrQueue(client, description: "permission-result subscription update") { [weak self] client, deviceId, token in
            self?.patchSubscribed(client, deviceId: deviceId, token: token, granted, logContext: "requestPermission")
          }
        }
      }
    }
  }

  public func login(_ externalUserId: String) {
    workQueue.async { [weak self] in
      guard let self = self, let client = self.apiClient else { return }
      self.performOrQueue(client, description: "login") { [weak self] client, deviceId, token in
        let result = client.patchDevice(
          deviceId: deviceId,
          token: token,
          fields: ["external_user_id": externalUserId]
        )
        switch result {
        case .success:
          self?.deviceStore.setExternalUserId(externalUserId)
        case .failure(let message):
          self?.logger("Notti.login: PATCH failed (\(message)) - not retried")
        }
      }
    }
  }

  /// The backend does not support clearing `external_user_id` server-side
  /// (spec Edge Case) - only the SDK's locally-held association is cleared.
  public func logout() {
    workQueue.async { [weak self] in
      self?.deviceStore.setExternalUserId(nil)
    }
  }

  public func setSubscription(_ enabled: Bool) {
    workQueue.async { [weak self] in
      guard let self = self, let client = self.apiClient else { return }
      self.performOrQueue(client, description: "setSubscription") { [weak self] client, deviceId, token in
        self?.patchSubscribed(client, deviceId: deviceId, token: token, enabled, logContext: "setSubscription")
      }
    }
  }

  /// Cached device id, or `nil` if registration hasn't assigned one yet.
  public func getDeviceId() -> String? {
    deviceStore.getDeviceId()
  }

  public func mutateTags(add: [String: String]?, remove: [String]?) {
    workQueue.async { [weak self] in
      guard let self = self, let client = self.apiClient else { return }
      self.performOrQueue(client, description: "tag mutation") { [weak self] client, deviceId, token in
        guard let self = self else { return }
        // The merge deliberately reads the tag cache at *send* time, not at
        // call time: a mutation queued before registration must merge onto
        // whatever tags the registration response seeded.
        let merged = NottiDeviceStore.mergeTags(self.deviceStore.getTags(), add: add, remove: remove)
        let result = client.patchDevice(deviceId: deviceId, token: token, fields: ["tags": merged])
        switch result {
        case .success(let response):
          self.deviceStore.setTags(response.tags)
        case .failure(let message):
          self.logger("Notti.mutateTags: PATCH failed (\(message)) - not retried")
        }
      }
    }
  }

  /// Blocks the calling thread until every mutation already enqueued on
  /// `workQueue` has run, or `timeout` elapses (returns `false` on timeout).
  /// Test/diagnostic hook only — the SDK itself never calls it, and it is
  /// not reachable from the JS API surface.
  @discardableResult
  public func waitForPendingWork(timeout: TimeInterval = 5) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    workQueue.async { semaphore.signal() }
    return semaphore.wait(timeout: .now() + timeout) == .success
  }

  /// Flush trigger for the network observer and the push delegate's
  /// opportunistic post-enqueue flush (T8): hops onto `workQueue` and drains
  /// the offline event queue. A no-op when the device is not registered yet —
  /// `flushEventQueue` guards on `apiClient`/token — and the event stays queued
  /// for the next registration success or app foreground.
  internal func onNetworkAvailable() {
    workQueue.async { [weak self] in
      self?.flushEventQueue()
    }
  }

  // MARK: - workQueue-only internals

  private func initializeOnQueue(appId: String, clientKey: String, baseUrl: String) {
    if appId.isEmpty || clientKey.isEmpty || baseUrl.isEmpty {
      logger("Notti.initialize: appId, clientKey, or baseUrl is missing/empty - skipping registration")
      return
    }

    // A malformed-but-non-empty baseUrl (e.g. "my host.example.com", or a
    // scheme-less host) must leave the SDK disabled, not crash the host app
    // (SDK-03). Validated once here so nothing downstream ever has to
    // force-unwrap integrator-supplied config.
    guard let validatedBaseUrl = NottiApiClient.validatedBaseUrl(baseUrl) else {
      logger(
        "Notti.initialize: baseUrl is not a valid absolute http(s) URL - "
          + "skipping registration (SDK stays disabled)"
      )
      return
    }

    // Repeat call with identical args in the same session: no-op (SDK-07).
    if appId == self.appId && clientKey == self.clientKey && validatedBaseUrl == self.baseUrl {
      return
    }

    self.appId = appId
    self.clientKey = clientKey
    self.baseUrl = validatedBaseUrl
    let client = apiClientFactory(appId, clientKey, validatedBaseUrl)
    self.apiClient = client

    tokenProvider { [weak self] token in
      guard let self = self else { return }
      // The APNs token arrives asynchronously on an arbitrary thread.
      self.onWorkQueue {
        guard let token = token else {
          self.logger("Notti.initialize: no push token available - skipping registration")
          return
        }
        self.registerDevice(client, token)
      }
    }
  }

  private func registerDevice(_ client: NottiApiClient, _ token: String) {
    lastAttemptedToken = token
    switch client.createOrUpdateDevice(token: token, platform: platform) {
    case .success(let response):
      registrationState = .succeeded
      let previousDeviceId = deviceStore.getDeviceId()
      deviceStore.setDeviceId(response.id)
      if response.id != previousDeviceId {
        onDeviceIdChanged(response.id)
      }
      deviceStore.setLastToken(token)
      deviceStore.setTags(response.tags)
      flushPendingMutations(client, deviceId: response.id, token: token)
      syncAppVersionIfNeeded(client)
      flushEventQueue()
    case .failure(let message):
      registrationState = .failed
      logger("Notti.initialize: device registration failed: \(message)")
    }
  }

  // MARK: - Foreground retry (spec P1-AC5)

  /// workQueue-only. Diff-and-enqueue (SEGTEL-03): reads the current app
  /// version via the injected `versionProvider`, and only when it differs
  /// from the last value successfully synced does it enqueue a PATCH through
  /// the mutation queue, persisting the new value on Success. A nil read
  /// (no `CFBundleShortVersionString` in the host bundle) skips entirely —
  /// no crash, no registration block (SEGTEL edge case).
  private func syncAppVersionIfNeeded(_ client: NottiApiClient) {
    guard let current = versionProvider() else { return }
    guard current != deviceStore.getAppVersion() else { return }
    performOrQueue(client, description: "app version") { [weak self] client, deviceId, token in
      let result = client.patchDevice(deviceId: deviceId, token: token, fields: ["app_version": current])
      switch result {
      case .success:
        self?.deviceStore.setAppVersion(current)
      case .failure(let message):
        self?.logger("Notti.syncAppVersionIfNeeded: PATCH failed (\(message)) - not retried")
      }
    }
  }

  /// Subscribes to `UIApplication.didBecomeActiveNotification` directly - a
  /// plain system notification, so no host-`AppDelegate` forwarding is needed
  /// (unlike the APNs callbacks). Without this, a registration that exhausted
  /// its 5 attempts never retried until the app was relaunched.
  private func observeAppForeground() {
    #if canImport(UIKit)
      foregroundObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.handleAppDidBecomeActive()
      }
    #endif
  }

  /// The T8 session-end hook: mirrors `observeAppForeground` on
  /// `UIApplication.didEnterBackgroundNotification` (also plain system
  /// notifications, zero AppDelegate forwarding). Removed in `deinit` like the
  /// foreground observer.
  private func observeAppBackground() {
    #if canImport(UIKit)
      backgroundObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.handleAppDidEnterBackground()
      }
    #endif
  }

  private func handleAppDidBecomeActive() {
    foregroundLock.lock()
    if foregroundRetryQueued {
      foregroundLock.unlock()
      return
    }
    foregroundRetryQueued = true
    foregroundLock.unlock()

    workQueue.async { [weak self] in
      guard let self = self else { return }
      self.foregroundLock.lock()
      self.foregroundRetryQueued = false
      self.foregroundLock.unlock()
      // Session start first (SEGTEL-05): a repeat `didBecomeActive` without an
      // intervening background must not close+reopen the current session, so
      // only a real transition (or the cold-start launch) reaches
      // `handleSessionStartOnQueue`.
      if self.appIsInBackground || !self.hasStartedSession {
        self.hasStartedSession = true
        self.appIsInBackground = false
        self.handleSessionStartOnQueue(nowMs: self.nowMs())
      }
      // Unconditional: a device that is already registered skips the retry
      // below but must still get its offline event queue flushed.
      self.flushEventQueue()
      self.retryRegistrationIfNeeded()
    }
  }

  /// workQueue-only. Session end on the `didEnterBackgroundNotification` path.
  private func handleAppDidEnterBackground() {
    workQueue.async { [weak self] in
      guard let self = self else { return }
      self.appIsInBackground = true
      self.handleSessionEndOnQueue(nowMs: self.nowMs())
    }
  }

  /// workQueue-only. Runs after any in-flight registration has finished (the
  /// queue is serial), so `registrationState` is already final here.
  private func retryRegistrationIfNeeded() {
    guard let client = apiClient else { return }
    guard registrationState != .succeeded else { return }

    logger("Notti: app foregrounded without a successful registration - retrying")

    if let token = lastAttemptedToken {
      registerDevice(client, token)
      return
    }

    // No token has been seen *this session*. The persisted `lastToken` is
    // deliberately not used as a stand-in: APNs tokens rotate (backup restore,
    // reinstall), so on a relaunch where the token simply has not been
    // delivered yet, registering with the previous session's token would both
    // bind the backend to a dead token and cause a second, duplicate
    // registration moments later when the real token does arrive. Ask the
    // platform instead (on iOS this re-triggers registerForRemoteNotifications
    // and the callback fires only once the real token is in hand) — the same
    // mechanism `initialize` uses.
    tokenProvider { [weak self] token in
      guard let self = self else { return }
      self.onWorkQueue {
        guard let token = token else {
          self.logger("Notti: foreground retry found no push token available")
          return
        }
        self.registerDevice(client, token)
      }
    }
  }

  // MARK: - Session lifecycle (T8, SEGTEL-05..09)

  /// Starts (or, on an unclean kill, first closes then re-opens) the current
  /// session. Public entry point for the lifecycle hooks; hops onto
  /// `workQueue`, where `handleSessionStartOnQueue` does the real work.
  internal func handleSessionStart(nowMs: Int64) {
    workQueue.async { [weak self] in
      self?.handleSessionStartOnQueue(nowMs: nowMs)
    }
  }

  /// Ends the current session (aggregate + snapshot PATCH). Public entry point
  /// for the background hook; hops onto `workQueue`, where
  /// `handleSessionEndOnQueue` does the real work.
  internal func handleSessionEnd(nowMs: Int64) {
    workQueue.async { [weak self] in
      self?.handleSessionEndOnQueue(nowMs: nowMs)
    }
  }

  /// workQueue-only. Session-start bookkeeping:
  /// 1. A stale `sessionStartedAtMs` means the previous process was killed
  ///    while foreground (no clean background transition) — close the missed
  ///    session with an estimate (SEGTEL-08) before opening the new one.
  /// 2. `firstSessionAtMs` is set once, never overwritten (SEGTEL-05 AC1).
  /// 3. Open the new session at `nowMs`.
  private func handleSessionStartOnQueue(nowMs: Int64) {
    if deviceStore.getSessionStartedAtMs() != nil {
      handleSessionEndOnQueue(nowMs: nowMs)
    }
    if deviceStore.getFirstSessionAtMs() == nil {
      deviceStore.setFirstSessionAtMs(nowMs)
    }
    deviceStore.setSessionStartedAtMs(nowMs)
  }

  /// workQueue-only. Session-end bookkeeping:
  /// 1. No active session → no-op (also excludes widget/extension/background-
  ///    fetch invocations, which never set `sessionStartedAtMs`).
  /// 2. Otherwise increment the aggregate, persist it (survives kill), and
  ///    enqueue a session PATCH whose fields are a **snapshot captured at
  ///    enqueue time** — a new session starting mid-flush must not be
  ///    double-counted (SEGTEL-07 AC3, same capture-at-enqueue shape as
  ///    `mutateTags`).
  private func handleSessionEndOnQueue(nowMs: Int64) {
    guard let startedAt = deviceStore.getSessionStartedAtMs() else { return }
    let sessionCount = deviceStore.getSessionCount() + 1
    let sessionTimeMs = deviceStore.getSessionTimeMs() + (nowMs - startedAt)
    deviceStore.setSessionCount(sessionCount)
    deviceStore.setSessionTimeMs(sessionTimeMs)
    deviceStore.setLastSessionAtMs(nowMs)
    deviceStore.setSessionStartedAtMs(nil)

    var snapshot: [String: Any] = [:]
    if let firstSessionAt = deviceStore.getFirstSessionAtMs() {
      snapshot["first_session_at"] = Self.formatIsoUtc(firstSessionAt)
    }
    snapshot["last_session_at"] = Self.formatIsoUtc(nowMs)
    snapshot["session_count"] = sessionCount
    snapshot["session_time_seconds"] = sessionTimeMs / 1000

    guard let client = apiClient else { return }
    performOrQueue(client, description: "session telemetry") { client, deviceId, token in
      _ = client.patchDevice(deviceId: deviceId, token: token, fields: snapshot)
    }
  }

  private func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }

  /// ISO-8601 UTC with millisecond precision — the same
  /// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` shape Android's `formatIsoUtc` produces,
  /// so the backend's Go RFC3339 parse accepts both platforms.
  private static func formatIsoUtc(_ epochMs: Int64) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000))
  }

  /// Runs `work` right away when the device already has an id + token, or
  /// parks it in `pendingMutations` when registration has not completed yet.
  /// Registration is inherently async on iOS (the APNs token only arrives via
  /// `didRegisterForRemoteNotificationsWithDeviceToken`), so `login`/
  /// `addTags`/`requestPermission` called right after `initialize()` would
  /// otherwise be silently and permanently dropped.
  private func performOrQueue(
    _ client: NottiApiClient,
    description: String,
    _ work: @escaping (_ client: NottiApiClient, _ deviceId: String, _ token: String) -> Void
  ) {
    guard let deviceId = deviceStore.getDeviceId(), let token = deviceStore.getLastToken() else {
      if pendingMutations.count >= Self.maxPendingMutations {
        let dropped = pendingMutations.removeFirst()
        logger("Notti: pending-mutation queue full - dropping the oldest queued mutation (\(dropped.description))")
      }
      pendingMutations.append(PendingMutation(description: description, work: work))
      logger("Notti: device not registered yet - queued \(description) until registration completes")
      return
    }
    work(client, deviceId, token)
  }

  /// Flushes, in call order, every mutation issued before registration
  /// completed. In-memory only: anything still queued when the process dies
  /// is dropped rather than replayed with stale state (spec Edge Case).
  private func flushPendingMutations(_ client: NottiApiClient, deviceId: String, token: String) {
    guard !pendingMutations.isEmpty else { return }
    let queued = pendingMutations
    pendingMutations.removeAll()
    logger("Notti: registration complete - flushing \(queued.count) queued mutation(s)")
    for mutation in queued {
      mutation.work(client, deviceId, token)
    }
  }

  /// workQueue-only. Drains the offline event queue (`NottiEventStore`),
  /// reporting each pending event to the backend and removing it once the
  /// backend has acknowledged it. Write-ahead persistence: the event is
  /// persisted before any report attempt, so a crash mid-flush never loses a
  /// queued event - at worst it is re-reported, which the backend treats as
  /// idempotent. A no-op until the device is registered with a push token:
  /// there is nothing to report against, and `reportEvent` needs the token to
  /// prove the event belongs to the receiving device.
  ///
  /// On a terminal `.failure` (`terminal == true`, a 4xx the backend will
  /// never accept - e.g. a stale token 403 per spec SDKCTR-11) the event is
  /// removed too: re-attempting it on every future flush would fail
  /// identically forever. On a transient `.failure` (`terminal == false`,
  /// retry cap exhausted on network/5xx) the event STAYS queued and the next
  /// registration success, app foreground, or network regain tries again.
  /// Mirrors `NottiCore.kt`'s `flushEventQueue` exactly.
  private func flushEventQueue() {
    guard let client = apiClient, let token = deviceStore.getLastToken() else { return }
    for event in eventStore.all() {
      switch client.reportEvent(
        notificationId: event.notificationId,
        deliveryId: event.deliveryId,
        type: event.type,
        token: token
      ) {
      case .success:
        eventStore.remove(id: event.id)
      case .failure(let message, let terminal):
        if terminal {
          logger("Notti.flushEventQueue: event report terminally failed (\(message)) - event dropped")
          eventStore.remove(id: event.id)
        } else {
          logger("Notti.flushEventQueue: event report failed (\(message)) - event stays queued")
        }
      }
    }
  }

  private func patchSubscribed(
    _ client: NottiApiClient,
    deviceId: String,
    token: String,
    _ subscribed: Bool,
    logContext: String
  ) {
    let result = client.patchDevice(deviceId: deviceId, token: token, fields: ["subscribed": subscribed])
    switch result {
    case .success:
      deviceStore.setSubscribed(subscribed)
    case .failure(let message):
      logger("Notti.\(logContext): PATCH failed (\(message)) - not retried")
    }
  }
}
