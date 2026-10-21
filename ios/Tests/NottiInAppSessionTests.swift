import XCTest
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

private func message(
  _ id: String,
  trigger: InAppTrigger = .sessionStart,
  renderable: Bool = true,
  dismissAfterSeconds: Int? = nil
) -> InAppMessage {
  InAppMessage(
    id: id,
    format: .center,
    title: "t",
    body: "b",
    imageUrl: nil,
    imageAction: nil,
    style: InAppStyle(),
    dismissAfterSeconds: dismissAfterSeconds,
    trigger: trigger,
    buttons: [],
    renderable: renderable
  )
}

private func event(_ id: String, _ name: String) -> InAppMessage { message(id, trigger: .event(name: name)) }

private let configA = InAppConfig(appId: "app-a", clientKey: "key-a", baseUrl: "https://a.example")
private let configB = InAppConfig(appId: "app-b", clientKey: "key-b", baseUrl: "https://b.example")

/// Mirror of `NottiInAppSessionTest.kt`: same cases, same order.
final class NottiInAppSessionTests: XCTestCase {

  private var now: Int64 = 1_000
  private var counter = 0
  private var session: NottiInAppSession!

  override func setUp() {
    super.setUp()
    now = 1_000
    counter = 0
    session = NottiInAppSession(
      monotonicMs: { [unowned self] in self.now },
      uuid: { [unowned self] in
        self.counter += 1
        return "display-\(self.counter)"
      }
    )
  }

  @discardableResult
  private func openWithFetch(_ messages: [InAppMessage]) -> InAppDecision {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    guard let generation = session.tryStartFetch() else {
      XCTFail("fetch must start")
      return .nothing
    }
    return session.onFetched(generation: generation, messages: messages)
  }

  private func startFetch(file: StaticString = #filePath, line: UInt = #line) -> Int64 {
    guard let generation = session.tryStartFetch() else {
      XCTFail("fetch must start", file: file, line: line)
      return -1
    }
    return generation
  }

  private func shownId(_ decision: InAppDecision) -> String? {
    guard case .show(let display) = decision else { return nil }
    return display.message.id
  }

  private func currentDisplayId(file: StaticString = #filePath, line: UInt = #line) -> String {
    guard let display = session.display else {
      XCTFail("expected a display", file: file, line: line)
      return ""
    }
    return display.displayId
  }

  private func closeCurrent(file: StaticString = #filePath, line: UInt = #line) {
    let id = currentDisplayId(file: file, line: line)
    XCTAssertTrue(session.markVisible(id), file: file, line: line)
    XCTAssertTrue(session.markClosed(id), file: file, line: line)
  }

  // MARK: - Session tokens

