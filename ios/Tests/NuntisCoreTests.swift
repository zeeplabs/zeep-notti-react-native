import XCTest

final class NuntisCoreTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: NuntisDeviceStore!
  private let baseUrl = "https://nuntis.example.com"

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
    suiteName = "NuntisCoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = NuntisDeviceStore(defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func newCore(
    tokenProvider: @escaping (@escaping (String?) -> Void) -> Void = { cb in cb("apns-token") },
    permissionRequester: @escaping (@escaping (Bool) -> Void) -> Void = { cb in cb(true) },
    apiClient: NuntisApiClient? = nil,
    logs: LogSink? = nil
  ) -> NuntisCore {
    let session = stubSession()
    return NuntisCore(
      deviceStore: store,
      apiClientFactory: { appId, clientKey, baseUrl in
        apiClient
          ?? NuntisApiClient(session: session, baseUrl: baseUrl, appId: appId, clientKey: clientKey, sleeper: { _ in })
      },
      tokenProvider: tokenProvider,
      permissionRequester: permissionRequester,
      logger: { message in logs?.append(message) }
    )
  }

  func test_initializeWithBlankAppIdLogsAndDoesNotCallTheApiClient() {
    let logs = LogSink()
    let core = newCore(logs: logs)

    core.initialize(appId: "", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
    XCTAssertTrue(logs.messages.contains { $0.contains("appId, clientKey, or baseUrl") })
  }

  func test_initializeWithBlankClientKeyLogsAndDoesNotCallTheApiClient() {
    let logs = LogSink()
    let core = newCore(logs: logs)

    core.initialize(appId: "app-1", clientKey: "", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
    XCTAssertTrue(logs.messages.contains { $0.contains("appId, clientKey, or baseUrl") })
  }

  func test_initializeWithBlankBaseUrlLogsAndDoesNotCallTheApiClient() {
    let logs = LogSink()
    let core = newCore(logs: logs)

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: "")
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
    XCTAssertTrue(logs.messages.contains { $0.contains("appId, clientKey, or baseUrl") })
  }

  func test_initializeWithNoAvailablePushTokenLogsAndDoesNotRegister() {
    let logs = LogSink()
    let core = newCore(tokenProvider: { cb in cb(nil) }, logs: logs)

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
    XCTAssertTrue(logs.messages.contains { $0.contains("no push token") })
  }

  func test_initializeWithAnAsyncTokenFetchThatResolvesLaterStillRegistersOnceTheTokenArrives() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    var deferredCallback: ((String?) -> Void)?
    let core = newCore(tokenProvider: { cb in deferredCallback = cb })

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)

    deferredCallback?("apns-token")
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)
    XCTAssertEqual(store.getDeviceId(), "device-1")
    XCTAssertEqual(store.getLastToken(), "apns-token")
  }

  func test_initializeWithAnAsyncTokenFetchThatFailsDoesNotCrashAndDoesNotAttemptRegistration() {
    let logs = LogSink()
    var deferredCallback: ((String?) -> Void)?
    let core = newCore(tokenProvider: { cb in deferredCallback = cb }, logs: logs)

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    deferredCallback?(nil)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
    XCTAssertTrue(logs.messages.contains { $0.contains("no push token") })
  }

  func test_initializeHappyPathRegistersTheDeviceAndPersistsIdAndTags() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"plan":"vip"}}"#))
    let core = newCore()

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)
    XCTAssertEqual(store.getDeviceId(), "device-1")
    XCTAssertEqual(store.getLastToken(), "apns-token")
    XCTAssertEqual(store.getTags(), ["plan": "vip"])
  }

  func test_repeatInitializeWithIdenticalArgsIsANoOp() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    let core = newCore()

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)
  }

  func test_onTokenRefreshedReRegistersWithTheNewToken() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.onTokenRefreshed("new-apns-token")
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(store.getLastToken(), "new-apns-token")
  }

  func test_requestPermissionGrantPathInvokesTheNativePromptAndPatchesSubscribedTrue() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    var promptInvoked = false
    let core = newCore(permissionRequester: { cb in promptInvoked = true; cb(true) })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    var callbackResult: Bool?
    let expectation = expectation(description: "permission callback")
    core.requestPermission { granted in
      callbackResult = granted
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2)
    drain(core)

    XCTAssertTrue(promptInvoked)
    XCTAssertEqual(callbackResult, true)
    XCTAssertTrue(store.getSubscribed())
    let patchRequest = StubURLProtocol.recordedRequests().last!
    XCTAssertEqual(patchRequest.httpMethod, "PATCH")
  }

  func test_requestPermissionDenyPathPatchesSubscribedFalse() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    let core = newCore(permissionRequester: { cb in cb(false) })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let expectation = expectation(description: "permission callback")
    core.requestPermission { _ in expectation.fulfill() }
    wait(for: [expectation], timeout: 2)
    drain(core)

    XCTAssertFalse(store.getSubscribed())
  }

  func test_requestPermissionCalledBeforeInitializeLogsAndDoesNotPrompt() {
    let logs = LogSink()
    var promptInvoked = false
    let core = newCore(permissionRequester: { cb in promptInvoked = true; cb(true) }, logs: logs)

    var callbackResult: Bool?
    let expectation = expectation(description: "permission callback")
    core.requestPermission { granted in
      callbackResult = granted
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2)
    drain(core)

    XCTAssertFalse(promptInvoked)
    XCTAssertEqual(callbackResult, false)
    XCTAssertTrue(logs.messages.contains { $0.contains("before initialize") })
  }

  func test_loginPatchesExternalUserIdAndTheCachedTokenAndPersistsItLocallyOnSuccess() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.login("user-42")
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2)
    let patchRequest = requests.last!
    XCTAssertEqual(patchRequest.httpMethod, "PATCH")
    let body = try! JSONSerialization.jsonObject(with: bodyData(patchRequest)) as! [String: Any]
    XCTAssertEqual(body["external_user_id"] as? String, "user-42")
    XCTAssertEqual(body["token"] as? String, "apns-token")
    XCTAssertEqual(store.getExternalUserId(), "user-42")
  }

  func test_logoutClearsTheLocallyHeldExternalUserIdWithoutSendingAnyPatch() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    core.login("user-42")
    drain(core)
    XCTAssertEqual(store.getExternalUserId(), "user-42")

    core.logout()
    drain(core)

    // Only the initial register + login PATCH from setup above - logout()
    // itself must not issue any network call (spec SDK-15: local-only clear,
    // the backend has no support for clearing external_user_id server-side).
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 2)
    XCTAssertNil(store.getExternalUserId())
  }

  func test_setSubscriptionPatchesTheGivenSubscribedValueAndTheCachedTokenAndPersistsItLocallyOnSuccess() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setSubscription(true)
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2)
    let patchRequest = requests.last!
    XCTAssertEqual(patchRequest.httpMethod, "PATCH")
    let body = try! JSONSerialization.jsonObject(with: bodyData(patchRequest)) as! [String: Any]
    XCTAssertEqual(body["subscribed"] as? Bool, true)
    XCTAssertEqual(body["token"] as? String, "apns-token")
    XCTAssertTrue(store.getSubscribed())
  }

  func test_twoRapidTagMutationsSerializeAndConvergeToTheCorrectNetMergedResult() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    // First mutation's PATCH response is artificially slow; if mutateTags did
    // not serialize, the second (fast) mutation on another thread would race
    // ahead and read the store's tags before the first call's write landed,
    // producing a stale/incorrect merge instead of the correct net result.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"plan":"vip"}}"#, delayMs: 300))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"cohort":"beta"}}"#))

    let done1 = expectation(description: "mutation 1")
    let done2 = expectation(description: "mutation 2")

    let thread1 = Thread {
      core.mutateTags(add: ["plan": "vip"], remove: nil)
      done1.fulfill()
    }
    let thread2 = Thread {
      core.mutateTags(add: ["cohort": "beta"], remove: ["plan"])
      done2.fulfill()
    }

    thread1.start()
    Thread.sleep(forTimeInterval: 0.05) // ensure thread1's mutation is enqueued first
    thread2.start()

    wait(for: [done1, done2], timeout: 5)
    drain(core, timeout: 10)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 3)
    XCTAssertEqual(store.getTags(), ["cohort": "beta"])
  }

  // MARK: - Threading contract (main thread must never block on the API client)

  func test_initializeDoesNotBlockTheCallingThreadAndRunsTheApiCallOffTheMainThread() {
    // The APNs registration path (`didRegisterForRemoteNotificationsWith
    // DeviceToken` -> `onTokenRefreshed` -> `registerDevice`) is invoked on the
    // host app's main thread, and `NuntisApiClient` is blocking by design
    // (semaphore wait + `Thread.sleep` retry backoff). If that chain runs on
    // the caller's thread, a slow/dead network freezes the UI and the watchdog
    // kills the app (0x8badf00d).
    let probe = ThreadProbeApiClient(blockForSeconds: 1.0)
    let core = newCore(apiClient: probe)

    XCTAssertTrue(Thread.isMainThread, "XCTest drives this test from the main thread")
    let started = Date()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertLessThan(elapsed, 0.2, "initialize() must return without waiting on the network call")
    drain(core, timeout: 10)
    XCTAssertEqual(probe.callCount, 1)
    XCTAssertEqual(probe.sawMainThread, false, "the API client must never run on the main thread")
  }

  func test_onTokenRefreshedDoesNotBlockTheCallingThread() {
    let probe = ThreadProbeApiClient(blockForSeconds: 1.0)
    let core = newCore(apiClient: probe)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core, timeout: 10)

    let started = Date()
    core.onTokenRefreshed("new-apns-token")
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertLessThan(elapsed, 0.2)
    drain(core, timeout: 10)
    XCTAssertEqual(probe.callCount, 2)
    XCTAssertEqual(probe.sawMainThread, false)
  }

  func test_permissionResultPatchRunsOffTheMainThreadEvenWhenThePromptRepliesOnMain() {
    // Mirrors `NuntisImpl`'s real wiring, where the `UNUserNotificationCenter`
    // authorization result used to be hopped onto `DispatchQueue.main` before
    // the (blocking) PATCH was issued.
    let probe = ThreadProbeApiClient(blockForSeconds: 1.0)
    let core = newCore(
      permissionRequester: { cb in DispatchQueue.main.async { cb(true) } },
      apiClient: probe
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core, timeout: 10)

    let resolved = expectation(description: "permission callback")
    core.requestPermission { _ in resolved.fulfill() }
    wait(for: [resolved], timeout: 5)
    drain(core, timeout: 10)

    XCTAssertEqual(probe.patchCallCount, 1)
    XCTAssertEqual(probe.sawMainThread, false)
  }

  func test_tagMutationDoesNotBlockTheCallingThread() {
    let probe = ThreadProbeApiClient(blockForSeconds: 1.0)
    let core = newCore(apiClient: probe)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core, timeout: 10)

    let started = Date()
    core.mutateTags(add: ["plan": "vip"], remove: nil)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertLessThan(elapsed, 0.2)
    drain(core, timeout: 10)
    XCTAssertEqual(probe.patchCallCount, 1)
    XCTAssertEqual(probe.sawMainThread, false)
  }

  /// Waits (bounded) for every mutation `NuntisCore` has queued on its
  /// internal serial work queue to finish. Every public `NuntisCore` method is
  /// fire-and-forget now, so assertions on the store/recorded requests must
  /// drain first.
  private func drain(_ core: NuntisCore, timeout: TimeInterval = 5) {
    XCTAssertTrue(core.waitForPendingWork(timeout: timeout), "NuntisCore work queue did not drain in \(timeout)s")
  }

  /// Mirrors `NuntisApiClientTests.swift`'s private helper of the same name -
  /// `URLRequest.httpBody` is sometimes nil with the body only available via
  /// `httpBodyStream` depending on how `URLSession` moved it internally.
  private func bodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: bufferSize)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}

