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
public class NuntisCore {

  private let deviceStore: NuntisDeviceStore
  private let apiClientFactory: (_ appId: String, _ clientKey: String, _ baseUrl: String) -> NuntisApiClient
  private let tokenProvider: (_ callback: @escaping (String?) -> Void) -> Void
  private let permissionRequester: (_ callback: @escaping (Bool) -> Void) -> Void
  private let platform: String
  private let logger: (String) -> Void

  private var appId: String?
  private var clientKey: String?
  private var baseUrl: String?
  private var apiClient: NuntisApiClient?
  private let mutationLock = NSLock()

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
  }

  public func initialize(appId: String, clientKey: String, baseUrl: String) {
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
      guard let token = token else {
        self.logger("Nuntis.initialize: no push token available - skipping registration")
        return
      }
      self.registerDevice(client, token)
    }
  }

  public func onTokenRefreshed(_ newToken: String) {
    guard let client = apiClient else { return }
    registerDevice(client, newToken)
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

  public func requestPermission(_ callback: @escaping (Bool) -> Void) {
    guard let client = apiClient else {
      logger("Nuntis.requestPermission: called before initialize - not prompting")
      callback(false)
      return
    }

    permissionRequester { [weak self] granted in
      guard let self = self else { return }
      if let result = self.patchIfRegistered(client, { ["subscribed": granted] }) {
        if case .success = result { self.deviceStore.setSubscribed(granted) }
      }
      callback(granted)
    }
  }

  public func login(_ externalUserId: String) {
    guard let client = apiClient else { return }
    if let result = patchIfRegistered(client, { ["external_user_id": externalUserId] }) {
      if case .success = result { deviceStore.setExternalUserId(externalUserId) }
    }
  }

  /// The backend does not support clearing `external_user_id` server-side
  /// (spec Edge Case) - only the SDK's locally-held association is cleared.
  public func logout() {
    deviceStore.setExternalUserId(nil)
  }

  public func setSubscription(_ enabled: Bool) {
    guard let client = apiClient else { return }
    if let result = patchIfRegistered(client, { ["subscribed": enabled] }) {
      if case .success = result { deviceStore.setSubscribed(enabled) }
    }
  }

  public func mutateTags(add: [String: String]?, remove: [String]?) {
    guard let client = apiClient else { return }
    mutationLock.lock()
    defer { mutationLock.unlock() }

    guard let deviceId = deviceStore.getDeviceId(), let token = deviceStore.getLastToken() else { return }
    let merged = NuntisDeviceStore.mergeTags(deviceStore.getTags(), add: add, remove: remove)
    let result = client.patchDevice(deviceId: deviceId, token: token, fields: ["tags": merged])
    if case .success(let response) = result {
      deviceStore.setTags(response.tags)
    }
  }

  private func patchIfRegistered(_ client: NuntisApiClient, _ fields: () -> [String: Any]) -> ApiResult? {
    mutationLock.lock()
    defer { mutationLock.unlock() }

    guard let deviceId = deviceStore.getDeviceId(), let token = deviceStore.getLastToken() else { return nil }
    return client.patchDevice(deviceId: deviceId, token: token, fields: fields())
  }
}
