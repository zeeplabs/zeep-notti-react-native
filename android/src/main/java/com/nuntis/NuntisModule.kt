package com.nuntis

import com.facebook.react.bridge.ReactApplicationContext

class NuntisModule(reactContext: ReactApplicationContext) :
  NativeNuntisSpec(reactContext) {

  override fun multiply(a: Double, b: Double): Double {
    return a * b
  }

  companion object {
    const val NAME = NativeNuntisSpec.NAME
  }
}