  func test_sessionTokenIncrementsAndStaleTokensAreRejected() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    let first = session.sessionToken
    XCTAssertTrue(session.isCurrentSession(first))
    session.onSessionEnded()
    XCTAssertFalse(session.isCurrentSession(first))
    session.onSessionStarted()
    XCTAssertEqual(session.sessionToken, first + 1)
    XCTAssertFalse(session.isCurrentSession(first))
    XCTAssertTrue(session.isCurrentSession(session.sessionToken))
  }

  // MARK: - onFetched selection

  func test_firstRenderableSessionStartIsShownAndOthersAreNotQueued() {
    let decision = openWithFetch([message("broken", renderable: false), message("s1"), message("s2")])
    XCTAssertEqual(shownId(decision), "s1")
    closeCurrent()
    XCTAssertEqual(session.trackEvent("anything"), .nothing)
    XCTAssertNil(session.display)
  }

  func test_eventMessagesAreHeldInServerOrderAndNotShownOnFetch() {
    let decision = openWithFetch([event("e1", "buy"), event("e2", "buy"), event("e3", "view")])
    XCTAssertEqual(decision, .nothing)
    XCTAssertEqual(session.heldMessages.map(\.id), ["e1", "e2", "e3"])
  }

  func test_sessionStartIsDroppedWhenADisplayAlreadyExists() throws {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    XCTAssertEqual(shownId(session.onFetched(generation: startFetch(), messages: [message("s1")])), "s1")
    let carried = try XCTUnwrap(session.display)
    XCTAssertTrue(session.markVisible(carried.displayId))
    session.onSessionEnded()
    session.onSessionStarted()
    let decision = session.onFetched(generation: startFetch(), messages: [message("s2")])
    XCTAssertEqual(decision, .nothing)
    XCTAssertTrue(session.display === carried)
  }

  func test_duplicateIdInTheResponseIsShownAtMostOnce() {
    openWithFetch([event("e1", "buy"), event("e1", "buy")])
    XCTAssertEqual(shownId(session.trackEvent("buy")), "e1")
    closeCurrent()
    XCTAssertEqual(session.trackEvent("buy"), .nothing)
  }

  func test_onlyOneSuccessfulFetchPerSession() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    let generation = startFetch()
    XCTAssertNil(session.tryStartFetch())
    _ = session.onFetched(generation: generation, messages: [])
    XCTAssertEqual(session.fetch, .done)
    XCTAssertNil(session.tryStartFetch())
  }

  func test_transientGiveUpCanRestartTheFetchTerminalGiveUpCannot() throws {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    session.onFetchGaveUp(generation: startFetch(), transient: true)
    let retry = try XCTUnwrap(session.tryStartFetch())
    session.onFetchGaveUp(generation: retry, transient: false)
    XCTAssertNil(session.tryStartFetch())
  }

  func test_noFetchWithoutAnOpenSessionOrAfterA401() {
    _ = session.onInitialized(configA)
    XCTAssertNil(session.tryStartFetch())
    session.onSessionStarted()
    session.markKeyRejected()
    XCTAssertNil(session.tryStartFetch())
    session.onSessionEnded()
    session.onSessionStarted()
    XCTAssertFalse(session.keyRejected)
    XCTAssertNotNil(session.tryStartFetch())
  }

  // MARK: - trackEvent

  func test_trackEventMatchesExactlyAndCaseSensitively() {
    openWithFetch([event("e1", "Buy")])
    XCTAssertEqual(session.trackEvent("buy"), .nothing)
    XCTAssertEqual(session.trackEvent("Buy "), .nothing)
    XCTAssertEqual(shownId(session.trackEvent("Buy")), "e1")
  }

  func test_trackEventPicksTheOldestMatchingHeldMessageAndNeverShowsItTwice() {
    openWithFetch([event("e1", "buy"), event("e2", "buy")])
    XCTAssertEqual(shownId(session.trackEvent("buy")), "e1")
    closeCurrent()
    XCTAssertEqual(shownId(session.trackEvent("buy")), "e2")
    closeCurrent()
    XCTAssertEqual(session.trackEvent("buy"), .nothing)
  }

  func test_trackEventIsIgnoredWhileADisplayIsPendingOrVisibleAndHeldStayUntouched() {
    openWithFetch([event("e1", "buy"), event("e2", "view")])
    XCTAssertEqual(shownId(session.trackEvent("buy")), "e1")
    XCTAssertEqual(session.trackEvent("view"), .nothing)
    _ = session.markVisible(currentDisplayId())
    XCTAssertEqual(session.trackEvent("view"), .nothing)
    XCTAssertEqual(session.heldMessages.map(\.id), ["e1", "e2"])
    XCTAssertTrue(session.markClosed(currentDisplayId()))
    XCTAssertEqual(shownId(session.trackEvent("view")), "e2")
  }

  func test_blankNamesAreIgnored() {
    openWithFetch([event("e1", " ")])
    XCTAssertEqual(session.trackEvent(""), .nothing)
    XCTAssertEqual(session.trackEvent("   "), .nothing)
  }

  func test_namesBeforeTheResponseAreReplayedOnceInOrderAfterOnFetched() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    let generation = startFetch()
    _ = session.trackEvent("view")
    _ = session.trackEvent("buy")
    _ = session.trackEvent("view")
    XCTAssertEqual(session.pending, ["view", "buy"])
    let decision = session.onFetched(generation: generation, messages: [event("e1", "buy"), event("e2", "view")])
    XCTAssertEqual(shownId(decision), "e2")
    XCTAssertTrue(session.pending.isEmpty)
    closeCurrent()
    XCTAssertEqual(session.trackEvent("other"), .nothing)
    XCTAssertNil(session.display)
  }

  func test_sessionStartWinsOverAReplayedName() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    let generation = startFetch()
    _ = session.trackEvent("buy")
    let decision = session.onFetched(generation: generation, messages: [message("s1"), event("e1", "buy")])
    XCTAssertEqual(shownId(decision), "s1")
    XCTAssertTrue(session.pending.isEmpty)
  }

  func test_pendingNamesAreCappedAt32Distinct() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    for i in 0..<40 { _ = session.trackEvent("n\(i)") }
    XCTAssertEqual(session.pending.count, NottiInAppSession.maxPendingNames)
    XCTAssertEqual(session.pending.last, "n31")
  }

  func test_namesWhileTheFetchGaveUpStayPendingUntilSessionEnd() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    session.onFetchGaveUp(generation: startFetch(), transient: true)
    _ = session.trackEvent("buy")
    XCTAssertEqual(session.pending, ["buy"])
    session.onSessionEnded()
    XCTAssertTrue(session.pending.isEmpty)
  }

  // MARK: - awaitingFirstSession

  func test_trackEventBeforeOnInitializedIsIgnored() {
    _ = session.trackEvent("buy")
    XCTAssertTrue(session.pending.isEmpty)
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    let decision = session.onFetched(generation: startFetch(), messages: [event("e1", "buy")])
    XCTAssertEqual(decision, .nothing)
  }

  func test_onInitializedThenTrackEventBeforeTheFirstSessionReplaysWithThatSession() {
    _ = session.onInitialized(configA)
    XCTAssertTrue(session.awaitingFirstSession)
    _ = session.trackEvent("buy")
    session.onSessionStarted()
    XCTAssertFalse(session.awaitingFirstSession)
    XCTAssertEqual(session.pending, ["buy"])
    let decision = session.onFetched(generation: startFetch(), messages: [event("e1", "buy")])
    XCTAssertEqual(shownId(decision), "e1")
    XCTAssertTrue(session.pending.isEmpty)
  }

  func test_awaitingNamesAreCappedAt32() {
    _ = session.onInitialized(configA)
    for i in 0..<33 { _ = session.trackEvent("n\(i)") }
    XCTAssertEqual(session.pending.count, 32)
  }

  func test_sessionEndWithNoSessionOpenKeepsTheAwaitingNames() {
    _ = session.onInitialized(configA)
    _ = session.trackEvent("buy")
    session.onSessionEnded()
    XCTAssertEqual(session.pending, ["buy"])
    XCTAssertTrue(session.awaitingFirstSession)
  }

  func test_trackEventInBackgroundAfterASessionRanIsIgnored() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    session.onSessionEnded()
    _ = session.trackEvent("buy")
    XCTAssertTrue(session.pending.isEmpty)
  }

  func test_reInitializeAfterASessionRanDoesNotSetAwaitingFirstSession() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    session.onSessionEnded()
    _ = session.onInitialized(configB)
    XCTAssertFalse(session.awaitingFirstSession)
  }

  // MARK: - fetchGeneration and late responses

  func test_responseAfterSessionEndIsDiscarded() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    let generation = startFetch()
    session.onSessionEnded()
    XCTAssertEqual(session.onFetched(generation: generation, messages: [message("s1"), event("e1", "buy")]), .nothing)
    XCTAssertTrue(session.heldMessages.isEmpty)
  }

  func test_responseOfAnEndedSessionIsDiscardedEvenWithANewerSessionOpen() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    let old = startFetch()
    session.onSessionEnded()
    session.onSessionStarted()
    XCTAssertEqual(session.onFetched(generation: old, messages: [message("s1"), event("e1", "buy")]), .nothing)
    XCTAssertTrue(session.heldMessages.isEmpty)
    XCTAssertEqual(session.fetch, .idle)
    XCTAssertNotNil(session.tryStartFetch())
  }

  func test_staleGiveUpIsIgnored() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    let old = startFetch()
    session.onSessionEnded()
    session.onSessionStarted()
    session.onFetchGaveUp(generation: old, transient: false)
    XCTAssertEqual(session.fetch, .idle)
  }

  func test_heldMessagesAreDroppedAtSessionEnd() {
    openWithFetch([event("e1", "buy")])
    session.onSessionEnded()
    XCTAssertTrue(session.heldMessages.isEmpty)
    session.onSessionStarted()
    XCTAssertEqual(session.trackEvent("buy"), .nothing)
  }

  // MARK: - onInitialized

  func test_sameConfigLeavesTheStateUntouched() {
    openWithFetch([event("e1", "buy"), message("s1")])
    let display = session.display
    let generation = session.fetchGeneration
    session.eventsPausedUntilMs = 5_000
    let sameValues = InAppConfig(appId: "app-a", clientKey: "key-a", baseUrl: "https://a.example")
    XCTAssertEqual(session.onInitialized(sameValues), .unchanged)
    XCTAssertTrue(session.display === display)
    XCTAssertEqual(session.fetchGeneration, generation)
    XCTAssertEqual(session.heldMessages.map(\.id), ["e1"])
    XCTAssertEqual(session.eventsPausedUntilMs, 5_000)
    XCTAssertEqual(session.fetch, .done)
  }

  func test_differentConfigResetsTheStateAndTearsTheDisplayDownSilently() throws {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    let generation = startFetch()
    _ = session.trackEvent("buy")
    _ = session.onFetched(generation: generation, messages: [message("s1"), event("e1", "buy")])
    let display = try XCTUnwrap(session.display)
    _ = session.markVisible(display.displayId)
    session.eligiblePausedUntilMs = 1
    session.eventsPausedUntilMs = 2
    session.markKeyRejected()
    _ = session.shouldWarnInactive(.events)

    let outcome = session.onInitialized(configB)

    XCTAssertEqual(outcome, .changed(teardown: display))
    XCTAssertNil(session.display)
    XCTAssertEqual(display.state, .closed)
    XCTAssertFalse(session.markClosed(display.displayId))
    XCTAssertTrue(session.heldMessages.isEmpty)
    XCTAssertTrue(session.pending.isEmpty)
    XCTAssertTrue(session.shown.isEmpty)
    XCTAssertEqual(session.fetch, .idle)
    XCTAssertNil(session.eligiblePausedUntilMs)
    XCTAssertNil(session.eventsPausedUntilMs)
    XCTAssertFalse(session.keyRejected)
    XCTAssertTrue(session.shouldWarnInactive(.events))
    XCTAssertEqual(session.fetchGeneration, generation + 1)
    XCTAssertEqual(session.onFetched(generation: generation, messages: [message("s2")]), .nothing)
    XCTAssertEqual(session.config, configB)
  }

  func test_configChangeDuringAnInFlightFetchLetsANewFetchStart() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    let old = startFetch()
    _ = session.onInitialized(configB)
    let fresh = startFetch()
    XCTAssertNotEqual(fresh, old)
    XCTAssertEqual(shownId(session.onFetched(generation: fresh, messages: [message("s1")])), "s1")
  }

  func test_firstOnInitializedReportsFirst() {
    XCTAssertEqual(session.onInitialized(configA), .first)
  }

  func test_configDescriptionsNeverPrintTheKey() {
    for text in [configA.description, String(describing: configA), String(reflecting: configA), "\(configA)"] {
      XCTAssertFalse(text.contains("key-a"), text)
      XCTAssertFalse(text.contains("app-a"), text)
    }
  }

  // MARK: - Display states

  func test_markVisibleIsTrueOnlyOnce() {
    openWithFetch([message("s1")])
    let id = currentDisplayId()
    XCTAssertTrue(session.markVisible(id))
    XCTAssertFalse(session.markVisible(id))
    XCTAssertEqual(session.display?.impressionRecorded, true)
  }

  func test_markVisibleWithAnUnknownDisplayIdIsRejected() {
    openWithFetch([message("s1")])
    XCTAssertFalse(session.markVisible("other"))
  }

  func test_markClosedGivesExactlyOneTerminalOutcome() {
    openWithFetch([message("s1")])
    let id = currentDisplayId()
    _ = session.markVisible(id)
    XCTAssertTrue(session.markClosed(id))
    XCTAssertFalse(session.markClosed(id))
    XCTAssertFalse(session.markVisible(id))
  }

  func test_noTerminalOutcomeBeforeVisible() {
    openWithFetch([message("s1")])
    let id = currentDisplayId()
    XCTAssertFalse(session.markClosed(id))
    XCTAssertEqual(session.display?.state, .preparing)
  }

  func test_dropPreparingRemovesADisplayThatNeverBecameVisible() {
    openWithFetch([message("s1")])
    let id = currentDisplayId()
    XCTAssertTrue(session.dropPreparing(id))
    XCTAssertNil(session.display)
    XCTAssertFalse(session.markVisible(id))
  }

  func test_dropPreparingDoesNotTouchAVisibleDisplay() {
    openWithFetch([message("s1")])
    let id = currentDisplayId()
    _ = session.markVisible(id)
    XCTAssertFalse(session.dropPreparing(id))
    XCTAssertNotNil(session.display)
  }

  // MARK: - Session end carry-over (DD-8)

  func test_visibleDisplaySurvivesSessionEndAndItsIdIsShownInTheNextSession() throws {
    openWithFetch([message("s1")])
    let display = try XCTUnwrap(session.display)
    _ = session.markVisible(display.displayId)
    XCTAssertNil(session.onSessionEnded())
    XCTAssertTrue(session.display === display)
    session.onSessionStarted()
    XCTAssertEqual(session.shown, ["s1"])
    XCTAssertTrue(session.markClosed(display.displayId))
    let decision = session.onFetched(generation: startFetch(), messages: [message("s1"), message("s2")])
    XCTAssertEqual(shownId(decision), "s2")
  }

  func test_preparingDisplayIsDroppedAtSessionEnd() throws {
    openWithFetch([message("s1")])
    let display = try XCTUnwrap(session.display)
    XCTAssertTrue(session.onSessionEnded() === display)
    XCTAssertNil(session.display)
    XCTAssertFalse(session.markVisible(display.displayId))
  }

  func test_shownIdsDoNotPersistAcrossSessions() {
    openWithFetch([message("s1")])
    closeCurrent()
    session.onSessionEnded()
    session.onSessionStarted()
    XCTAssertTrue(session.shown.isEmpty)
    let decision = session.onFetched(generation: startFetch(), messages: [message("s1")])
    XCTAssertEqual(shownId(decision), "s1")
  }

  // MARK: - Warnings

  func test_inactiveWarningOncePerSessionPerRoute() {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    XCTAssertTrue(session.shouldWarnInactive(.eligible))
    XCTAssertFalse(session.shouldWarnInactive(.eligible))
    XCTAssertTrue(session.shouldWarnInactive(.events))
    session.onSessionEnded()
    session.onSessionStarted()
    XCTAssertTrue(session.shouldWarnInactive(.eligible))
  }

  // MARK: - Clock wiring

  func test_displayGetsAClockOnlyFor1To300Seconds() {
    openWithFetch([event("a", "a"), message("b", trigger: .event(name: "b"), dismissAfterSeconds: 5)])
    _ = session.trackEvent("a")
    XCTAssertNotNil(session.display)
    XCTAssertNil(session.display?.clock)
    closeCurrent()
    _ = session.trackEvent("b")
    XCTAssertNotNil(session.display?.clock)
  }

  func test_markVisibleStartsTheClockAndAppBackgroundPausesIt() throws {
    openWithFetch([message("s1", dismissAfterSeconds: 10)])
    let display = try XCTUnwrap(session.display)
    let clock = try XCTUnwrap(display.clock)
    clock.setAttached(true)
    XCTAssertFalse(clock.isRunning)
    _ = session.markVisible(display.displayId)
    XCTAssertTrue(clock.isRunning)
    now += 4_000
    session.setAppForeground(false)
    XCTAssertFalse(clock.isRunning)
    now += 60_000
    XCTAssertEqual(clock.remainingMs(), 6_000)
    session.setAppForeground(true)
    now += 6_000
    XCTAssertTrue(clock.isExpired())
  }

  func test_clockCreatedWhileTheAppIsInBackgroundStartsPaused() throws {
    _ = session.onInitialized(configA)
    session.onSessionStarted()
    let generation = startFetch()
    session.setAppForeground(false)
    _ = session.onFetched(generation: generation, messages: [message("s1", dismissAfterSeconds: 3)])
    let display = try XCTUnwrap(session.display)
    let clock = try XCTUnwrap(display.clock)
    clock.setAttached(true)
    _ = session.markVisible(display.displayId)
    XCTAssertFalse(clock.isRunning)
  }
}