/// An API client that records which thread it was called on and blocks there
/// for a while, standing in for a slow/dead network. A stubbed `URLProtocol`
/// cannot prove this: `URLSession` always runs the protocol on its own
/// internal queue, so the only way to observe the thread the *SDK's* blocking
/// call chain occupies is from inside the client itself.
final class ThreadProbeApiClient: NuntisApiClient {

  private let blockForSeconds: TimeInterval
  private let lock = NSLock()
  private var mainThreadSeen = false
  private var calls = 0
  private var patchCalls = 0

  init(blockForSeconds: TimeInterval) {
    self.blockForSeconds = blockForSeconds
    super.init(baseUrl: "https://nuntis.example.com", appId: "app-1", clientKey: "key", sleeper: { _ in })
  }

  var sawMainThread: Bool {
    lock.lock(); defer { lock.unlock() }
    return mainThreadSeen
  }

  var callCount: Int {
    lock.lock(); defer { lock.unlock() }
    return calls
  }

  var patchCallCount: Int {
    lock.lock(); defer { lock.unlock() }
    return patchCalls
  }

  override func createOrUpdateDevice(token: String, platform: String) -> ApiResult {
    record(isPatch: false)
    Thread.sleep(forTimeInterval: blockForSeconds)
    return .success(DeviceResponse(id: "device-1", tags: [:]))
  }

  override func patchDevice(deviceId: String, token: String, fields: [String: Any]) -> ApiResult {
    record(isPatch: true)
    Thread.sleep(forTimeInterval: blockForSeconds)
    return .success(DeviceResponse(id: deviceId, tags: (fields["tags"] as? [String: String]) ?? [:]))
  }

  private func record(isPatch: Bool) {
    let onMain = Thread.isMainThread
    lock.lock(); defer { lock.unlock() }
    if onMain { mainThreadSeen = true }
    calls += 1
    if isPatch { patchCalls += 1 }
  }
}

/// Thread-safe log capture, mirroring `NuntisCoreTest.kt`'s plain
/// `mutableListOf<String>()` (safe there because Kotlin's test only touches
/// it from callbacks that are themselves synchronized) — this SDK's
/// serialization test drives `NuntisCore` from two real threads, so the
/// Swift equivalent needs its own lock.
final class LogSink {
  private let lock = NSLock()
  private var storage: [String] = []

  func append(_ message: String) {
    lock.lock(); defer { lock.unlock() }
    storage.append(message)
  }

  var messages: [String] {
    lock.lock(); defer { lock.unlock() }
    return storage
  }
}
