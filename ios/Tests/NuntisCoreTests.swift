import UIKit
import XCTest

final class NuntisCoreTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: NuntisDeviceStore!
  private let baseUrl = "https://nuntis.example.com"

  /// Everything a test built, so `tearDown` can dispose of it deterministically.
  ///
  /// Both of these used to be dropped on the floor at the end of each test
  /// method, which leaks in two ways that compound over a 36-test class:
  ///
  /// * a `URLSession` is only released once it is invalidated ("if you do not
  ///   invalidate the session, your app leaks memory until it exits"), so every
  ///   `newCore()` left a live session behind — each with its own delegate
  ///   queue and CFNetwork worker threads. By the end of the class dozens of
  ///   them were competing for a 3-core CI runner, and a stubbed request that
  ///   costs ~10ms on a dev machine was taking well over a second there. Five
  ///   of those in one blocking retry loop no longer fit inside a test's drain
  ///   budget.
  /// * a `NuntisCore` whose work queue is still busy stays alive through its
  ///   own in-flight blocks. Once a drain timed out, that core kept running
  ///   *into the next test* — consuming responses from the process-global
  ///   `StubURLProtocol` queue and recording requests against the next test's
  ///   freshly reset counters, which is how one slow test cascaded into three
  ///   unrelated failures on CI.
  private var sessions: [URLSession] = []
  private var cores: [NuntisCore] = []

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
    suiteName = "NuntisCoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = NuntisDeviceStore(defaults: defaults)
  }

  override func tearDown() {
    // Let whatever is still queued finish before the next test resets the
    // shared stub, so no core outlives the test that created it.
    for core in cores { core.waitForPendingWork(timeout: 20) }
    cores.removeAll()
    for session in sessions { session.invalidateAndCancel() }
    sessions.removeAll()
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: config)
    sessions.append(session)
    return session
  }

  private func newCore(
    tokenProvider: @escaping (@escaping (String?) -> Void) -> Void = { cb in cb("apns-token") },
    permissionRequester: @escaping (@escaping (Bool) -> Void) -> Void = { cb in cb(true) },
    apiClient: NuntisApiClient? = nil,
    logs: LogSink? = nil
  ) -> NuntisCore {
    let session = stubSession()
    let core = NuntisCore(
      deviceStore: store,
      apiClientFactory: { appId, clientKey, baseUrl in
        apiClient
          ?? NuntisApiClient(session: session, baseUrl: baseUrl, appId: appId, clientKey: clientKey, sleeper: { _ in })
      },
      tokenProvider: tokenProvider,
      permissionRequester: permissionRequester,
      logger: { message in logs?.append(message) }
    )
    cores.append(core)
    return core
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
    wait(for: [expectation], timeout: 15)
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
    wait(for: [expectation], timeout: 15)
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
    wait(for: [expectation], timeout: 15)
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

  func test_aBodylessPatchAckStillPersistsTheMutationLocallyAndIsNotRetried() {
    // A backend that answers PATCH with `204 No Content` is doing nothing
    // wrong. Demanding a full device object back made every login/addTags/
    // setSubscription against such a backend burn five attempts and persist
    // nothing locally.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(204)) // login
    StubURLProtocol.enqueue(.status(204)) // addTags
    StubURLProtocol.enqueue(.status(204)) // setSubscription
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.login("user-42")
    core.mutateTags(add: ["plan": "vip"], remove: nil)
    core.setSubscription(true)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 4, "register + 3 PATCHes, none retried")
    XCTAssertEqual(store.getExternalUserId(), "user-42")
    XCTAssertEqual(store.getTags(), ["plan": "vip"], "an empty ACK must not wipe the tag cache")
    XCTAssertTrue(store.getSubscribed())
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

    wait(for: [done1, done2], timeout: 15)
    drain(core, timeout: 20)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 3)
    XCTAssertEqual(store.getTags(), ["cohort": "beta"])
  }

  // MARK: - Invalid baseUrl must disable the SDK, never crash the host app

  func test_initializeWithAMalformedBaseUrlDoesNotCrashAndDoesNotRegister() {
    // "my host.example.com" is non-empty, so it got past the isEmpty guard and
    // reached `URL(string:)!` inside the API client, taking the host app down
    // with it. Spec SDK-03: log, stay disabled, never crash.
    let malformed = [
      "my host.example.com", // space in the host
      "push.example.com", // no scheme
      "not a url at all",
      "https://", // scheme but no host
      "ftp://push.example.com", // unsupported scheme
      "   ",
    ]

    for baseUrl in malformed {
      StubURLProtocol.reset()
      let logs = LogSink()
      let core = newCore(logs: logs)

      core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
      drain(core)

      XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0, "must not register with baseUrl '\(baseUrl)'")
      XCTAssertNil(store.getDeviceId())
      XCTAssertTrue(
        logs.messages.contains { $0.contains("baseUrl") },
        "expected a config error logged for baseUrl '\(baseUrl)', got \(logs.messages)"
      )
    }
  }

  func test_initializeWithAMalformedBaseUrlLeavesLaterMutationsInertRatherThanCrashing() {
    let core = newCore(logs: LogSink())
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: "my host.example.com")
    drain(core)

    core.mutateTags(add: ["plan": "vip"], remove: nil)
    core.login("user-42")
    core.setSubscription(true)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
  }

  func test_initializeTrimsATrailingSlashFromTheBaseUrlSoRequestPathsStayValid() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    let core = newCore()

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: "\(baseUrl)/")
    drain(core)

    let recorded = StubURLProtocol.recordedRequests()
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded[0].url?.path, "/v1/apps/app-1/devices")
  }

  // MARK: - Mutations issued before registration completes

  func test_tagsAddedBeforeTheApnsTokenArrivesAreSentOnceRegistrationCompletes() {
    // `initialize()` cannot register synchronously on iOS: the APNs token only
    // shows up later via didRegisterForRemoteNotificationsWithDeviceToken. A
    // mutation issued in that window must be queued, not dropped.
    var deliverToken: ((String?) -> Void)?
    let core = newCore(tokenProvider: { cb in deliverToken = cb })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.mutateTags(add: ["plan": "vip"], remove: nil)
    drain(core)
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0, "nothing can be sent before the device has an id")

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"plan":"vip"}}"#))
    deliverToken?("apns-token")
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2, "the queued tag mutation must be flushed after registration")
    XCTAssertEqual(requests.last!.httpMethod, "PATCH")
    let body = try! JSONSerialization.jsonObject(with: bodyData(requests.last!)) as! [String: Any]
    XCTAssertEqual(body["tags"] as? [String: String], ["plan": "vip"])
    XCTAssertEqual(store.getTags(), ["plan": "vip"])
  }

  func test_permissionGrantedBeforeTheApnsTokenArrivesStillPatchesSubscribedAfterRegistration() {
    // Worst case of the same window: permission granted before the token
    // round-trip finished used to leave the device permanently ineligible for
    // push - subscribed was never PATCHed nor persisted, and nothing retried.
    var deliverToken: ((String?) -> Void)?
    let core = newCore(tokenProvider: { cb in deliverToken = cb }, permissionRequester: { cb in cb(true) })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let resolved = expectation(description: "permission callback")
    core.requestPermission { granted in
      XCTAssertTrue(granted)
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 15)
    drain(core)
    XCTAssertFalse(store.getSubscribed())

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    deliverToken?("apns-token")
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.last!.httpMethod, "PATCH")
    let body = try! JSONSerialization.jsonObject(with: bodyData(requests.last!)) as! [String: Any]
    XCTAssertEqual(body["subscribed"] as? Bool, true)
    XCTAssertEqual(body["token"] as? String, "apns-token")
    XCTAssertTrue(store.getSubscribed())
  }

  func test_loginBeforeTheApnsTokenArrivesIsSentOnceRegistrationCompletes() {
    var deliverToken: ((String?) -> Void)?
    let core = newCore(tokenProvider: { cb in deliverToken = cb })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.login("user-42")
    drain(core)
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    deliverToken?("apns-token")
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2)
    let body = try! JSONSerialization.jsonObject(with: bodyData(requests.last!)) as! [String: Any]
    XCTAssertEqual(body["external_user_id"] as? String, "user-42")
    XCTAssertEqual(store.getExternalUserId(), "user-42")
  }

  func test_mutationsQueuedBeforeRegistrationAreFlushedInCallOrder() {
    var deliverToken: ((String?) -> Void)?
    let core = newCore(tokenProvider: { cb in deliverToken = cb })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.mutateTags(add: ["plan": "vip"], remove: nil)
    core.login("user-42")
    core.mutateTags(add: nil, remove: ["plan"])
    drain(core)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"plan":"vip"}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"plan":"vip"}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    deliverToken?("apns-token")
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 4)
    let bodies = requests.dropFirst().map { try! JSONSerialization.jsonObject(with: bodyData($0)) as! [String: Any] }
    XCTAssertEqual(bodies[0]["tags"] as? [String: String], ["plan": "vip"])
    XCTAssertEqual(bodies[1]["external_user_id"] as? String, "user-42")
    // The last mutation removes the key the first one added: the queued merge
    // must read the tag cache at send time, so it sees "plan" and drops it.
    XCTAssertEqual(bodies[2]["tags"] as? [String: String], [:])
    XCTAssertEqual(store.getTags(), [:])
  }

  // MARK: - Foreground retry after the retry cap is exhausted (P1-AC5)

  func test_registrationThatExhaustedItsRetryCapIsRetriedOnTheNextAppForeground() {
    // The backoff stops after 5 attempts. Without a foreground hook the device
    // stayed unregistered until the app was relaunched.
    for _ in 0..<5 { StubURLProtocol.enqueue(.status(500)) }
    let logs = LogSink()
    let core = newCore(logs: logs)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 5)
    XCTAssertNil(store.getDeviceId())

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(core, timeout: 20)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 6, "foreground must re-trigger registration")
    XCTAssertEqual(store.getDeviceId(), "device-1")
    XCTAssertEqual(store.getLastToken(), "apns-token")
  }

  func test_aSuccessfulRegistrationIsNotRepeatedOnEveryForeground() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    for _ in 0..<3 {
      NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    drain(core, timeout: 20)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)
  }

  func test_foregroundsArrivingWhileARegistrationIsInFlightDoNotPileUpExtraAttempts() {
    // Guards against a retry storm: several didBecomeActive notifications
    // during one in-flight registration must collapse into nothing extra.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#, delayMs: 400))
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)

    XCTAssertTrue(waitForRequestCount(1, timeout: 15), "registration request never went out")
    for _ in 0..<5 {
      NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    drain(core, timeout: 20)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)
    XCTAssertEqual(store.getDeviceId(), "device-1")
  }

  func test_foregroundBeforeInitializeDoesNothing() {
    let core = newCore()

    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
    _ = core
  }

  func test_foregroundRetriesRegistrationWhenTheTokenNeverArrivedTheFirstTime() {
    var deliverToken: ((String?) -> Void)?
    let core = newCore(tokenProvider: { cb in deliverToken = cb })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(core)
    // The foreground retry asks the platform for a token again; registration
    // happens once that (async) request resolves.
    deliverToken?("apns-token")
    drain(core, timeout: 20)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)
    XCTAssertEqual(store.getDeviceId(), "device-1")
  }

  func test_foregroundRetryDoesNotRegisterWithAPreviousSessionsPersistedToken() {
    // Relaunch: a token from the last session is still in the store, but APNs
    // has not delivered this session's token yet. The foreground retry used to
    // fall back to the persisted one, registering the backend against a token
    // that may already be dead - and then registering a *second* time moments
    // later when the real token arrived.
    store.setLastToken("stale-token-from-last-session")
    var deliverToken: ((String?) -> Void)?
    let core = newCore(tokenProvider: { cb in deliverToken = cb })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(core, timeout: 20)

    XCTAssertEqual(
      StubURLProtocol.recordedRequests().count, 0,
      "the foreground retry must wait for a real token, not reuse the persisted one"
    )

    // The real token lands right after: exactly one registration, with it.
    deliverToken?("fresh-apns-token")
    drain(core, timeout: 20)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 1, "no duplicate registration")
    let body = try! JSONSerialization.jsonObject(with: bodyData(requests[0])) as! [String: Any]
    XCTAssertEqual(body["token"] as? String, "fresh-apns-token")
    XCTAssertEqual(store.getLastToken(), "fresh-apns-token")
  }

  // MARK: - A 2xx that is not a device object must not fake a successful registration

  func test_registrationWith2xxButAnUnparseableBodyDoesNotFakeSuccessAndRetriesOnForeground() {
    // Captive-portal/proxy 200-with-HTML (or a renamed `id` field) used to be
    // reported as a successful registration carrying an empty device id: the
    // SDK then persisted "" as the deviceId, wiped its local tags, and aimed
    // every later PATCH at `.../devices/`. It must fail honestly instead, and
    // stay eligible for the foreground retry.
    store.setDeviceId("device-old")
    store.setLastToken("apns-token")
    store.setTags(["plan": "vip"])

    for _ in 0..<5 { StubURLProtocol.enqueue(.status(200, body: "<html>captive portal</html>")) }
    let logs = LogSink()
    let core = newCore(logs: logs)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core, timeout: 20)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 5)
    XCTAssertEqual(store.getDeviceId(), "device-old", "an empty device id must never be persisted")
    XCTAssertEqual(store.getTags(), ["plan": "vip"], "local tags must survive a failed registration")
    XCTAssertTrue(logs.messages.contains { $0.contains("registration failed") })

    // Still marked failed, so the next foreground gets another go and can win.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"plan":"vip"}}"#))
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(core, timeout: 20)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 6)
    XCTAssertEqual(store.getDeviceId(), "device-1")
  }

  // MARK: - Registration tag write vs. addTags read-merge-write

  func test_aRegistrationLandingDuringAnInFlightAddTagsCannotClobberTheMergedTags() {
    // The registration path also writes the tag cache (from the register
    // response). If that write is not mutually exclusive with addTags'
    // read-merge-write, a token-refresh registration that *started* before the
    // mutation but *finishes* after it overwrites the merged map with its own
    // stale tags, silently dropping the tag the app just added.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    // Token-refresh registration: slow, and its response carries the server's
    // pre-mutation tag state (empty).
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#, delayMs: 400))
    // The tag PATCH that follows: fast, echoing the merged map back.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"plan":"vip"}}"#))

    let refreshIssued = expectation(description: "token refresh issued")
    let mutationIssued = expectation(description: "tag mutation issued")

    let refreshThread = Thread {
      core.onTokenRefreshed("apns-token-2")
      refreshIssued.fulfill()
    }
    refreshThread.start()

    // Deterministic interleaving: only start the mutation once the
    // registration request is provably in flight inside the API client.
    XCTAssertTrue(waitForRequestCount(2, timeout: 15), "registration request never went out")

    let mutationThread = Thread {
      core.mutateTags(add: ["plan": "vip"], remove: nil)
      mutationIssued.fulfill()
    }
    mutationThread.start()

    wait(for: [refreshIssued, mutationIssued], timeout: 15)
    drain(core, timeout: 20)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 3)
    XCTAssertEqual(store.getTags(), ["plan": "vip"], "the registration response must not clobber the merged tags")
  }

  /// Bounded poll until the stub has seen `count` requests. Used to force a
  /// deterministic interleaving instead of relying on sleep timings.
  private func waitForRequestCount(_ count: Int, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if StubURLProtocol.recordedRequests().count >= count { return true }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return false
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
    drain(core, timeout: 20)
    XCTAssertEqual(probe.callCount, 1)
    XCTAssertEqual(probe.sawMainThread, false, "the API client must never run on the main thread")
  }

  func test_onTokenRefreshedDoesNotBlockTheCallingThread() {
    let probe = ThreadProbeApiClient(blockForSeconds: 1.0)
    let core = newCore(apiClient: probe)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core, timeout: 20)

    let started = Date()
    core.onTokenRefreshed("new-apns-token")
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertLessThan(elapsed, 0.2)
    drain(core, timeout: 20)
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
    drain(core, timeout: 20)

    let resolved = expectation(description: "permission callback")
    core.requestPermission { _ in resolved.fulfill() }
    wait(for: [resolved], timeout: 15)
    drain(core, timeout: 20)

    XCTAssertEqual(probe.patchCallCount, 1)
    XCTAssertEqual(probe.sawMainThread, false)
  }

  func test_tagMutationDoesNotBlockTheCallingThread() {
    let probe = ThreadProbeApiClient(blockForSeconds: 1.0)
    let core = newCore(apiClient: probe)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core, timeout: 20)

    let started = Date()
    core.mutateTags(add: ["plan": "vip"], remove: nil)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertLessThan(elapsed, 0.2)
    drain(core, timeout: 20)
    XCTAssertEqual(probe.patchCallCount, 1)
    XCTAssertEqual(probe.sawMainThread, false)
  }

  /// Waits (bounded) for every mutation `NuntisCore` has queued on its
  /// internal serial work queue to finish. Every public `NuntisCore` method is
  /// fire-and-forget now, so assertions on the store/recorded requests must
  /// drain first.
  /// The timeout is a liveness bound, not an assertion about how fast the SDK
  /// is: the work being awaited is a handful of instantly-answered stub
  /// requests, so a healthy run drains in milliseconds regardless of the value.
  /// It is generous because the shared CI runner is an order of magnitude
  /// slower per request than a dev machine, and a drain that expires there
  /// leaves the core running into the next test.
  private func drain(_ core: NuntisCore, timeout: TimeInterval = 25) {
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
