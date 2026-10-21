import UserNotifications
import XCTest


final class NottiPushPermissionActionTests: XCTestCase {

  private final class Probe {
    var effects: [String] = []
    var logs: [String] = []
    let action: NottiPushPermissionAction

    init(state: NottiPushPermissionAction.State) {
      var effectsRef: ((String) -> Void)?
      var logsRef: ((String) -> Void)?
      action = NottiPushPermissionAction(
        readState: { $0(state) },
        requestPermission: { effectsRef?("request") },
        openNotificationSettings: { effectsRef?("settings") },
        logger: { logsRef?($0) }
      )
      effectsRef = { [unowned self] in self.effects.append($0) }
      logsRef = { [unowned self] in self.logs.append($0) }
    }
  }

  func testNotDeterminedRequestsThePermission() {
    let probe = Probe(state: .notDetermined)
    probe.action.run()
    XCTAssertEqual(probe.effects, ["request"])
  }

  func testDeniedOpensNotificationSettingsAndNeverRequests() {
    let probe = Probe(state: .denied)
    probe.action.run()
    XCTAssertEqual(probe.effects, ["settings"])
  }

  func testGrantedDoesNothing() {
    let probe = Probe(state: .granted)
    probe.action.run()
    XCTAssertEqual(probe.effects, [])
    XCTAssertEqual(probe.logs, [])
  }

  func testUnknownDoesNothingAndLogsOneGenericLine() {
    let probe = Probe(state: .unknown)
    probe.action.run()
    XCTAssertEqual(probe.effects, [])
    XCTAssertEqual(probe.logs, ["Notti.inapp: push permission state unavailable"])
  }

  func testAuthorizationStatusesMapToState() {
    XCTAssertEqual(NottiPushPermissionAction.State(.notDetermined), .notDetermined)
    XCTAssertEqual(NottiPushPermissionAction.State(.denied), .denied)
    XCTAssertEqual(NottiPushPermissionAction.State(.authorized), .granted)
    XCTAssertEqual(NottiPushPermissionAction.State(.provisional), .granted)
    XCTAssertEqual(NottiPushPermissionAction.State(.ephemeral), .granted)
  }

  func testAsyncStateReaderStillRunsTheEffectOnce() {
    var effects: [String] = []
    let answered = expectation(description: "effect")
    let action = NottiPushPermissionAction(
      readState: { callback in DispatchQueue.global().async { callback(.denied) } },
      requestPermission: {},
      openNotificationSettings: {
        effects.append("settings")
        answered.fulfill()
      },
      logger: { _ in }
    )
    action.run()
    wait(for: [answered], timeout: 2)
    XCTAssertEqual(effects, ["settings"])
  }
}
