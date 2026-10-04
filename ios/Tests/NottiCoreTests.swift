import UIKit
import XCTest

final class NottiCoreTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: NottiDeviceStore!
  private let baseUrl = "https://notti.example.com"

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
  /// * a `NottiCore` whose work queue is still busy stays alive through its
  ///   own in-flight blocks. Once a drain timed out, that core kept running
  ///   *into the next test* — consuming responses from the process-global
  ///   `StubURLProtocol` queue and recording requests against the next test's
  ///   freshly reset counters, which is how one slow test cascaded into three
  ///   unrelated failures on CI.
  private var sessions: [URLSession] = []
  private var cores: [NottiCore] = []

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
    suiteName = "NottiCoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = NottiDeviceStore(defaults: defaults)
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
    versionProvider: @escaping () -> String? = { nil },
    hasLocationPermission: @escaping () -> Bool = { false },
    countryProvider: @escaping (@escaping (String?) -> Void) -> Void = { $0(nil) },
    deviceOsProvider: @escaping () -> String? = { nil },
    deviceModelProvider: @escaping () -> String? = { nil },
    timezoneProvider: @escaping () -> String? = { nil },
    languageProvider: @escaping () -> String? = { nil },
    permissionStatusProvider: @escaping (@escaping (String?) -> Void) -> Void = { $0(nil) },
    appStateProvider: @escaping (@escaping (Bool) -> Void) -> Void = { $0(false) },
    beginBackgroundTask: @escaping () -> (() -> Void) = { {} },
    heartbeatInterval: TimeInterval = 60,
    apiClient: NottiApiClient? = nil,
    logs: LogSink? = nil,
    onDeviceIdChanged: @escaping (String) -> Void = { _ in },
    eventStore: NottiEventStore? = nil,
    sessionGate: NottiCore.SessionGate = NottiCore.SessionGate()
  ) -> NottiCore {
    let session = stubSession()
    let core = NottiCore(
      deviceStore: store,
      eventStore: eventStore ?? NottiEventStore(defaults: defaults),
      apiClientFactory: { appId, clientKey, baseUrl in
        apiClient
          ?? NottiApiClient(session: session, baseUrl: baseUrl, appId: appId, clientKey: clientKey, sleeper: { _ in })
      },
      tokenProvider: tokenProvider,
      permissionRequester: permissionRequester,
      versionProvider: versionProvider,
      hasLocationPermission: hasLocationPermission,
      countryProvider: countryProvider,
      deviceOsProvider: deviceOsProvider,
      deviceModelProvider: deviceModelProvider,
      timezoneProvider: timezoneProvider,
      languageProvider: languageProvider,
      permissionStatusProvider: permissionStatusProvider,
      appStateProvider: appStateProvider,
      beginBackgroundTask: beginBackgroundTask,
      heartbeatInterval: heartbeatInterval,
      logger: { message in logs?.append(message) },
      onDeviceIdChanged: onDeviceIdChanged,
      sessionGate: sessionGate
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

  func test_initializeHappyPathExposesThePersistedIdViaGetDeviceId() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    let core = newCore()

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(core.getDeviceId(), "device-1")
  }

  func test_firstRegistrationNotifiesOnDeviceIdChangedWithTheNewlyAssignedId() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    var changes: [String] = []
    let core = newCore(onDeviceIdChanged: { changes.append($0) })

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(changes, ["device-1"])
  }

  func test_reRegistrationThatReturnsTheSameIdDoesNotNotifyOnDeviceIdChangedAgain() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    var changes: [String] = []
    let core = newCore(onDeviceIdChanged: { changes.append($0) })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.onTokenRefreshed("new-apns-token")
    drain(core)

    XCTAssertEqual(changes, ["device-1"])
  }

  func test_reRegistrationThatReturnsADifferentIdNotifiesOnDeviceIdChangedWithTheNewValue() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-2","tags":{}}"#))
    var changes: [String] = []
    let core = newCore(onDeviceIdChanged: { changes.append($0) })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.onTokenRefreshed("new-apns-token")
    drain(core)

    XCTAssertEqual(changes, ["device-1", "device-2"])
    XCTAssertEqual(core.getDeviceId(), "device-2")
  }

  func test_aFirstRegistrationThatFailsDoesNotNotifyOnDeviceIdChangedAndLeavesGetDeviceIdNil() {
    for _ in 0..<5 { StubURLProtocol.enqueue(.status(500)) }
    var changes: [String] = []
    let core = newCore(onDeviceIdChanged: { changes.append($0) })

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(changes, [])
    XCTAssertNil(core.getDeviceId())
  }

  func test_aReRegistrationThatFailsDoesNotNotifyOnDeviceIdChangedAndLeavesGetDeviceIdAtItsLastKnownValue() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    for _ in 0..<5 { StubURLProtocol.enqueue(.status(500)) }
    var changes: [String] = []
    let core = newCore(onDeviceIdChanged: { changes.append($0) })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.onTokenRefreshed("new-apns-token")
    drain(core)

    XCTAssertEqual(changes, ["device-1"])
    XCTAssertEqual(core.getDeviceId(), "device-1")
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

  func test_logoutClearsTheExternalUserIdLocallyOnlyAndEnqueuesEmailAndPhoneNullClears() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // login
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // email set
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // phone set
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // email null
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // phone null
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    core.login("user-42")
    core.setEmail("user@example.com")
    core.setPhone("+5511999999999")
    drain(core)
    XCTAssertEqual(store.getExternalUserId(), "user-42")
    XCTAssertEqual(store.getLastSyncedEmail(), "user@example.com")

    core.logout()
    drain(core)

    // external_user_id is a local-only clear (spec SDK-15: the backend has no
    // support for clearing it server-side), but the PII email/phone ARE
    // cleared server-side with explicit nulls (F2).
    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 6, "register + login + email/phone set + email/phone null")
    let logoutBodies = patchBodies(Array(requests.dropFirst(4)))
    XCTAssertTrue(logoutBodies.allSatisfy { $0["external_user_id"] == nil })
    XCTAssertTrue(logoutBodies.contains { $0["email"] is NSNull })
    XCTAssertTrue(logoutBodies.contains { $0["phone"] is NSNull })
    XCTAssertNil(store.getExternalUserId())
    XCTAssertNil(store.getEmail())
    XCTAssertNil(store.getPhone())
    XCTAssertNil(store.getLastSyncedEmail())
    XCTAssertNil(store.getLastSyncedPhone())
  }

  func test_logoutBeforeInitializeClearsLocallyAndResendsTheNullsAtRegistration() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // email null
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // phone null
    store.setEmail("user@example.com")
    store.setLastSyncedEmail("user@example.com")
    store.setPhone("+5511999999999")
    store.setLastSyncedPhone("+5511999999999")
    let core = newCore()
    core.logout()
    drain(core)
    XCTAssertNil(store.getEmail())
    XCTAssertNil(store.getPhone())

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertTrue(bodies.contains { $0["email"] is NSNull })
    XCTAssertTrue(bodies.contains { $0["phone"] is NSNull })
    XCTAssertNil(store.getLastSyncedEmail())
    XCTAssertNil(store.getLastSyncedPhone())
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

  // MARK: - B1 (LGPD opt-out must not wait on a busy work queue)

  /// Pre-release review round 3, B1: `setLocationSharingEnabled` used to do
  /// its `UserDefaults` writes inside `workQueue.async`, which
  /// `NottiApiClient`'s blocking retry backoff can occupy for minutes. A
  /// process killed in that window would never have persisted the opt-out.
  /// This test blocks the queue with a slow, synchronous `tokenProvider`
  /// (standing in for a live registration retry) and asserts the opt-out and
  /// its pending-clear obligation are visible on `store` *before* the queue
  /// is ever released - i.e. they were written on the caller's thread, not
  /// queued behind the busy work.
  func test_setLocationSharingEnabledPersistsImmediatelyEvenWhileTheWorkQueueIsBusy() {
    store.setLocationSharingEnabled(true)

    let tokenProviderEntered = XCTestExpectation(description: "tokenProvider entered (queue now busy)")
    let releaseQueue = XCTestExpectation(description: "test releases the queue")
    let core = newCore(tokenProvider: { cb in
      tokenProviderEntered.fulfill()
      _ = XCTWaiter.wait(for: [releaseQueue], timeout: 5)
      cb("apns-token")
    })

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    wait(for: [tokenProviderEntered], timeout: 2)

    core.setLocationSharingEnabled(false)

    XCTAssertFalse(
      store.getLocationSharingEnabled(),
      "opt-out must persist before the method returns, not after the busy work queue drains"
    )
    XCTAssertTrue(
      store.getPendingCountryClear(),
      "the pending country-clear obligation must be armed immediately, surviving a process death before the queue drains"
    )

    releaseQueue.fulfill()
    drain(core)
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

  // MARK: - Offline event queue flush (SDKCTR-09/SDKCTR-12)

  func test_flushEventQueueBeforeInitializeIsANoOpAndKeepsTheEvent() {
    // `apiClient` is nil until `initialize` runs, so even a foreground trigger
    // must not report anything - and the pending event must stay queued. This
    // is the closest iOS gets to a direct flush call without `initialize`.
    let eventStore = NottiEventStore(defaults: defaults)
    _ = eventStore.enqueue(notificationId: "n-1", deliveryId: "d-1", type: "received")
    let core = newCore(eventStore: eventStore)

    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(core)

    XCTAssertTrue(StubURLProtocol.recordedRequests().isEmpty)
    XCTAssertEqual(eventStore.all().count, 1)
  }

  func test_registrationSuccessFlushesAQueuedEventAndRemovesIt() {
    let eventStore = NottiEventStore(defaults: defaults)
    _ = eventStore.enqueue(notificationId: "n-1", deliveryId: "d-1", type: "received")
    let core = newCore(eventStore: eventStore)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200)) // event report
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2, "register + event report")
    XCTAssertEqual(requests[1].httpMethod, "POST")
    XCTAssertEqual(requests[1].url?.path, "/v1/apps/app-1/notifications/n-1/events")
    let body = try! JSONSerialization.jsonObject(with: bodyData(requests[1])) as! [String: Any]
    XCTAssertEqual(body["delivery_id"] as? String, "d-1")
    XCTAssertEqual(body["type"] as? String, "received")
    XCTAssertEqual(body["token"] as? String, "apns-token")
    XCTAssertTrue(eventStore.all().isEmpty)
  }

  func test_flushEventQueueKeepsTheEventWhenReportingFails() {
    // `reportEvent` already exhausted its own 5-attempt retry cycle with
    // backoff; a failure returned here means "give up for now", so the event
    // stays queued for the next registration/foreground flush.
    let eventStore = NottiEventStore(defaults: defaults)
    _ = eventStore.enqueue(notificationId: "n-1", deliveryId: "d-1", type: "received")
    let core = newCore(eventStore: eventStore)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    for _ in 0..<5 { StubURLProtocol.enqueue(.status(500)) } // event report: 5 failed attempts
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 6, "register + 5 event attempts")
    XCTAssertEqual(eventStore.all().count, 1)
  }

  func test_flushEventQueueDropsTheEventOnATerminal4xxReport() {
    // A 403 (e.g. stale/mismatched token per spec SDKCTR-11) is terminal: the
    // backend will never accept it, so the event must be dropped, not left to
    // re-fail forever on every flush trigger.
    let eventStore = NottiEventStore(defaults: defaults)
    _ = eventStore.enqueue(notificationId: "n-1", deliveryId: "d-1", type: "received")
    let core = newCore(eventStore: eventStore)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(403)) // event report: terminal
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 2, "register + 1 terminal event attempt")
    XCTAssertTrue(eventStore.all().isEmpty, "a terminal 4xx must remove the event from the queue")
  }

  func test_appForegroundFlushesTheEventQueueEvenWhenAlreadyRegistered() {
    // A device that is already registered skips the foreground registration
    // retry but must still get its offline event queue flushed on every
    // foreground.
    let eventStore = NottiEventStore(defaults: defaults)
    let core = newCore(eventStore: eventStore)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)

    _ = eventStore.enqueue(notificationId: "n-1", deliveryId: "d-1", type: "clicked")
    StubURLProtocol.enqueue(.status(200)) // event report
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(core, timeout: 20)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2, "register + foreground event report, no re-registration")
    XCTAssertEqual(requests[1].httpMethod, "POST")
    XCTAssertEqual(requests[1].url?.path, "/v1/apps/app-1/notifications/n-1/events")
    XCTAssertTrue(eventStore.all().isEmpty)
  }

  func test_aQueuedOpenedEventIsFlushedWithTypeOpenedAndRemovedOn2xx() {
    // SDKOPEN-09: `opened` rides the same write-ahead queue and flush path as
    // received/clicked; the stored type is sent as is.
    let eventStore = NottiEventStore(defaults: defaults)
    let core = newCore(eventStore: eventStore)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    _ = eventStore.enqueue(notificationId: "n-1", deliveryId: "d-1", type: NottiEventType.opened)
    StubURLProtocol.enqueue(.status(201)) // event report
    core.onNetworkAvailable()
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[1].url?.path, "/v1/apps/app-1/notifications/n-1/events")
    let body = try! JSONSerialization.jsonObject(with: bodyData(requests[1])) as! [String: Any]
    XCTAssertEqual(body["type"] as? String, "opened")
    XCTAssertEqual(body["delivery_id"] as? String, "d-1")
    XCTAssertTrue(eventStore.all().isEmpty)
  }

  func test_onNetworkAvailableFlushesAQueuedEventAfterRegistration() {
    // T8: the network observer (and the push delegate's opportunistic flush)
    // trigger `onNetworkAvailable`; it must hop onto the work queue and drain
    // the offline queue the same way the app-foreground trigger does.
    let eventStore = NottiEventStore(defaults: defaults)
    let core = newCore(eventStore: eventStore)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)

    _ = eventStore.enqueue(notificationId: "n-1", deliveryId: "d-1", type: "clicked")
    StubURLProtocol.enqueue(.status(200)) // event report
    core.onNetworkAvailable()
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2, "register + network-triggered event report")
    XCTAssertEqual(requests[1].httpMethod, "POST")
    XCTAssertEqual(requests[1].url?.path, "/v1/apps/app-1/notifications/n-1/events")
    XCTAssertTrue(eventStore.all().isEmpty)
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
    // host app's main thread, and `NottiApiClient` is blocking by design
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
    // Mirrors `NottiImpl`'s real wiring, where the `UNUserNotificationCenter`
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

  /// Waits (bounded) for every mutation `NottiCore` has queued on its
  /// internal serial work queue to finish. Every public `NottiCore` method is
  /// fire-and-forget now, so assertions on the store/recorded requests must
  /// drain first.
  /// The timeout is a liveness bound, not an assertion about how fast the SDK
  /// is: the work being awaited is a handful of instantly-answered stub
  /// requests, so a healthy run drains in milliseconds regardless of the value.
  /// It is generous because the shared CI runner is an order of magnitude
  /// slower per request than a dev machine, and a drain that expires there
  /// leaves the core running into the next test.
  private func drain(_ core: NottiCore, timeout: TimeInterval = 25) {
    XCTAssertTrue(core.waitForPendingWork(timeout: timeout), "NottiCore work queue did not drain in \(timeout)s")
  }

  /// Mirrors `NottiApiClientTests.swift`'s private helper of the same name -
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

  private func patchBodies(_ requests: [URLRequest]) -> [[String: Any]] {
    requests.filter { $0.httpMethod == "PATCH" }.map {
      try! JSONSerialization.jsonObject(with: bodyData($0)) as! [String: Any]
    }
  }

  // MARK: - App version sync (T7, SEGTEL-01/02/03/04)

  func test_appVersionDiffOnRegistrationEnqueuesAPatchWithTheVersion() {
    StubURLProtocol.enqueue(.echoDevice()) // registration
    StubURLProtocol.enqueue(.echoDevice()) // app_version PATCH
    let core = newCore(versionProvider: { "1.2.3" })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2, "register + app_version PATCH")
    XCTAssertEqual(requests[1].httpMethod, "PATCH")
    let body = patchBodies(requests).first!
    XCTAssertEqual(body["app_version"] as? String, "1.2.3")
    XCTAssertEqual(store.getAppVersion(), "1.2.3")
  }

  func test_appVersionEqualToTheLastSyncedValueDoesNotPatchAgain() {
    store.setAppVersion("1.2.3")
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration only
    let core = newCore(versionProvider: { "1.2.3" })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1, "no PATCH when the version is unchanged")
    XCTAssertEqual(store.getAppVersion(), "1.2.3")
  }

  func test_aNilVersionProviderSkipsTheSyncEntirely() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration only
    let core = newCore(versionProvider: { nil })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)
    XCTAssertNil(store.getAppVersion())
  }

  func test_aBumpedVersionBetweenTwoRegistrationsResyncsWithTheNewValue() {
    var currentVersion: String? = "1.2.3"
    StubURLProtocol.enqueue(.echoDevice()) // registration 1
    StubURLProtocol.enqueue(.echoDevice()) // app_version 1.2.3
    StubURLProtocol.enqueue(.echoDevice()) // registration 2 (token refresh)
    StubURLProtocol.enqueue(.echoDevice()) // app_version 2.0.0
    let core = newCore(versionProvider: { currentVersion })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    XCTAssertEqual(store.getAppVersion(), "1.2.3")

    currentVersion = "2.0.0"
    core.onTokenRefreshed("new-apns-token")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 2, "one app_version PATCH per registration")
    XCTAssertEqual(bodies[0]["app_version"] as? String, "1.2.3")
    XCTAssertEqual(bodies[1]["app_version"] as? String, "2.0.0")
    XCTAssertEqual(store.getAppVersion(), "2.0.0")
  }

  // MARK: - Device profile fields (T7, DPF-01..09)

  func test_registrationWithProfileProvidersPatchesAllSixFields() {
    StubURLProtocol.enqueue(.echoDevice()) // registration
    for _ in 0..<6 { StubURLProtocol.enqueue(.echoDevice()) } // six PATCHes
    let core = newCore(
      versionProvider: { "1.2.3" },
      deviceOsProvider: { "18.0" },
      deviceModelProvider: { "iPhone17,1" },
      timezoneProvider: { "America/Sao_Paulo" },
      languageProvider: { "pt" }
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl, sdkVersion: "0.5.0")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 6)
    XCTAssertEqual(bodies.first { $0["app_version"] != nil }?["app_version"] as? String, "1.2.3")
    XCTAssertEqual(bodies.first { $0["device_os"] != nil }?["device_os"] as? String, "18.0")
    XCTAssertEqual(bodies.first { $0["device_model"] != nil }?["device_model"] as? String, "iPhone17,1")
    XCTAssertEqual(bodies.first { $0["sdk_version"] != nil }?["sdk_version"] as? String, "0.5.0")
    XCTAssertEqual(bodies.first { $0["timezone_id"] != nil }?["timezone_id"] as? String, "America/Sao_Paulo")
    XCTAssertEqual(bodies.first { $0["language"] != nil }?["language"] as? String, "pt")
    XCTAssertEqual(store.getAppVersion(), "1.2.3")
    XCTAssertEqual(store.getLastSyncedDeviceOs(), "18.0")
    XCTAssertEqual(store.getLastSyncedDeviceModel(), "iPhone17,1")
    XCTAssertEqual(store.getLastSyncedSdkVersion(), "0.5.0")
    XCTAssertEqual(store.getLastSyncedTimezoneId(), "America/Sao_Paulo")
    XCTAssertEqual(store.getLastSyncedLanguage(), "pt")
  }

  func test_onlyAChangedProfileFieldIsResentBetweenTwoRegistrations() {
    StubURLProtocol.enqueue(.echoDevice()) // registration 1
    for _ in 0..<6 { StubURLProtocol.enqueue(.echoDevice()) } // six PATCHes
    StubURLProtocol.enqueue(.echoDevice()) // registration 2
    for _ in 0..<2 { StubURLProtocol.enqueue(.echoDevice()) } // two changed-field PATCHes
    var deviceOs: String? = "18.0"
    var timezone: String? = "America/Sao_Paulo"
    let core = newCore(
      versionProvider: { "1.2.3" },
      deviceOsProvider: { deviceOs },
      deviceModelProvider: { "iPhone17,1" },
      timezoneProvider: { timezone },
      languageProvider: { "pt" }
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl, sdkVersion: "0.5.0")
    drain(core)
    XCTAssertEqual(store.getLastSyncedDeviceOs(), "18.0")

    deviceOs = "19.0"
    timezone = "America/New_York"
    core.onTokenRefreshed("new-apns-token")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    // 8 PATCHes total: six on the first registration + two changed on the second.
    XCTAssertEqual(bodies.count, 8)
    XCTAssertEqual(bodies.last { $0["device_os"] != nil }?["device_os"] as? String, "19.0")
    XCTAssertEqual(bodies.last { $0["timezone_id"] != nil }?["timezone_id"] as? String, "America/New_York")
    XCTAssertEqual(store.getLastSyncedDeviceOs(), "19.0")
    XCTAssertEqual(store.getLastSyncedTimezoneId(), "America/New_York")
    // Unchanged fields keep their synced values.
    XCTAssertEqual(store.getLastSyncedDeviceModel(), "iPhone17,1")
    XCTAssertEqual(store.getLastSyncedSdkVersion(), "0.5.0")
    XCTAssertEqual(store.getLastSyncedLanguage(), "pt")
  }

  func test_aPatchAckThatDoesNotEchoTheFieldLeavesItUnsyncedAndResendsOnTheNextRegistration() {
    // Backend older than the profile-field contract: answers 2xx but ignores
    // the field, so the echo never carries it. Treating that 2xx as synced
    // would stop the SDK from ever sending the value again.
    for _ in 0..<4 { StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) }
    let logs = LogSink()
    let core = newCore(versionProvider: { "1.2.3" }, logs: logs)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    XCTAssertNil(store.getAppVersion())

    core.onTokenRefreshed("new-apns-token")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 2, "the unacked app_version is re-sent on the second registration")
    XCTAssertEqual(bodies[1]["app_version"] as? String, "1.2.3")
    XCTAssertNil(store.getAppVersion())
    XCTAssertTrue(logs.messages.contains { $0.contains("Notti.app_version") && $0.contains("not echoed") })
  }

  func test_aPatchAckEchoingADifferentValueDoesNotMarkTheFieldSynced() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{},"app_version":"1.0.0"}"#)) // PATCH
    let core = newCore(versionProvider: { "1.2.3" })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 2)
    XCTAssertNil(store.getAppVersion())
  }

  func test_aNilProfileProviderOmitsThatFieldWithoutCrashing() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // app_version PATCH only
    // All profile providers default to nil - only versionProvider is set.
    let core = newCore(versionProvider: { "1.2.3" })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["app_version"] as? String, "1.2.3")
    XCTAssertNil(bodies[0]["device_os"])
    XCTAssertNil(bodies[0]["device_model"])
    XCTAssertNil(bodies[0]["sdk_version"])
    XCTAssertNil(bodies[0]["timezone_id"])
    XCTAssertNil(bodies[0]["language"])
  }

  func test_sdkVersionPassedThroughInitializeReachesThePayload() {
    StubURLProtocol.enqueue(.echoDevice()) // registration
    for _ in 0..<3 { StubURLProtocol.enqueue(.echoDevice()) } // device_os + sdk_version + timezone_id
    let core = newCore(deviceOsProvider: { "18.0" }, timezoneProvider: { "UTC" })

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl, sdkVersion: "0.5.0")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 3)
    XCTAssertEqual(bodies.first { $0["sdk_version"] != nil }?["sdk_version"] as? String, "0.5.0")
    XCTAssertEqual(store.getLastSyncedSdkVersion(), "0.5.0")
  }

  // MARK: - Permission status + last_unsubscribed_at (T8, DPF-10..16)

  func test_registrationSuccessSyncsPermissionStatus() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // permission_status PATCH
    let core = newCore(permissionStatusProvider: { cb in cb("granted") })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["permission_status"] as? String, "granted")
    XCTAssertEqual(store.getLastSyncedPermissionStatus(), "granted")
  }

  func test_requestPermissionResultSyncsTheOSPermissionStatus() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // permission_status (notDetermined)
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // subscribed PATCH
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // permission_status (granted)
    var permissionStatus: String? = "notDetermined"
    let core = newCore(
      permissionRequester: { cb in permissionStatus = "granted"; cb(true) },
      permissionStatusProvider: { cb in cb(permissionStatus) }
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let resolved = expectation(description: "permission callback")
    core.requestPermission { _ in resolved.fulfill() }
    wait(for: [resolved], timeout: 15)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertTrue(bodies.contains { $0["subscribed"] as? Bool == true })
    XCTAssertTrue(bodies.contains { $0["permission_status"] as? String == "granted" })
  }

  func test_aGrantedToDeniedSettingsChangeIsCaughtAtTheNextSessionStart() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // permission_status + last_unsubscribed PATCH
    store.setLastSyncedPermissionStatus("granted")
    var permissionStatus: String? = "granted"
    let core = newCore(
      permissionStatusProvider: { cb in cb(permissionStatus) },
      heartbeatInterval: 0
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    StubURLProtocol.reset()

    permissionStatus = "denied"
    let before = Int64(Date().timeIntervalSince1970 * 1000)
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // permission_status + last_unsubscribed PATCH
    core.handleSessionStart(nowMs: 1_000)
    drain(core)
    let after = Int64(Date().timeIntervalSince1970 * 1000)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["permission_status"] as? String, "denied")
    // last_unsubscribed_at is a real "now" timestamp, not an exact value.
    let unsub = store.getLastUnsubscribedAtMs()
    XCTAssertNotNil(unsub)
    XCTAssertGreaterThanOrEqual(unsub ?? 0, before)
    XCTAssertLessThanOrEqual(unsub ?? 0, after)
    XCTAssertEqual(store.getLastSyncedPermissionStatus(), "denied")
  }

  func test_setSubscriptionFalseOnASubscribedDeviceSetsLastUnsubscribedWhilePermissionStaysGranted() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // permission_status PATCH
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // subscribed(false)+last_unsubscribed PATCH
    store.setSubscribed(true)
    let core = newCore(
      permissionStatusProvider: { cb in cb("granted") },
      heartbeatInterval: 0
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    StubURLProtocol.reset()

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // subscribed(false)+last_unsubscribed PATCH
    core.setSubscription(false)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1, "the timestamp must travel in the same PATCH as subscribed (atomic, DPF-14)")
    XCTAssertEqual(bodies[0]["subscribed"] as? Bool, false)
    XCTAssertTrue(bodies[0]["last_unsubscribed_at"] != nil, "true->false must PATCH last_unsubscribed_at")
    XCTAssertNotNil(store.getLastUnsubscribedAtMs())
    XCTAssertFalse(store.getSubscribed())
    // The app opt-out does not touch the OS permission axis (DPF-16).
    XCTAssertFalse(bodies[0]["permission_status"] != nil)
    XCTAssertEqual(store.getLastSyncedPermissionStatus(), "granted")
  }

  func test_reSubscribeDoesNotClearLastUnsubscribedAt() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // permission_status PATCH
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // subscribed(false)+last_unsubscribed PATCH
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // subscribed(true) PATCH
    store.setSubscribed(true)
    let core = newCore(
      permissionStatusProvider: { cb in cb("granted") },
      heartbeatInterval: 0
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setSubscription(false)
    drain(core)
    let recorded = store.getLastUnsubscribedAtMs()
    XCTAssertNotNil(recorded)

    core.setSubscription(true)
    drain(core)

    XCTAssertEqual(store.getLastUnsubscribedAtMs(), recorded, "re-subscribe must not clear the timestamp")
    XCTAssertTrue(store.getSubscribed())
  }

  private func isoUtc(_ epochMs: Int64) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000))
  }

  func test_setSubscriptionFalseWithAnUnknownLocalStateRecordsLastUnsubscribedAt() {
    // F4: the backend registers devices subscribed by default, so a never-
    // acknowledged local state counts as subscribed.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // subscribed(false)
    XCTAssertNil(store.getSubscribedIfKnown())
    let core = newCore(heartbeatInterval: 0)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setSubscription(false)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["subscribed"] as? Bool, false)
    XCTAssertNotNil(bodies[0]["last_unsubscribed_at"], "unknown -> false is a transition")
    XCTAssertNotNil(store.getLastUnsubscribedAtMs())
    XCTAssertNil(store.getPendingUnsubscribeAtMs(), "acknowledged: nothing left pending")
  }

  func test_setSubscriptionFalseWhenAlreadyFalseDoesNotRecordLastUnsubscribedAt() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // subscribed(false)
    store.setSubscribed(false)
    let core = newCore(heartbeatInterval: 0)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setSubscription(false)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertNil(bodies[0]["last_unsubscribed_at"], "false -> false is never a transition")
    XCTAssertNil(store.getLastUnsubscribedAtMs())
  }

  func test_aRetriedSetSubscriptionFalseResendsThePersistedTimestamp() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(400)) // first opt-out: terminal failure
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // retry
    store.setSubscribed(true)
    let core = newCore(heartbeatInterval: 0)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setSubscription(false)
    drain(core)
    let stamped = store.getLastUnsubscribedAtMs()
    XCTAssertNotNil(stamped)
    XCTAssertEqual(store.getPendingUnsubscribeAtMs(), stamped)
    XCTAssertTrue(store.getSubscribed(), "a failed opt-out leaves the local state untouched")

    Thread.sleep(forTimeInterval: 0.01) // a fresh now() would differ
    core.setSubscription(false)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 2)
    XCTAssertEqual(bodies[1]["last_unsubscribed_at"] as? String, isoUtc(stamped!),
                   "the retry must re-send the stamp of the original detection")
    XCTAssertEqual(store.getLastUnsubscribedAtMs(), stamped)
    XCTAssertNil(store.getPendingUnsubscribeAtMs())
    XCTAssertFalse(store.getSubscribed())
  }

  func test_aRetriedPermissionDenialResendsThePersistedTimestamp() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    store.setLastSyncedPermissionStatus("granted")
    var permissionStatus: String? = "granted"
    let core = newCore(
      permissionStatusProvider: { cb in cb(permissionStatus) },
      heartbeatInterval: 0
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    permissionStatus = "denied"
    StubURLProtocol.reset()
    StubURLProtocol.enqueue(.status(400)) // denied PATCH: terminal failure
    core.handleSessionStart(nowMs: 1_000)
    drain(core)
    let stamped = store.getLastUnsubscribedAtMs()
    XCTAssertNotNil(stamped)
    XCTAssertEqual(store.getLastSyncedPermissionStatus(), "granted")

    Thread.sleep(forTimeInterval: 0.01)
    StubURLProtocol.reset()
    StubURLProtocol.enqueue(.status(200)) // orphaned-session telemetry PATCH (closed first)
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // retried denied PATCH
    core.handleSessionStart(nowMs: 2_000)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests()).filter { $0["permission_status"] != nil }
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["permission_status"] as? String, "denied")
    XCTAssertEqual(bodies[0]["last_unsubscribed_at"] as? String, isoUtc(stamped!))
    XCTAssertEqual(store.getLastSyncedPermissionStatus(), "denied")
    XCTAssertNil(store.getPendingPermissionUnsubscribeAtMs())
  }

  func test_aPermissionFlipQueuedBeforeRegistrationSendsOnlyTheFinalState() {
    // F8: denied -> granted both detected before registration. The diff runs
    // at execution time against the acknowledged status, so the stale
    // `{denied, last_unsubscribed_at}` is never sent.
    var deliverToken: ((String?) -> Void)?
    store.setLastSyncedPermissionStatus("granted")
    var permissionStatus: String? = "denied"
    let core = newCore(
      tokenProvider: { cb in deliverToken = cb },
      permissionStatusProvider: { cb in cb(permissionStatus) },
      heartbeatInterval: 0
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    core.handleSessionStart(nowMs: 1_000) // queues the denied read
    drain(core)
    permissionStatus = "granted"
    core.handleSessionStart(nowMs: 2_000) // coalesces onto it with granted
    drain(core)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    for _ in 0..<5 { StubURLProtocol.enqueue(.status(200)) }
    deliverToken?("apns-token")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertFalse(bodies.contains { $0["permission_status"] as? String == "denied" })
    XCTAssertTrue(bodies.allSatisfy { $0["last_unsubscribed_at"] == nil })
    XCTAssertNil(store.getLastUnsubscribedAtMs())
    XCTAssertEqual(store.getLastSyncedPermissionStatus(), "granted")
  }

  func test_aGrantedPermissionResultClearsAStaleUnackedUnsubscribeStamp() {
    // A failed opt-out at T1, then a granted requestPermission re-subscribes:
    // the T1 transition is moot, so a later opt-out at T2 must carry T2.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(400)) // setSubscription(false) at T1: terminal failure
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // permission-result subscribed(true)
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // setSubscription(false) at T2
    store.setSubscribed(true)
    let core = newCore(permissionRequester: { cb in cb(true) }, heartbeatInterval: 0)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setSubscription(false)
    drain(core)
    let t1 = store.getPendingUnsubscribeAtMs()
    XCTAssertNotNil(t1)

    let expectation = expectation(description: "permission callback")
    core.requestPermission { _ in expectation.fulfill() }
    wait(for: [expectation], timeout: 15)
    drain(core)
    XCTAssertNil(store.getPendingUnsubscribeAtMs(), "a granted re-subscribe makes the pending opt-out moot")
    XCTAssertTrue(store.getSubscribed())

    Thread.sleep(forTimeInterval: 0.01) // T2 must differ from T1
    let t2Floor = Int64(Date().timeIntervalSince1970 * 1000)
    core.setSubscription(false)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 3)
    let sent = bodies[2]["last_unsubscribed_at"] as? String
    XCTAssertNotNil(sent)
    XCTAssertNotEqual(sent, isoUtc(t1!), "the stale T1 stamp must not be re-sent")
    let stamped = store.getLastUnsubscribedAtMs()
    XCTAssertNotNil(stamped)
    XCTAssertGreaterThanOrEqual(stamped!, t2Floor)
    XCTAssertEqual(sent, isoUtc(stamped!))
    XCTAssertNil(store.getPendingUnsubscribeAtMs())
  }

  func test_anUnknownPermissionReadLeavesAPendingDenialStampUntouched() {
    // A nil (unknown / @unknown default) read is neither a reversal nor a new
    // denial: the field is omitted and a pending granted->denied stamp stays.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    for _ in 0..<3 { StubURLProtocol.enqueue(.status(200)) } // session telemetry
    store.setLastSyncedPermissionStatus("granted")
    store.setPendingPermissionUnsubscribeAtMs(1_234)
    let core = newCore(permissionStatusProvider: { cb in cb(nil) }, heartbeatInterval: 0)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl) // registration-success read
    drain(core)
    core.handleSessionStart(nowMs: 1_000) // session-start read
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertFalse(bodies.contains { $0["permission_status"] != nil }, "a nil status must be omitted")
    XCTAssertFalse(bodies.contains { $0["last_unsubscribed_at"] != nil })
    XCTAssertEqual(store.getPendingPermissionUnsubscribeAtMs(), 1_234)
    XCTAssertEqual(store.getLastSyncedPermissionStatus(), "granted")
  }

  func test_twoDeniedReadsBeforeRegistrationStampTheFirstDetection() {
    // Pre-registration reads coalesce by replacing the queued closure; the
    // stamp is persisted at the first detection, so it is never the last read.
    var deliverToken: ((String?) -> Void)?
    store.setLastSyncedPermissionStatus("granted")
    let core = newCore(
      tokenProvider: { cb in deliverToken = cb },
      permissionStatusProvider: { cb in cb("denied") },
      heartbeatInterval: 0
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    core.handleSessionStart(nowMs: 1_000) // first denied read
    drain(core)
    let first = store.getPendingPermissionUnsubscribeAtMs()
    XCTAssertNotNil(first, "the stamp is persisted at detection, before any PATCH")

    Thread.sleep(forTimeInterval: 0.01) // a second detection time would differ
    core.handleSessionStart(nowMs: 2_000) // second denied read, coalesced
    drain(core)
    XCTAssertEqual(store.getPendingPermissionUnsubscribeAtMs(), first)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    for _ in 0..<5 { StubURLProtocol.enqueue(.status(200)) }
    deliverToken?("apns-token")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests()).filter { $0["permission_status"] != nil }
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["permission_status"] as? String, "denied")
    XCTAssertEqual(bodies[0]["last_unsubscribed_at"] as? String, isoUtc(first!))
    XCTAssertEqual(store.getLastUnsubscribedAtMs(), first)
    XCTAssertEqual(store.getLastSyncedPermissionStatus(), "denied")
    XCTAssertNil(store.getPendingPermissionUnsubscribeAtMs(), "cleared on the 2xx")
  }

  func test_aDeniedGrantedDeniedFlipBeforeRegistrationStampsTheThirdRead() {
    // The granted read in the middle is a reversal: it drops the first stamp,
    // so the re-denial gets a fresh one (parity with Android).
    var deliverToken: ((String?) -> Void)?
    store.setLastSyncedPermissionStatus("granted")
    var permissionStatus: String? = "denied"
    let core = newCore(
      tokenProvider: { cb in deliverToken = cb },
      permissionStatusProvider: { cb in cb(permissionStatus) },
      heartbeatInterval: 0
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    core.handleSessionStart(nowMs: 1_000) // read 1: denied
    drain(core)
    let first = store.getPendingPermissionUnsubscribeAtMs()
    XCTAssertNotNil(first)

    permissionStatus = "granted"
    core.handleSessionStart(nowMs: 2_000) // read 2: granted (reversal)
    drain(core)
    XCTAssertNil(store.getPendingPermissionUnsubscribeAtMs(), "the reversal drops the first stamp")

    Thread.sleep(forTimeInterval: 0.01) // the third detection time must differ
    permissionStatus = "denied"
    core.handleSessionStart(nowMs: 3_000) // read 3: denied again
    drain(core)
    let third = store.getPendingPermissionUnsubscribeAtMs()
    XCTAssertNotNil(third)
    XCTAssertNotEqual(third, first)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    for _ in 0..<5 { StubURLProtocol.enqueue(.status(200)) }
    deliverToken?("apns-token")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests()).filter { $0["permission_status"] != nil }
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["permission_status"] as? String, "denied")
    XCTAssertEqual(bodies[0]["last_unsubscribed_at"] as? String, isoUtc(third!))
    XCTAssertEqual(store.getLastUnsubscribedAtMs(), third)
    XCTAssertEqual(store.getLastSyncedPermissionStatus(), "denied")
    XCTAssertNil(store.getPendingPermissionUnsubscribeAtMs())
  }

  func test_normalizedLanguageCodeKeepsOnlyTheIso6391PrimarySubtag() {
    XCTAssertEqual(NottiCore.normalizedLanguageCode("pt"), "pt")
    XCTAssertEqual(NottiCore.normalizedLanguageCode("pt-BR"), "pt")
    XCTAssertEqual(NottiCore.normalizedLanguageCode("EN_us"), "en")
    XCTAssertNil(NottiCore.normalizedLanguageCode(""))
    XCTAssertNil(NottiCore.normalizedLanguageCode("und"))
    XCTAssertNil(NottiCore.normalizedLanguageCode(nil))
  }

  func test_anUnknownPermissionStatusIsOmittedWithoutCrashing() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration only
    let core = newCore(permissionStatusProvider: { cb in cb(nil) })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertTrue(bodies.isEmpty, "a nil permission status must not be fabricated")
    XCTAssertNil(store.getLastSyncedPermissionStatus())
  }

  func test_aPermissionStatusReadThatResolvesAfterAReinitializePatchesTheCurrentApiClient() {
    // L2-class guard (final review finding): the OS permission read is async
    // and can outlive a second `initialize()` with a different appId/baseUrl
    // that replaced `apiClient`. The PATCH must go to the NEW backend, never
    // the stale one - same rule Android's `runOrQueue` and iOS's
    // `sendCountryIfChanged` enforce.
    var permissionCallbacks: [(String?) -> Void] = []
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration (app-1)
    let core = newCore(
      permissionStatusProvider: { cb in permissionCallbacks.append(cb) },
      heartbeatInterval: 0
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    XCTAssertEqual(permissionCallbacks.count, 1)

    // A second initialize with a different app/baseUrl swaps apiClient while
    // the first permission read is still pending.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-2","tags":{}}"#)) // re-registration (app-2)
    let secondBaseUrl = "https://notti-other.example.com"
    core.initialize(appId: "app-2", clientKey: "key", baseUrl: secondBaseUrl)
    drain(core)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-2","tags":{}}"#)) // permission PATCH
    // Fire the FIRST registration's pending read, long after apiClient moved on.
    permissionCallbacks[0]("granted")
    drain(core)

    let requests = StubURLProtocol.recordedRequests()
    let permissionPatch = requests.last!
    XCTAssertEqual(permissionPatch.httpMethod, "PATCH")
    XCTAssertEqual(
      permissionPatch.url?.host, "notti-other.example.com",
      "the async permission read must resolve against the current apiClient, not the stale one"
    )
  }

  // MARK: - First-class email/phone (T9, DPF-17..21)

  func test_setEmailEnqueuesAPatchWithEmailAndNeverTouchesTags() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // email PATCH
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setEmail("user@example.com")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["email"] as? String, "user@example.com")
    XCTAssertNil(bodies[0]["tags"], "email must travel as its own field, never merged into tags (DPF-21)")
    XCTAssertEqual(store.getEmail(), "user@example.com")
  }

  func test_clearEmailEnqueuesAnExplicitEmailNullClear() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // email clear PATCH
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.clearEmail()
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertTrue(bodies[0]["email"] is NSNull, "clear must send an explicit email null")
    XCTAssertNil(store.getEmail())
  }

  func test_setEmailTwiceWithTheSameValueEnqueuesASingleMutation() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // email PATCH
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setEmail("user@example.com")
    drain(core)
    XCTAssertEqual(store.getEmail(), "user@example.com")

    core.setEmail("user@example.com")
    drain(core)

    // register POST + exactly one email PATCH - the duplicate set is a no-op
    // (DPF-20 idempotence, matching addTag).
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 2)
    XCTAssertEqual(store.getEmail(), "user@example.com")
  }

  func test_setPhoneEnqueuesAPatchWithPhone() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // phone PATCH
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setPhone("+5511999999999")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["phone"] as? String, "+5511999999999")
    XCTAssertEqual(store.getPhone(), "+5511999999999")
  }

  func test_registrationSuccessResendsAHeldEmailAndPhone() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // email PATCH
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // phone PATCH
    store.setEmail("held@example.com")
    store.setPhone("+10000000000")
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 2)
    XCTAssertTrue(bodies.contains { $0["email"] as? String == "held@example.com" })
    XCTAssertTrue(bodies.contains { $0["phone"] as? String == "+10000000000" })
  }

  func test_setEmailBeforeInitializeIsPersistedAndResentOnRegistration() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // email PATCH
    let core = newCore()
    core.setEmail("preinit@example.com")
    drain(core)
    XCTAssertEqual(store.getEmail(), "preinit@example.com", "pre-init email must be persisted, not dropped (DPF-19)")

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertTrue(bodies.contains { $0["email"] as? String == "preinit@example.com" },
                  "held pre-init email must be re-sent after registration (DPF-19)")
  }

  func test_clearEmailBeforeInitializeOfASyncedValueIsSentAsNullAtRegistration() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // email null
    store.setEmail("stale@example.com") // held + acknowledged in a previous session
    store.setLastSyncedEmail("stale@example.com")
    let core = newCore()
    core.clearEmail()
    drain(core)
    XCTAssertNil(store.getEmail(), "pre-init clear must persist nil (DPF-18)")

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertTrue(bodies[0]["email"] is NSNull,
                  "a pre-init clear of a synced email must reach the backend as an explicit null (F1)")
    XCTAssertNil(store.getLastSyncedEmail())
    XCTAssertNil(store.getEmail(), "the cleared value must never be re-sent as a set")
  }

  func test_clearEmailBeforeInitializeOfANeverSyncedValueSendsNothing() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration only
    store.setEmail("never-synced@example.com")
    let core = newCore()
    core.clearEmail()
    drain(core)

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertTrue(patchBodies(StubURLProtocol.recordedRequests()).isEmpty,
                  "held nil + nothing acknowledged: nothing to clear server-side")
  }

  func test_aFailedClearIsResentAsNullAtTheNextRegistration() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // email set
    StubURLProtocol.enqueue(.status(400)) // email clear: terminal failure, single attempt
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    core.setEmail("user@example.com")
    drain(core)
    XCTAssertEqual(store.getLastSyncedEmail(), "user@example.com")

    core.clearEmail()
    drain(core)
    XCTAssertNil(store.getEmail())
    XCTAssertEqual(store.getLastSyncedEmail(), "user@example.com", "a failed clear must stay owed")

    StubURLProtocol.reset()
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // re-registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // email null resync
    core.onTokenRefreshed("apns-token-2")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertTrue(bodies[0]["email"] is NSNull)
    XCTAssertNil(store.getLastSyncedEmail())
  }

  func test_setEmailWithTheSameValueAfterAFailedPatchReEnqueuesIt() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(400)) // first set: terminal failure
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // retry set
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setEmail("user@example.com")
    drain(core)
    XCTAssertNil(store.getLastSyncedEmail())

    core.setEmail("user@example.com")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 2, "held == value but never acknowledged: the repeat is not a no-op")
    XCTAssertEqual(bodies[1]["email"] as? String, "user@example.com")
    XCTAssertEqual(store.getLastSyncedEmail(), "user@example.com")
  }

  func test_aSetAckedAfterANewerClearStillLeavesTheClearResendable() {
    // A clear issued while the older set's PATCH is in flight (simulated by
    // the hook) whose own PATCH then fails: the set's 2xx must still record
    // lastSynced = set value, so the next registration re-sends the null.
    let heldStore: NottiDeviceStore = store
    var clearAttempts = 0
    var bodies: [[String: Any]] = []
    let client = PatchHookApiClient { fields in
      bodies.append(fields)
      if fields["email"] as? String == "old@example.com" {
        heldStore.setEmail(nil) // the newer clear's local write lands mid-flight
      }
      if fields["email"] is NSNull {
        clearAttempts += 1
        return clearAttempts > 1 // first clear PATCH fails, the resync succeeds
      }
      return true
    }
    let core = newCore(apiClient: client)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setEmail("old@example.com")
    core.clearEmail()
    drain(core)
    XCTAssertNil(store.getEmail())
    XCTAssertEqual(store.getLastSyncedEmail(), "old@example.com",
                   "the set's ack is recorded even though a newer clear was issued")

    core.onTokenRefreshed("apns-token-2") // next registration
    drain(core)

    XCTAssertEqual(clearAttempts, 2, "the failed clear is re-sent at registration")
    XCTAssertTrue(bodies.last?["email"] is NSNull)
    XCTAssertNil(store.getLastSyncedEmail())
  }

  func test_setEmailThenLogoutLoginAndANewEmailConvergesOnTheNewEmail() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    for _ in 0..<6 { StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) }
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    core.setEmail("a@example.com")
    drain(core)
    XCTAssertEqual(store.getLastSyncedEmail(), "a@example.com")

    core.logout()
    core.login("u2")
    core.setEmail("b@example.com")
    drain(core)

    let emailBodies = patchBodies(StubURLProtocol.recordedRequests()).filter { $0.keys.contains("email") }
    XCTAssertEqual(emailBodies.last?["email"] as? String, "b@example.com")
    let lastB = emailBodies.lastIndex { $0["email"] as? String == "b@example.com" }!
    XCTAssertFalse(emailBodies[lastB...].contains { $0["email"] is NSNull }, "no null clear may land after b")
    XCTAssertTrue(emailBodies[..<lastB].contains { $0["email"] is NSNull }, "logout still cleared a server-side")
    XCTAssertEqual(store.getEmail(), "b@example.com")
    XCTAssertEqual(store.getLastSyncedEmail(), "b@example.com")
    XCTAssertEqual(store.getExternalUserId(), "u2")
  }

  func test_registrationSuccessWithNoHeldEmailOrPhoneSendsNothingForThem() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration only
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertTrue(bodies.isEmpty, "null held values are never sent (DPF-19)")
  }

  // MARK: - Session lifecycle (T8, SEGTEL-05/06/07/08/09)

  func test_sessionStartThenEndIncrementsCountAddsElapsedTimeAndPatchesTheSnapshot() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // session PATCH
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.handleSessionStart(nowMs: 1_000)
    drain(core)
    core.handleSessionEnd(nowMs: 31_000)
    drain(core)

    XCTAssertEqual(store.getSessionCount(), 1)
    XCTAssertEqual(store.getSessionTimeMs(), 30_000)
    XCTAssertEqual(store.getLastSessionAtMs(), 31_000)
    XCTAssertNil(store.getSessionStartedAtMs())

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    let snapshot = bodies[0]
    XCTAssertEqual(snapshot["session_count"] as? Int, 1)
    XCTAssertEqual(snapshot["session_time_seconds"] as? Int, 30)
    XCTAssertEqual(snapshot["first_session_at"] as? String, "1970-01-01T00:00:01.000Z")
    XCTAssertEqual(snapshot["last_session_at"] as? String, "1970-01-01T00:00:31.000Z")
  }

  func test_uncleanKillIsClosedAtTheLastKnownForegroundTimestampAtTheNextSessionStart() {
    // Review item 4 / SEGTEL-08: the missed session ends at its last
    // heartbeat (last time the app was *known* foreground), not at the next
    // launch - the old `now - startedAt` counted all the dead time as usage.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // missed-session PATCH
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.handleSessionStart(nowMs: 1_000)
    core.recordHeartbeat(nowMs: 31_000)
    drain(core)
    // Process killed while foreground: no background transition. Next launch,
    // hours later:
    core.handleSessionStart(nowMs: 7_200_000)
    drain(core)

    // The missed session is closed once: 30s of known foreground, count 1.
    XCTAssertEqual(store.getSessionCount(), 1)
    XCTAssertEqual(store.getSessionTimeMs(), 30_000)
    XCTAssertEqual(store.getLastSessionAtMs(), 31_000)
    // ... and a fresh session is now open.
    XCTAssertEqual(store.getSessionStartedAtMs(), 7_200_000)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["session_count"] as? Int, 1)
    XCTAssertEqual(bodies[0]["session_time_seconds"] as? Int, 30)
  }

  func test_anOrphanedSessionWithoutAHeartbeatIsCountedWithZeroDurationNotInflated() {
    // State persisted by an SDK version that had no heartbeat: never guess
    // `now - startedAt` (could be days).
    store.setSessionStartedAtMs(1_000)
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // missed-session PATCH
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.handleSessionStart(nowMs: 5 * 24 * 3_600_000)
    drain(core)

    XCTAssertEqual(store.getSessionCount(), 1)
    XCTAssertEqual(store.getSessionTimeMs(), 0)
  }

  func test_theHeartbeatTimerPersistsTheLastForegroundTimestampAndStopsOnBackground() {
    let core = newCore(heartbeatInterval: 0.05)
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(core)
    let startedAt = store.getSessionStartedAtMs()
    XCTAssertNotNil(startedAt)

    Thread.sleep(forTimeInterval: 0.4)
    drain(core)
    XCTAssertGreaterThan(store.getSessionLastSeenAtMs() ?? 0, startedAt ?? .max, "heartbeat must advance while foreground")

    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    drain(core)
    Thread.sleep(forTimeInterval: 0.2)
    drain(core)
    XCTAssertNil(store.getSessionStartedAtMs())
    XCTAssertNil(store.getSessionLastSeenAtMs(), "no heartbeat may be written after the session ended")
  }

  func test_sessionEndWithNoActiveSessionIsANoOp() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    XCTAssertNil(store.getSessionStartedAtMs())

    core.handleSessionEnd(nowMs: 5_000)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1, "no session PATCH without an active session")
    XCTAssertEqual(store.getSessionCount(), 0)
    XCTAssertEqual(store.getSessionTimeMs(), 0)
    XCTAssertNil(store.getLastSessionAtMs())
  }

  func test_firstSessionAtIsSetOnceAndNeverOverwritten() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // session 1 PATCH
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.handleSessionStart(nowMs: 1_000)
    drain(core)
    XCTAssertEqual(store.getFirstSessionAtMs(), 1_000)

    core.handleSessionEnd(nowMs: 2_000)
    drain(core)
    core.handleSessionStart(nowMs: 5_000)
    drain(core)

    XCTAssertEqual(store.getFirstSessionAtMs(), 1_000, "first_session_at is set once, never overwritten")
    XCTAssertEqual(store.getSessionStartedAtMs(), 5_000)
  }

  // MARK: - Location opt-in country (T9, SEGTEL-10..15)

  func test_locationSharingOffNeverReadsCountryEvenWithPermissionGranted() {
    var countryReads = 0
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    let core = newCore(
      hasLocationPermission: { true },
      countryProvider: { cb in countryReads += 1; cb("BR") }
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.handleSessionStart(nowMs: 1_000)
    drain(core)

    XCTAssertEqual(countryReads, 0, "opt-in off must never read country, even with permission granted")
    XCTAssertFalse(store.getLocationSharingEnabled())
    XCTAssertTrue(
      StubURLProtocol.recordedRequests().allSatisfy { $0.httpMethod == "POST" },
      "no country PATCH may be issued with location sharing off"
    )
  }

  func test_locationSharingOnWithoutOSPermissionNeverReadsCountry() {
    var countryReads = 0
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    let core = newCore(
      hasLocationPermission: { false },
      countryProvider: { cb in countryReads += 1; cb("BR") }
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setLocationSharingEnabled(true)
    drain(core)
    XCTAssertTrue(store.getLocationSharingEnabled())

    core.handleSessionStart(nowMs: 1_000)
    drain(core)

    // Opt-in on but the OS has not granted permission: the read is gated
    // before the provider is ever invoked, and no country field is sent
    // (SEGTEL-12) - the SDK never requests permission itself (SEGTEL-14).
    XCTAssertEqual(countryReads, 0, "provider must not be invoked without OS permission")
    XCTAssertTrue(
      StubURLProtocol.recordedRequests().allSatisfy { $0.httpMethod == "POST" },
      "no country PATCH may be issued without OS location permission"
    )
  }

  func test_locationSharingOnWithPermissionAndAReadSendsCountryOnSessionStart() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    let core = newCore(
      hasLocationPermission: { true },
      countryProvider: { cb in cb("BR") }
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setLocationSharingEnabled(true)
    drain(core)
    XCTAssertTrue(store.getLocationSharingEnabled())
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1, "enabling sends no immediate request")

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // country PATCH
    core.handleSessionStart(nowMs: 1_000)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["country"] as? String, "BR")
  }

  func test_disablingLocationSharingEnqueuesAnExplicitCountryClear() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    let core = newCore()
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setLocationSharingEnabled(true)
    drain(core)
    XCTAssertTrue(store.getLocationSharingEnabled())

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // country clear PATCH
    core.setLocationSharingEnabled(false)
    drain(core)

    XCTAssertFalse(store.getLocationSharingEnabled())
    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertTrue(bodies[0].keys.contains("country"), "opt-out must PATCH country, not merely omit it")
    XCTAssertTrue(bodies[0]["country"] is NSNull, "opt-out must send an explicit null clear")
  }

  func test_aNilCountryReadOmitsTheFieldWithoutCrashing() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    let core = newCore(
      hasLocationPermission: { true },
      countryProvider: { cb in cb(nil) }
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    core.setLocationSharingEnabled(true)
    drain(core)
    core.handleSessionStart(nowMs: 1_000)
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertTrue(bodies.allSatisfy { $0["country"] == nil }, "a nil read must omit country entirely")
  }

  // MARK: - Pre-release review fixes (iOS)

  private func registeredCore(
    hasLocationPermission: @escaping () -> Bool = { false },
    countryProvider: @escaping (@escaping (String?) -> Void) -> Void = { $0(nil) },
    eventStore: NottiEventStore? = nil,
    logs: LogSink? = nil
  ) -> NottiCore {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    let core = newCore(
      hasLocationPermission: hasLocationPermission,
      countryProvider: countryProvider,
      logs: logs,
      eventStore: eventStore
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)
    XCTAssertEqual(store.getDeviceId(), "device-1")
    return core
  }

  private func countryBodies() -> [[String: Any]] {
    patchBodies(StubURLProtocol.recordedRequests()).filter { $0.keys.contains("country") }
  }

  // Item 1 (LGPD): the opt-out clear is a persisted obligation.

  func test_optOutBeforeInitializeStillClearsCountryOnceRegistrationCompletes() {
    // Previous launch had opted in and synced "BR".
    store.setLocationSharingEnabled(true)
    store.setLastSyncedCountry("BR")
    let core = newCore()

    core.setLocationSharingEnabled(false)
    drain(core)
    XCTAssertTrue(StubURLProtocol.recordedRequests().isEmpty)
    XCTAssertTrue(store.getPendingCountryClear(), "the clear must be persisted, not discarded")

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200)) // country clear
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    let bodies = countryBodies()
    XCTAssertEqual(bodies.count, 1)
    XCTAssertTrue(bodies[0]["country"] is NSNull)
    XCTAssertFalse(store.getPendingCountryClear(), "lowered only after the 2xx")
    XCTAssertNil(store.getLastSyncedCountry())
  }

  func test_aCountryClearThatFailsOfflineOr5xxStaysPendingUntilA2xx() {
    let core = registeredCore()
    core.setLocationSharingEnabled(true)
    drain(core)

    for _ in 0..<5 { StubURLProtocol.enqueue(.networkError()) } // offline
    core.setLocationSharingEnabled(false)
    drain(core)
    XCTAssertEqual(countryBodies().count, 5)
    XCTAssertTrue(store.getPendingCountryClear(), "offline: clear stays pending")

    for _ in 0..<5 { StubURLProtocol.enqueue(.status(503)) } // backend down
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(core)
    XCTAssertEqual(countryBodies().count, 10, "foreground re-sends the pending clear")
    XCTAssertTrue(store.getPendingCountryClear(), "5xx: clear stays pending")

    StubURLProtocol.enqueue(.status(200))
    core.onNetworkAvailable()
    drain(core)
    let bodies = countryBodies()
    XCTAssertEqual(bodies.count, 11, "network regain re-sends the pending clear")
    XCTAssertTrue(bodies.allSatisfy { $0["country"] is NSNull })
    XCTAssertFalse(store.getPendingCountryClear())

    // Nothing left to do: later triggers send nothing more.
    core.onNetworkAvailable()
    drain(core)
    XCTAssertEqual(countryBodies().count, 11)
  }

  // Final review C: consent coming back after a clear whose ack was lost.

  func test_reOptInAfterAFailedClearForgetsTheSyncedCountryAndResendsIt() {
    let core = registeredCore(hasLocationPermission: { true }, countryProvider: { cb in cb("BR") })
    core.setLocationSharingEnabled(true)
    drain(core)
    StubURLProtocol.enqueue(.status(200)) // country BR
    core.handleSessionStart(nowMs: 1_000)
    drain(core)
    XCTAssertEqual(store.getLastSyncedCountry(), "BR")

    // Opt-out whose clear never gets acknowledged (it may or may not have
    // reached the server - the ack is what is lost).
    for _ in 0..<5 { StubURLProtocol.enqueue(.networkError()) }
    core.setLocationSharingEnabled(false)
    drain(core)
    XCTAssertTrue(store.getPendingCountryClear())
    XCTAssertEqual(store.getLastSyncedCountry(), "BR", "nothing acknowledged yet")

    // Consent comes back: the pending clear is superseded and the synced
    // value forgotten, so the same country is sent again.
    core.setLocationSharingEnabled(true)
    drain(core)
    XCTAssertFalse(store.getPendingCountryClear())
    XCTAssertNil(store.getLastSyncedCountry(), "the server may have dropped BR - never assume it is still there")

    StubURLProtocol.enqueue(.status(200)) // orphan close of the session open since 1_000
    StubURLProtocol.enqueue(.status(200)) // country BR again
    core.handleSessionStart(nowMs: 1_000 + NottiCore.minCountryReadIntervalMs)
    drain(core)
    let countries = countryBodies().compactMap { $0["country"] as? String }
    XCTAssertEqual(countries, ["BR", "BR"], "the unchanged country is re-sent after re-consent")
    XCTAssertEqual(store.getLastSyncedCountry(), "BR")
  }

  // Final review D: a permanently rejected clear gets its own log line.

  func test_aCountryClearRejectedWithAPermanent4xxLogsDistinctlyAndStaysPending() {
    for status in [401, 403, 404] {
      StubURLProtocol.reset()
      let logs = LogSink()
      store.setPendingCountryClear(false)
      store.setLocationSharingEnabled(false)
      let core = registeredCore(logs: logs)
      core.setLocationSharingEnabled(true)
      drain(core)

      StubURLProtocol.enqueue(.status(status))
      core.setLocationSharingEnabled(false)
      drain(core)

      XCTAssertEqual(countryBodies().count, 1, "a 4xx is not retried inline (HTTP \(status))")
      XCTAssertTrue(store.getPendingCountryClear(), "still pending, re-sent on the next trigger (HTTP \(status))")
      let rejected = logs.messages.filter { $0.contains("country clear rejected permanently") }
      XCTAssertEqual(rejected.count, 1, "distinct log for HTTP \(status): \(logs.messages)")
      XCTAssertTrue(rejected.first?.contains("HTTP \(status)") ?? false)
      XCTAssertFalse(rejected.first?.contains("device-1") ?? true, "no identifiers in the log")
      XCTAssertFalse(logs.messages.contains { $0.contains("country clear failed") }, "not the generic line")

      // Trigger-based resend is unchanged.
      StubURLProtocol.enqueue(.status(200))
      core.onNetworkAvailable()
      drain(core)
      XCTAssertEqual(countryBodies().count, 2)
      XCTAssertFalse(store.getPendingCountryClear())
    }
  }

  func test_aTransientClearFailureKeepsTheGenericLog() {
    let logs = LogSink()
    let core = registeredCore(logs: logs)
    core.setLocationSharingEnabled(true)
    drain(core)
    for _ in 0..<5 { StubURLProtocol.enqueue(.status(429)) }
    core.setLocationSharingEnabled(false)
    drain(core)
    XCTAssertTrue(logs.messages.contains { $0.contains("country clear failed") })
    XCTAssertFalse(logs.messages.contains { $0.contains("rejected permanently") })
  }

  func test_optOutWithoutAPriorOptInOrSyncedCountrySendsNothing() {
    let core = registeredCore()

    core.setLocationSharingEnabled(false)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1, "registration only")
    XCTAssertFalse(store.getPendingCountryClear())
  }

  // Item 9: a country in flight / queued never lands after an opt-out.

  func test_aCountryQueuedBeforeRegistrationIsNeverSentAfterAnOptOut() {
    var deliverToken: ((String?) -> Void)?
    let core = newCore(
      tokenProvider: { cb in deliverToken = cb },
      hasLocationPermission: { true },
      countryProvider: { cb in cb("BR") }
    )
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    core.setLocationSharingEnabled(true)
    core.handleSessionStart(nowMs: 1_000) // country "BR" read -> queued (not registered yet)
    core.setLocationSharingEnabled(false)
    drain(core)
    XCTAssertTrue(StubURLProtocol.recordedRequests().isEmpty)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200)) // country clear
    deliverToken?("apns-token")
    drain(core)

    let bodies = countryBodies()
    XCTAssertEqual(bodies.count, 1, "only the clear; the queued BR must be dropped at execution time")
    XCTAssertTrue(bodies[0]["country"] is NSNull)
    XCTAssertFalse(store.getPendingCountryClear())
  }

  func test_aCountryReadResolvingAfterAnOptOutIsNotWritten() {
    var resolveCountry: ((String?) -> Void)?
    let core = registeredCore(hasLocationPermission: { true }, countryProvider: { cb in resolveCountry = cb })
    core.setLocationSharingEnabled(true)
    core.handleSessionStart(nowMs: 1_000)
    drain(core)
    XCTAssertNotNil(resolveCountry)

    StubURLProtocol.enqueue(.status(200)) // country clear
    core.setLocationSharingEnabled(false)
    drain(core)
    resolveCountry?("BR")
    drain(core)

    let bodies = countryBodies()
    XCTAssertEqual(bodies.count, 1)
    XCTAssertTrue(bodies[0]["country"] is NSNull)
  }

  // Minor: country diff + geocoder throttling.

  func test_anUnchangedCountryIsNotPatchedAgainAndReadsAreThrottled() {
    var reads = 0
    let core = registeredCore(hasLocationPermission: { true }, countryProvider: { cb in reads += 1; cb("BR") })
    core.setLocationSharingEnabled(true)
    drain(core)

    StubURLProtocol.enqueue(.status(200)) // country BR
    StubURLProtocol.enqueue(.status(200)) // session 1 PATCH
    StubURLProtocol.enqueue(.status(200)) // session 2 PATCH
    core.handleSessionStart(nowMs: 1_000)
    core.handleSessionEnd(nowMs: 2_000)
    core.handleSessionStart(nowMs: 3_000) // within the throttle window: no read
    core.handleSessionEnd(nowMs: 4_000)
    core.handleSessionStart(nowMs: 1_000 + NottiCore.minCountryReadIntervalMs) // read, same country
    drain(core)

    XCTAssertEqual(reads, 2, "one geocode per throttle window")
    XCTAssertEqual(countryBodies().count, 1, "an unchanged country is not re-sent")
    XCTAssertEqual(store.getLastSyncedCountry(), "BR")
  }

  // Item 2: the cold-start session.

  func test_aCoreCreatedWhileTheAppIsAlreadyActiveOpensTheColdStartSession() {
    let core = newCore(appStateProvider: { $0(true) })
    drain(core)
    let startedAt = store.getSessionStartedAtMs()
    XCTAssertNotNil(startedAt, "the launch didBecomeActive fired before the core existed")
    XCTAssertNotNil(store.getFirstSessionAtMs())

    // The (late or real) notification must not restart the open session.
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(core)
    XCTAssertEqual(store.getSessionStartedAtMs(), startedAt)
    XCTAssertEqual(store.getSessionCount(), 0)
  }

  // Final review A: a JS reload while foreground re-creates the core in the
  // same process; the new core must adopt the open session, not close it as
  // an orphan of a killed process.

  func test_aCoreRecreatedByAJsReloadWhileForegroundAdoptsTheOpenSessionInsteadOfClosingIt() {
    let gate = NottiCore.SessionGate()
    var first: NottiCore? = newCore(appStateProvider: { $0(true) }, sessionGate: gate)
    drain(first!)
    let startedAt = store.getSessionStartedAtMs()
    XCTAssertNotNil(startedAt)
    // RN bridge torn down (invalidate) and the old core released, as on reload.
    cores.removeAll { $0 === first }
    weak var releasedFirst = first
    first = nil
    XCTAssertNil(releasedFirst, "the old core must be gone so only the new one observes lifecycle")

    // Same process, app still active: the new core sees `.active` at birth.
    let second = newCore(appStateProvider: { $0(true) }, sessionGate: gate)
    drain(second)
    XCTAssertEqual(store.getSessionCount(), 0, "a reload must not close the open session as an orphan")
    XCTAssertEqual(store.getSessionStartedAtMs(), startedAt, "the open session is adopted, not reopened")

    // The real background ends that one session exactly once ...
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    drain(second)
    XCTAssertEqual(store.getSessionCount(), 1, "two cores in one process => session_count +1 only")
    XCTAssertNil(store.getSessionStartedAtMs())

    // ... and the next foreground is a genuinely new session again.
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(second)
    XCTAssertNotNil(store.getSessionStartedAtMs())
    XCTAssertEqual(store.getSessionCount(), 1, "a fresh start after background closes nothing")
  }

  func test_anInvalidatedCoreThatIsStillAliveNoLongerReactsToLifecycle() {
    // The torn-down module may outlive the reload for a while; it must not
    // also end the session (two work queues racing on the same counters).
    // Deterministic form: with only the invalidated core alive, a background
    // must leave the session untouched for the next core to adopt/end.
    let core = newCore(appStateProvider: { $0(true) })
    drain(core)
    let startedAt = store.getSessionStartedAtMs()
    XCTAssertNotNil(startedAt)

    core.invalidate()
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    drain(core)
    XCTAssertEqual(store.getSessionCount(), 0, "an invalidated core must not end the session")
    XCTAssertEqual(store.getSessionStartedAtMs(), startedAt)
  }

  func test_anOpenSessionLeftByAKilledProcessIsStillClosedAsAnOrphanOnColdStart() {
    // A fresh gate = a new process: the persisted session really is an orphan.
    store.setSessionStartedAtMs(1_000)
    store.setSessionLastSeenAtMs(31_000)
    let core = newCore(appStateProvider: { $0(true) }, sessionGate: NottiCore.SessionGate())
    drain(core)
    XCTAssertEqual(store.getSessionCount(), 1)
    XCTAssertEqual(store.getSessionTimeMs(), 30_000)
    XCTAssertNotEqual(store.getSessionStartedAtMs(), 1_000, "a new session is open")
  }

  func test_aCoreCreatedInBackgroundDoesNotOpenASession() {
    let core = newCore(appStateProvider: { $0(false) })
    drain(core)
    XCTAssertNil(store.getSessionStartedAtMs())
  }

  // Item 3: lifecycle timestamps come from the callback, not the queue.

  func test_sessionEndUsesTheBackgroundTimestampEvenWhenTheWorkQueueIsBusy() {
    var begun = 0
    var ended = 0
    let probe = ThreadProbeApiClient(blockForSeconds: 1.5)
    let core = newCore(
      beginBackgroundTask: { begun += 1; return { ended += 1 } },
      apiClient: probe
    )
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    drain(core)
    XCTAssertNotNil(store.getSessionStartedAtMs())

    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl) // blocks the queue 1.5s
    let deadline = Date().addingTimeInterval(10)
    while probe.callCount == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    drain(core)

    XCTAssertEqual(store.getSessionCount(), 1)
    XCTAssertLessThan(store.getSessionTimeMs(), 1_000, "queue wait time must not be counted as foreground")
    XCTAssertEqual(begun, 1, "session end must run under an OS background task")
    XCTAssertEqual(ended, 1, "the background task must be ended once the work ran")
  }

  // Item 6: flush stops at the first transient failure, and is de-duplicated.

  func test_flushStopsAtTheFirstTransientFailureInsteadOfRetryingEveryEvent() {
    let eventStore = NottiEventStore(defaults: defaults)
    for index in 0..<3 {
      _ = eventStore.enqueue(notificationId: "n-\(index)", deliveryId: "d-\(index)", type: "received")
    }
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    for _ in 0..<5 { StubURLProtocol.enqueue(.status(503)) } // first event: 5 attempts
    let core = newCore(eventStore: eventStore)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 6, "register + 5 attempts for the FIRST event only")
    XCTAssertEqual(eventStore.all().count, 3, "every event stays queued")
  }

  func test_aBurstOfFlushTriggersSchedulesASingleFlush() {
    let client = SlowEventApiClient()
    let eventStore = NottiEventStore(defaults: defaults)
    let core = newCore(apiClient: client, eventStore: eventStore)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    drain(core)

    _ = eventStore.enqueue(notificationId: "n-1", deliveryId: "d-1", type: "received")
    for _ in 0..<10 { core.onNetworkAvailable() }
    drain(core)

    XCTAssertLessThanOrEqual(client.reportCallCount, 2, "a burst of triggers must not queue one flush each")
    XCTAssertGreaterThanOrEqual(client.reportCallCount, 1)
  }

  // Item 8: telemetry never evicts user mutations and is coalesced per key.

  func test_queuedTelemetryIsCoalescedToTheLatestSnapshotPerKey() {
    var deliverToken: ((String?) -> Void)?
    let core = newCore(tokenProvider: { cb in deliverToken = cb })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    core.handleSessionStart(nowMs: 1_000)
    core.handleSessionEnd(nowMs: 2_000)
    core.handleSessionStart(nowMs: 3_000)
    core.handleSessionEnd(nowMs: 5_000)
    drain(core)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    StubURLProtocol.enqueue(.status(200)) // ONE session PATCH
    deliverToken?("apns-token")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies[0]["session_count"] as? Int, 2, "the latest cumulative snapshot wins")
    XCTAssertEqual(bodies[0]["session_time_seconds"] as? Int, 3)
  }

  func test_coalescedTelemetryNeitherCountsAgainstNorEvictsQueuedUserMutations() {
    // Mirrors Android's `runOrQueue`: coalesced entries never count against
    // the 32-entry cap, so telemetry never evicts a login/tag mutation and is
    // itself never evicted.
    var deliverToken: ((String?) -> Void)?
    let core = newCore(tokenProvider: { cb in deliverToken = cb })
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    core.login("user-42")
    for index in 0..<30 { core.mutateTags(add: ["k\(index)": "v"], remove: nil) }
    core.handleSessionStart(nowMs: 1_000)
    core.handleSessionEnd(nowMs: 2_000) // telemetry: outside the cap
    core.mutateTags(add: ["last": "v"], remove: nil) // 32nd user mutation: fits
    core.handleSessionStart(nowMs: 3_000)
    core.handleSessionEnd(nowMs: 4_000) // coalesced onto the queued session snapshot
    drain(core)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    for _ in 0..<33 { StubURLProtocol.enqueue(.status(200)) }
    deliverToken?("apns-token")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies.count, 33, "all 32 user mutations + the single coalesced session snapshot")
    XCTAssertEqual(bodies[0]["external_user_id"] as? String, "user-42", "login must never be evicted by telemetry")
    XCTAssertEqual(bodies.filter { $0["session_count"] != nil }.count, 1)
    XCTAssertEqual(bodies.first { $0["session_count"] != nil }?["session_count"] as? Int, 2)
    XCTAssertEqual((bodies.last?["tags"] as? [String: String])?["last"], "v")
    XCTAssertEqual(store.getSessionCount(), 2, "the aggregate itself is still persisted locally")
  }

  func test_queuedEmailAndPhoneAreNeverEvictedFromAFullQueue() {
    var deliverToken: ((String?) -> Void)?
    let logs = LogSink()
    let core = newCore(tokenProvider: { cb in deliverToken = cb }, logs: logs)
    core.initialize(appId: "app-1", clientKey: "key", baseUrl: baseUrl)
    core.setEmail("user@example.com") // queued first
    core.clearPhone()                  // queued second (a PII erasure)
    core.login("user-42")
    for index in 0..<31 { core.mutateTags(add: ["k\(index)": "v"], remove: nil) } // 32 user mutations
    core.mutateTags(add: ["last": "v"], remove: nil) // 33rd: evicts the oldest USER mutation (login)
    drain(core)

    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#)) // registration
    for _ in 0..<40 { StubURLProtocol.enqueue(.status(200)) }
    deliverToken?("apns-token")
    drain(core)

    let bodies = patchBodies(StubURLProtocol.recordedRequests())
    XCTAssertEqual(bodies[0]["email"] as? String, "user@example.com", "queued email must survive a full queue")
    XCTAssertTrue(bodies[1]["phone"] is NSNull, "queued phone clear must survive a full queue")
    XCTAssertTrue(bodies.allSatisfy { $0["external_user_id"] == nil }, "the oldest user mutation is what gets evicted")
    XCTAssertEqual(bodies.filter { $0["tags"] != nil }.count, 32)
    XCTAssertTrue(logs.messages.contains { $0.contains("dropping the oldest queued mutation (login)") })
  }
}

