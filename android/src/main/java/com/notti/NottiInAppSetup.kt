package com.notti

import android.app.Application
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.OkHttpClient

/**
 * Builds and installs the process-wide In-App coordinator with its overlay
 * presenter, Activity tracker and image loader. Called once from
 * [NottiInitProvider.onCreate], before any Activity, so the tracker sees the
 * first resume; a second call returns the installed coordinator.
 */
internal object NottiInAppSetup {

  @Synchronized
  fun install(application: Application): NottiInAppCoordinator {
    NottiInApp.get()?.let { return it }
    val prefs = application.getSharedPreferences(NottiModule.PREFS_NAME, Context.MODE_PRIVATE)
    val deviceStore = NottiDeviceStore(prefs)
    val main = Handler(Looper.getMainLooper())
    val coordinator = NottiInAppCoordinator(
      store = NottiInAppEventStore(prefs),
      clientFactory = { config ->
        NottiApiClient(OkHttpClient(), config.baseUrl, config.appId, config.clientKey)
      },
      identity = {
        val deviceId = deviceStore.getDeviceId()
        val token = deviceStore.getLastToken()
        if (deviceId != null && token != null) InAppIdentity(deviceId, token) else null
      },
      executor = NottiInAppScheduler(),
      // Always posted, even from main: keeps one FIFO for initialize, trackEvent
      // and the session start the core's creation replays (DD-13).
      postToMain = { task -> main.post(task) },
      logger = { message -> Log.w(NottiModule.NAME, message) }
    )
    val installed = NottiInApp.install(coordinator)
    if (installed !== coordinator) return installed

    val images = NottiInAppImageLoader()
    val tracker = NottiInAppActivityTracker()
    coordinator.presenter = NottiInAppOverlayPresenter(tracker, coordinator, images)
    application.registerActivityLifecycleCallbacks(tracker)
    application.registerComponentCallbacks(ImageCacheTrimmer(images))
    return coordinator
  }

  /** Drops the in-memory image cache under memory pressure (design "Images"). */
  private class ImageCacheTrimmer(private val images: NottiInAppImageLoader) : ComponentCallbacks2 {
    override fun onTrimMemory(level: Int) {
      // UI_HIDDEN only means the app went to the background, not memory pressure.
      if (level != ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) images.clear()
    }

    @Deprecated("Deprecated in Java")
    override fun onLowMemory() = images.clear()

    override fun onConfigurationChanged(newConfig: Configuration) = Unit
  }
}
