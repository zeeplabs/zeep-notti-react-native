package com.notti

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import okhttp3.CookieJar
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Image port of the presenter. [done] may run on any thread; null means "no image". */
fun interface InAppImageSource {
  fun load(url: String, maxSidePx: Int, done: (Bitmap?) -> Unit)
}

/**
 * Downloads `image_url` (SDKIAM-57, A10). The host is chosen by the message
 * author, so the request goes through a dedicated client: no Notti header,
 * no cookies, no identifiers, no redirect to a non-`https` URL. Bounded in
 * time and size, decoded downsampled, cached in memory only. Any failure is
 * "no image", never an error of the message. Never logs the URL.
 */
class NottiInAppImageLoader(
  private val client: OkHttpClient = newClient(),
  private val executor: Executor = defaultExecutor,
  private val maxBytes: Long = MAX_BYTES,
  cacheBytes: Int = defaultCacheBytes()
) : InAppImageSource {

  companion object {
    const val TIMEOUT_MS = 10_000L
    const val MAX_BYTES = 5L * 1024 * 1024
    const val MAX_CACHE_BYTES = 32 * 1024 * 1024

    private val defaultExecutor: Executor by lazy {
      Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "notti-inapp-image").apply { isDaemon = true }
      }
    }

    /** The credential-free client. [base] lets tests trust their own certificate. */
    fun newClient(base: OkHttpClient.Builder = OkHttpClient.Builder(), timeoutMs: Long = TIMEOUT_MS): OkHttpClient =
      base
        .cookieJar(CookieJar.NO_COOKIES)
        .cache(null)
        // https -> https redirects are followed; https -> http is refused.
        .followSslRedirects(false)
        .callTimeout(timeoutMs, TimeUnit.MILLISECONDS)
        .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
        .readTimeout(timeoutMs, TimeUnit.MILLISECONDS)
        .build()

    internal fun isHttps(url: String): Boolean = url.toHttpUrlOrNull()?.isHttps == true

    /**
     * Smallest power-of-two sample size that brings the longest side down to
     * [maxSide] or less (a decoder rounds a partial pixel up, hence the ceil).
     * A 4800 px square on a 2400 px screen decodes at 2400 px, ~23 MB ARGB,
     * instead of ~92 MB at full size.
     */
    internal fun sampleSize(width: Int, height: Int, maxSide: Int): Int {
      var sample = 1
      val longest = maxOf(width, height)
      while (maxSide > 0 && (longest + sample - 1) / sample > maxSide) sample *= 2
      return sample
    }

    /**
     * 1/16 of the heap, capped at [MAX_CACHE_BYTES]: a few card-sized images
     * on any device, while the host app keeps the rest. An image larger than
     * the whole cache is shown but not kept.
     */
    internal fun defaultCacheBytes(maxHeap: Long = Runtime.getRuntime().maxMemory()): Int =
      (maxHeap / 16).coerceIn(1L, MAX_CACHE_BYTES.toLong()).toInt()
  }

  /** Bounded in bytes, not entries: one full-screen bitmap weighs as much as dozens of small ones. */
  private val cache = object : LruCache<String, Bitmap>(cacheBytes) {
    override fun sizeOf(key: String, value: Bitmap): Int = value.allocationByteCount
  }

  override fun load(url: String, maxSidePx: Int, done: (Bitmap?) -> Unit) {
    cache.get(url)?.let {
      done(it)
      return
    }
    // Rejected before any connection.
    if (!isHttps(url)) {
      done(null)
      return
    }
    executor.execute {
      // Throwable, not Exception: an OutOfMemoryError while decoding would
      // otherwise kill this thread, and with it the host app, before [done].
      val bitmap = try {
        fetch(url, maxSidePx)
      } catch (e: Throwable) {
        null
      }
      // An oversize put would evict every other entry and then itself.
      if (bitmap != null && bitmap.allocationByteCount <= cache.maxSize()) cache.put(url, bitmap)
      done(bitmap)
    }
  }

  /** Drops the cached images (low memory). */
  fun clear() = cache.evictAll()

  internal fun fetch(url: String, maxSidePx: Int): Bitmap? {
    val request = Request.Builder().url(url).get().build()
    client.newCall(request).execute().use { response ->
      if (!response.isSuccessful || !response.request.url.isHttps) return null
      val body = response.body ?: return null
      if (body.contentLength() > maxBytes) return null
      val bytes = readBounded(body.byteStream()) ?: return null
      return decode(bytes, maxSidePx)
    }
  }

  /** Null as soon as the body passes [maxBytes]: the rest is never read. */
  private fun readBounded(input: InputStream): ByteArray? {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(16 * 1024)
    var total = 0L
    while (true) {
      val read = input.read(buffer)
      if (read < 0) break
      total += read
      if (total > maxBytes) return null
      out.write(buffer, 0, read)
    }
    return out.toByteArray()
  }

  private fun decode(bytes: ByteArray, maxSidePx: Int): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    val options = BitmapFactory.Options().apply {
      inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, maxSidePx)
    }
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
  }
}