/// An API client that records which thread it was called on and blocks there
/// for a while, standing in for a slow/dead network. A stubbed `URLProtocol`
/// cannot prove this: `URLSession` always runs the protocol on its own
/// internal queue, so the only way to observe the thread the *SDK's* blocking
/// call chain occupies is from inside the client itself.
final class ThreadProbeApiClient: NottiApiClient {

  private let blockForSeconds: TimeInterval
  private let lock = NSLock()
  private var mainThreadSeen = false
  private var calls = 0
  private var patchCalls = 0

  init(blockForSeconds: TimeInterval) {
    self.blockForSeconds = blockForSeconds
    super.init(baseUrl: "https://notti.example.com", appId: "app-1", clientKey: "key", sleeper: { _ in })
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

/// Thread-safe log capture, mirroring `NottiCoreTest.kt`'s plain
/// `mutableListOf<String>()` (safe there because Kotlin's test only touches
/// it from callbacks that are themselves synchronized) — this SDK's
/// serialization test drives `NottiCore` from two real threads, so the
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

/// Registers successfully and answers every PATCH through `onPatch` (true =
/// 2xx, false = terminal 400) - lets a test mutate store state while a PATCH
/// is "in flight" and fail specific requests. Called on the work queue only.
final class PatchHookApiClient: NottiApiClient {
  private let onPatch: ([String: Any]) -> Bool

  init(onPatch: @escaping ([String: Any]) -> Bool) {
    self.onPatch = onPatch
    super.init(baseUrl: "https://notti.example.com", appId: "app-1", clientKey: "key", sleeper: { _ in })
  }

  override func createOrUpdateDevice(token: String, platform: String) -> ApiResult {
    .success(DeviceResponse(id: "device-1", tags: [:]))
  }

  override func patchDevice(deviceId: String, token: String, fields: [String: Any]) -> ApiResult {
    onPatch(fields) ? .success(DeviceResponse(id: deviceId, tags: [:])) : .failure("HTTP 400")
  }
}

/// Registers successfully and answers every event report with a slow
/// transient failure, counting calls - used to prove flush de-duplication.
final class SlowEventApiClient: NottiApiClient {
  private let lock = NSLock()
  private var reports = 0

  init() {
    super.init(baseUrl: "https://notti.example.com", appId: "app-1", clientKey: "key", sleeper: { _ in })
  }

  var reportCallCount: Int {
    lock.lock(); defer { lock.unlock() }
    return reports
  }

  override func createOrUpdateDevice(token: String, platform: String) -> ApiResult {
    .success(DeviceResponse(id: "device-1", tags: [:]))
  }

  override func reportEvent(notificationId: String, deliveryId: String, type: String, token: String) -> EventResult {
    lock.lock(); reports += 1; lock.unlock()
    Thread.sleep(forTimeInterval: 0.3)
    return .failure("HTTP 503", terminal: false)
  }
}