/// Mirror of `NottiInAppDisplayClockTest` (same Kotlin file).
final class NottiInAppDisplayClockTests: XCTestCase {

  private var now: Int64 = 0

  private func makeClock(_ seconds: Int?) -> NottiInAppDisplayClock? {
    NottiInAppDisplayClock.create(seconds: seconds, monotonicMs: { [unowned self] in self.now })
  }

  override func setUp() {
    super.setUp()
    now = 0
  }

  func test_valuesOutside1To300GiveNoClock() {
    XCTAssertNil(makeClock(nil))
    XCTAssertNil(makeClock(0))
    XCTAssertNil(makeClock(-5))
    XCTAssertNil(makeClock(301))
    XCTAssertNotNil(makeClock(1))
    XCTAssertNotNil(makeClock(300))
  }

  func test_clockRunsOnlyAfterStartWhileAttachedAndInForeground() throws {
    let clock = try XCTUnwrap(makeClock(10))
    clock.setAttached(true)
    now += 5_000
    XCTAssertEqual(clock.remainingMs(), 10_000)
    clock.start()
    XCTAssertTrue(clock.isRunning)
    now += 3_000
    XCTAssertEqual(clock.remainingMs(), 7_000)
  }

  func test_detachPreservesTheRemainingTime() throws {
    let clock = try XCTUnwrap(makeClock(10))
    clock.start()
    clock.setAttached(true)
    now += 2_000
    clock.setAttached(false)
    now += 100_000
    XCTAssertEqual(clock.remainingMs(), 8_000)
    clock.setAttached(true)
    now += 8_000
    XCTAssertTrue(clock.isExpired())
  }

  func test_backgroundPauseAndResumePreserveRemainingTime() throws {
    let clock = try XCTUnwrap(makeClock(5))
    clock.start()
    clock.setAttached(true)
    now += 1_000
    clock.setForeground(false)
    now += 30_000
    clock.setForeground(true)
    XCTAssertEqual(clock.remainingMs(), 4_000)
    now += 3_999
    XCTAssertFalse(clock.isExpired())
    now += 1
    XCTAssertTrue(clock.isExpired())
  }

  func test_remainingTimeNeverGoesBelowZero() throws {
    let clock = try XCTUnwrap(makeClock(1))
    clock.start()
    clock.setAttached(true)
    now += 10_000
    XCTAssertEqual(clock.remainingMs(), 0)
    clock.setAttached(false)
    XCTAssertEqual(clock.remainingMs(), 0)
  }

  func test_repeatedAttachDoesNotRestartTheCountdown() throws {
    let clock = try XCTUnwrap(makeClock(10))
    clock.start()
    clock.setAttached(true)
    now += 2_000
    clock.setAttached(true)
    clock.start()
    now += 1_000
    XCTAssertEqual(clock.remainingMs(), 7_000)
  }
}
