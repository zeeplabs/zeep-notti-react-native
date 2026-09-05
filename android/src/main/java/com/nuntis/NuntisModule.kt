package com.nuntis

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap

// SPEC_DEVIATION: T4's Spec change (multiply -> the real v1 method surface)
// regenerates NativeNuntisSpec with these abstract methods; T8 wires each
// one into NuntisCore (T7). These are temporary no-op stubs kept only to
// keep the Android module compiling ahead of T7/T8.
class NuntisModule(reactContext: ReactApplicationContext) :
  NativeNuntisSpec(reactContext) {

  override fun initialize(appId: String?, clientKey: String?) = Unit

  override fun requestPermission(promise: Promise?) = Unit

  override fun login(externalUserId: String?) = Unit

  override fun logout() = Unit

  override fun addTags(tags: ReadableMap?) = Unit

  override fun removeTags(keys: ReadableArray?) = Unit

  override fun setSubscription(enabled: Boolean) = Unit

  companion object {
    const val NAME = NativeNuntisSpec.NAME
  }
}
