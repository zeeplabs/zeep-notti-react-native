import Foundation
import UIKit
import UserNotifications

/// iOS side of the `push_permission` in-app button (IABA-06..08).
///
/// | state | effect |
/// | --- | --- |
/// | not determined | request through the core, so the subscribed PATCH and the status refresh stay in one place |
/// | denied | open the app's notification settings |
/// | authorized, provisional, ephemeral | nothing |
/// | unknown | nothing, one generic log line |
///
/// Every platform effect is injected, so each row is a plain XCTest.
final class NottiPushPermissionAction {

  enum State: Equatable {
    case notDetermined
    case denied
    case granted
    case unknown

    init(_ status: UNAuthorizationStatus) {
      switch status {
      case .notDetermined: self = .notDetermined
      case .denied: self = .denied
      case .authorized, .provisional, .ephemeral: self = .granted
      @unknown default: self = .unknown
      }
    }
  }

  private let readState: (@escaping (State) -> Void) -> Void
  private let requestPermission: () -> Void
  private let openNotificationSettings: () -> Void
  private let logger: (String) -> Void

  /// `readState` may answer on any thread; `openNotificationSettings` is
  /// expected to hop to main itself.
  init(
    readState: @escaping (@escaping (State) -> Void) -> Void,
    requestPermission: @escaping () -> Void,
    openNotificationSettings: @escaping () -> Void,
    logger: @escaping (String) -> Void
  ) {
    self.readState = readState
    self.requestPermission = requestPermission
    self.openNotificationSettings = openNotificationSettings
    self.logger = logger
  }

  func run() {
    readState { [self] state in
      switch state {
      case .notDetermined: requestPermission()
      case .denied: openNotificationSettings()
      case .granted: break
      case .unknown: logger("Notti.inapp: push permission state unavailable")
      }
    }
  }

  /// The production state reader.
  static func systemState(_ callback: @escaping (State) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      callback(State(settings.authorizationStatus))
    }
  }

  /// Opens the app's notification settings where the OS has such a page, else its settings page.
  static func openSystemNotificationSettings() {
    DispatchQueue.main.async {
      let raw: String
      if #available(iOS 16.0, *) {
        raw = UIApplication.openNotificationSettingsURLString
      } else {
        raw = UIApplication.openSettingsURLString
      }
      guard let url = URL(string: raw) else { return }
      UIApplication.shared.open(url)
    }
  }
}
