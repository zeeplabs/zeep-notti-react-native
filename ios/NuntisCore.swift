import Foundation

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
/// call plus `Thread.sleep` retry backoff, up to ~5x65s + backoff on a dead
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
          if let result = self.patchIfRegistered(client, ["subscribed": granted]) {
            if case .success = result { self.deviceStore.setSubscribed(granted) }
          }
        }
      }
    }
  }

  public func login(_ externalUserId: String) {
    workQueue.async { [weak self] in
      guard let self = self, let client = self.apiClient else { return }
      if let result = self.patchIfRegistered(client, ["external_user_id": externalUserId]) {
        if case .success = result { self.deviceStore.setExternalUserId(externalUserId) }
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
      if let result = self.patchIfRegistered(client, ["subscribed": enabled]) {
        if case .success = result { self.deviceStore.setSubscribed(enabled) }
      }
    }
  }

  public func mutateTags(add: [String: String]?, remove: [String]?) {
    workQueue.async { [weak self] in
      guard let self = self, let client = self.apiClient else { return }
      guard let deviceId = self.deviceStore.getDeviceId(), let token = self.deviceStore.getLastToken() else { return }

      let merged = NuntisDeviceStore.mergeTags(self.deviceStore.getTags(), add: add, remove: remove)
      if case .success(let response) = client.patchDevice(deviceId: deviceId, token: token, fields: ["tags": merged]) {
        self.deviceStore.setTags(response.tags)
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

    // Repeat call with identical args in the same session: no-op (SDK-07).
    if appId == self.appId && clientKey == self.clientKey && baseUrl == self.baseUrl {
      return
    }

    self.appId = appId
    self.clientKey = clientKey
    self.baseUrl = baseUrl
    let client = apiClientFactory(appId, clientKey, baseUrl)
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
    switch client.createOrUpdateDevice(token: token, platform: platform) {
    case .success(let response):
      deviceStore.setDeviceId(response.id)
      deviceStore.setLastToken(token)
      deviceStore.setTags(response.tags)
    case .failure(let message):
      logger("Nuntis.initialize: device registration failed: \(message)")
    }
  }

  private func patchIfRegistered(_ client: NuntisApiClient, _ fields: [String: Any]) -> ApiResult? {
    guard let deviceId = deviceStore.getDeviceId(), let token = deviceStore.getLastToken() else { return nil }
    return client.patchDevice(deviceId: deviceId, token: token, fields: fields)
  }
}
