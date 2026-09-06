import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Orchestrates init, device registration, token refresh, permission
/// requests, and tag/external-id/subscription mutations (design.md
/// NuntisCore). `NuntisApiClient`/`NuntisDeviceStore` are constructor-injected
/// so both can be faked in tests; `tokenProvider` and `permissionRequester`
/// abstract the platform-specific push-token fetch and OS permission prompt
/// (owned by the concrete wiring in T14/T15 — e.g. the real APNs
/// registration flow lives in whatever concrete `tokenProvider` is wired in,
/// not here). `tokenProvider` is callback-based rather than a plain
/// synchronous getter, since APNs delivers the device token asynchronously
/// via `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` —
/// there is no synchronous "get current token" API on iOS. Mirrors
/// `NuntisCore.kt`'s contract exactly (design.md's Risks & Concerns
/// parallel-platform-test-matrix mitigation).
///
/// **Threading contract**: every public method returns immediately and does
/// its real work on `workQueue`, a private serial background queue.
/// `NuntisApiClient` is blocking by design (semaphore-gated `URLSession`
/// call plus `Thread.sleep` retry backoff, up to 5x15s + backoff on a dead
/// network) and is therefore *only ever* invoked from `workQueue` — never
/// from the caller's thread, which on the APNs-delegate and permission-result
/// paths is the host app's main thread (a block there means a watchdog kill,
/// 0x8badf00d). `workQueue` being serial also gives the spec's P3-AC8
/// mutation serialization for free, and makes the registration tag write and
/// `mutateTags`' read-merge-write mutually exclusive (no lost tag update).
/// All mutable state below is read/written only on `workQueue`.
public class NuntisCore {

  private let deviceStore: NuntisDeviceStore
  private let apiClientFactory: (_ appId: String, _ clientKey: String, _ baseUrl: String) -> NuntisApiClient
  private let tokenProvider: (_ callback: @escaping (String?) -> Void) -> Void
  private let permissionRequester: (_ callback: @escaping (Bool) -> Void) -> Void
  private let platform: String
  private let logger: (String) -> Void

  private let workQueue = DispatchQueue(label: "app.nuntis.sdk.core", qos: .utility)
  private static let workQueueKey = DispatchSpecificKey<UInt8>()

  private var appId: String?
  private var clientKey: String?
  private var baseUrl: String?
  private var apiClient: NuntisApiClient?

  /// Mutations issued before device registration finished, replayed in order
  /// once it does. Bounded so a never-registering device cannot grow it
  /// without limit.
  private struct PendingMutation {
    let description: String
    let work: (_ client: NuntisApiClient, _ deviceId: String, _ token: String) -> Void
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

  /// Guards against a foreground-retry storm: `didBecomeActive` can fire
  /// repeatedly (app switcher, control centre, alerts), and only one retry may
  /// be queued at a time. Touched from the notification thread, so it needs
  /// its own lock rather than the work queue.
  private let foregroundLock = NSLock()
  private var foregroundRetryQueued = false
  private var foregroundObserver: NSObjectProtocol?

  public init(
    deviceStore: NuntisDeviceStore,
    apiClientFactory: @escaping (_ appId: String, _ clientKey: String, _ baseUrl: String) -> NuntisApiClient,
    tokenProvider: @escaping (_ callback: @escaping (String?) -> Void) -> Void,
    permissionRequester: @escaping (_ callback: @escaping (Bool) -> Void) -> Void,
    platform: String = "ios",
    logger: @escaping (String) -> Void = { _ in }
  ) {
    self.deviceStore = deviceStore
    self.apiClientFactory = apiClientFactory
    self.tokenProvider = tokenProvider
    self.permissionRequester = permissionRequester
    self.platform = platform
    self.logger = logger
    workQueue.setSpecific(key: Self.workQueueKey, value: 1)
    observeAppForeground()
  }

