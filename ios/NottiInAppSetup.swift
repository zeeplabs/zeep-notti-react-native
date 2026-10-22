import Foundation

/// Builds and installs the process-wide In-App coordinator with its window
/// presenter, image loader and click sink. Called from `NottiImpl.init`, before
/// any `NottiCore` exists, so no session start can reach a missing coordinator;
/// a second call returns the installed one. Fully built before it is published,
/// so no other thread ever sees a coordinator without its presenter.
enum NottiInAppSetup {

  private static let lock = NSLock()

  @discardableResult
  static func install(defaults: UserDefaults = NottiImpl.sharedDefaults) -> NottiInAppCoordinator {
    lock.lock()
    defer { lock.unlock() }
    if let installed = NottiInApp.get() { return installed }

    let deviceStore = NottiDeviceStore(defaults: defaults)
    let coordinator = NottiInAppCoordinator(
      store: NottiInAppEventStore(defaults: defaults),
      clientFactory: { config in
        NottiApiClient(baseUrl: config.baseUrl, appId: config.appId, clientKey: config.clientKey)
      },
      identity: {
        guard let deviceId = deviceStore.getDeviceId(), let token = deviceStore.getLastToken() else { return nil }
        return InAppIdentity(deviceId: deviceId, token: token)
      },
      executor: NottiInAppScheduler(),
      logger: { message in NSLog("%@", message) }
    )
    coordinator.presenter = NottiInAppWindowPresenter(events: coordinator, images: NottiInAppImageLoader())
    // The SDK opens no link: the click goes to the JS listener, or is dropped (A9).
    coordinator.clickSink = { NottiImpl.emitInAppClick($0) }
    return NottiInApp.install(coordinator)
  }
}