  deinit {
    if let observer = foregroundObserver {
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
        self.logger("Nuntis.requestPermission: called before initialize - not prompting")
        callback(false)
        return
      }

      self.permissionRequester { granted in
        // The OS prompt result can arrive on any thread; hop back onto the
        // work queue so the PATCH below never runs on the caller's (main)
        // thread. The callback fires first so the JS Promise resolves as
        // soon as the user answered, instead of waiting out a possibly
        // minutes-long retry cycle on a dead network.
        self.onWorkQueue {
          callback(granted)
          self.performOrQueue(client, description: "permission-result subscription update") { [weak self] client, deviceId, token in
            self?.patchSubscribed(client, deviceId: deviceId, token: token, granted)
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
        if case .success = result { self?.deviceStore.setExternalUserId(externalUserId) }
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
        self?.patchSubscribed(client, deviceId: deviceId, token: token, enabled)
      }
    }
  }

  public func mutateTags(add: [String: String]?, remove: [String]?) {
    workQueue.async { [weak self] in
      guard let self = self, let client = self.apiClient else { return }
      self.performOrQueue(client, description: "tag mutation") { [weak self] client, deviceId, token in
        guard let self = self else { return }
        // The merge deliberately reads the tag cache at *send* time, not at
        // call time: a mutation queued before registration must merge onto
        // whatever tags the registration response seeded.
        let merged = NuntisDeviceStore.mergeTags(self.deviceStore.getTags(), add: add, remove: remove)
        let result = client.patchDevice(deviceId: deviceId, token: token, fields: ["tags": merged])
        if case .success(let response) = result {
          self.deviceStore.setTags(response.tags)
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

  // MARK: - workQueue-only internals

  private func initializeOnQueue(appId: String, clientKey: String, baseUrl: String) {
    if appId.isEmpty || clientKey.isEmpty || baseUrl.isEmpty {
      logger("Nuntis.initialize: appId, clientKey, or baseUrl is missing/empty - skipping registration")
      return
    }

    // A malformed-but-non-empty baseUrl (e.g. "my host.example.com", or a
    // scheme-less host) must leave the SDK disabled, not crash the host app
    // (SDK-03). Validated once here so nothing downstream ever has to
    // force-unwrap integrator-supplied config.
    guard let validatedBaseUrl = NuntisApiClient.validatedBaseUrl(baseUrl) else {
      logger(
        "Nuntis.initialize: baseUrl is not a valid absolute http(s) URL - "
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
          self.logger("Nuntis.initialize: no push token available - skipping registration")
          return
        }
        self.registerDevice(client, token)
      }
    }
  }

  private func registerDevice(_ client: NuntisApiClient, _ token: String) {
    lastAttemptedToken = token
    switch client.createOrUpdateDevice(token: token, platform: platform) {
    case .success(let response):
      registrationState = .succeeded
      deviceStore.setDeviceId(response.id)
      deviceStore.setLastToken(token)
      deviceStore.setTags(response.tags)
      flushPendingMutations(client, deviceId: response.id, token: token)
    case .failure(let message):
      registrationState = .failed
      logger("Nuntis.initialize: device registration failed: \(message)")
    }
  }

  // MARK: - Foreground retry (spec P1-AC5)

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
      self.retryRegistrationIfNeeded()
    }
  }

  /// workQueue-only. Runs after any in-flight registration has finished (the
  /// queue is serial), so `registrationState` is already final here.
  private func retryRegistrationIfNeeded() {
    guard let client = apiClient else { return }
    guard registrationState != .succeeded else { return }

    logger("Nuntis: app foregrounded without a successful registration - retrying")

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
          self.logger("Nuntis: foreground retry found no push token available")
          return
        }
        self.registerDevice(client, token)
      }
    }
  }

  /// Runs `work` right away when the device already has an id + token, or
  /// parks it in `pendingMutations` when registration has not completed yet.
  /// Registration is inherently async on iOS (the APNs token only arrives via
  /// `didRegisterForRemoteNotificationsWithDeviceToken`), so `login`/
  /// `addTags`/`requestPermission` called right after `initialize()` would
  /// otherwise be silently and permanently dropped.
  private func performOrQueue(
    _ client: NuntisApiClient,
    description: String,
    _ work: @escaping (_ client: NuntisApiClient, _ deviceId: String, _ token: String) -> Void
  ) {
    guard let deviceId = deviceStore.getDeviceId(), let token = deviceStore.getLastToken() else {
      if pendingMutations.count >= Self.maxPendingMutations {
        let dropped = pendingMutations.removeFirst()
        logger("Nuntis: pending-mutation queue full - dropping the oldest queued mutation (\(dropped.description))")
      }
      pendingMutations.append(PendingMutation(description: description, work: work))
      logger("Nuntis: device not registered yet - queued \(description) until registration completes")
      return
    }
    work(client, deviceId, token)
  }

  /// Flushes, in call order, every mutation issued before registration
  /// completed. In-memory only: anything still queued when the process dies
  /// is dropped rather than replayed with stale state (spec Edge Case).
  private func flushPendingMutations(_ client: NuntisApiClient, deviceId: String, token: String) {
    guard !pendingMutations.isEmpty else { return }
    let queued = pendingMutations
    pendingMutations.removeAll()
    logger("Nuntis: registration complete - flushing \(queued.count) queued mutation(s)")
    for mutation in queued {
      mutation.work(client, deviceId, token)
    }
  }

  private func patchSubscribed(
    _ client: NuntisApiClient,
    deviceId: String,
    token: String,
    _ subscribed: Bool
  ) {
    let result = client.patchDevice(deviceId: deviceId, token: token, fields: ["subscribed": subscribed])
    if case .success = result { deviceStore.setSubscribed(subscribed) }
  }
}
