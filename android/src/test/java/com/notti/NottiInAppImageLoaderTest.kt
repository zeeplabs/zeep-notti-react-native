package com.notti

import android.graphics.Bitmap
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.QueueDispatcher
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NottiInAppImageLoaderTest {

  private lateinit var server: MockWebServer
  private lateinit var clientCerts: HandshakeCertificates
  private val sameThread = Executor { it.run() }

  @Before
  fun setUp() {
    val host = InetAddress.getByName("localhost").canonicalHostName
    val certificate = HeldCertificate.Builder().addSubjectAlternativeName(host).build()
    val serverCerts = HandshakeCertificates.Builder().heldCertificate(certificate).build()
    clientCerts = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
    server = MockWebServer()
    server.dispatcher = QueueDispatcher().apply { setFailFast(true) }
    server.useHttps(serverCerts.sslSocketFactory(), false)
    // Chunked bodies are an HTTP/1.1 framing; over h2 MockWebServer would send the framing as data.
    server.protocols = listOf(Protocol.HTTP_1_1)
    server.start()
  }

  @After
  fun tearDown() {
    server.shutdown()
  }

  /** Calls that reached the client, connected or not. */
  private var calls = 0

  private fun loader(timeoutMs: Long = 5_000, maxBytes: Long = NottiInAppImageLoader.MAX_BYTES): NottiInAppImageLoader {
    val base = OkHttpClient.Builder()
      .sslSocketFactory(clientCerts.sslSocketFactory(), clientCerts.trustManager)
      .addInterceptor { chain ->
        calls++
        chain.proceed(chain.request())
      }
    return NottiInAppImageLoader(NottiInAppImageLoader.newClient(base, timeoutMs), sameThread, maxBytes)
  }

  private fun png(width: Int = 400, height: Int = 200): Buffer {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val out = ByteArrayOutputStream()
    bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
    return Buffer().write(out.toByteArray())
  }

  private fun image(width: Int = 400, height: Int = 200) = MockResponse().setBody(png(width, height))

  private fun url(path: String = "/a.png") = server.url(path).toString()

  private fun load(loader: NottiInAppImageLoader, url: String, maxSide: Int = 2000): Bitmap? {
    var result: Bitmap? = null
    var called = false
    loader.load(url, maxSide) {
      result = it
      called = true
    }
    assertEquals(true, called)
    return result
  }

  @Test
  fun `a non-https url is rejected before any connection`() {
    val http = url().replaceFirst("https://", "http://")
    assertNull(load(loader(), http))
    assertNull(load(loader(), "not a url"))
    assertEquals(0, calls)
    assertEquals(0, server.requestCount)
  }

  @Test
  fun `the request carries no Authorization, no Cookie and no Notti header`() {
    server.enqueue(image().addHeader("Set-Cookie", "tracker=1; Path=/"))
    server.enqueue(image())
    val loader = loader()

    assertNotNull(load(loader, url("/a.png")))
    assertNotNull(load(loader, url("/b.png")))

    repeat(2) {
      val request = server.takeRequest(5, TimeUnit.SECONDS)!!
      assertNull(request.getHeader("Authorization"))
      assertNull(request.getHeader("Cookie"))
      assertEquals(emptyList<String>(), request.headers.names().filter { it.lowercase().startsWith("x-") })
    }
  }

  @Test
  fun `a loaded image is decoded at full size when it fits`() {
    server.enqueue(image())
    val bitmap = load(loader(), url())!!
    assertEquals(400, bitmap.width)
    assertEquals(200, bitmap.height)
  }

  @Test
  fun `a large image is downsampled to the slot`() {
    server.enqueue(image(400, 200))
    val bitmap = load(loader(), url(), maxSide = 100)!!
    assertEquals(100, bitmap.width)
    assertEquals(50, bitmap.height)
  }

  @Test
  fun `a body past the size limit is aborted`() {
    // A valid image one byte over the limit, without a declared length.
    val body = png()
    val size = body.size
    server.enqueue(MockResponse().setChunkedBody(body, 64))
    assertNull(load(loader(maxBytes = size - 1), url()))
  }

  @Test
  fun `a body exactly at the size limit is loaded`() {
    val body = png()
    val size = body.size
    server.enqueue(MockResponse().setChunkedBody(body, 64))
    assertNotNull(load(loader(maxBytes = size), url()))
  }

  @Test
  fun `a declared length past the limit is refused`() {
    val body = png()
    val size = body.size
    server.enqueue(MockResponse().setBody(body))
    assertNull(load(loader(maxBytes = size - 1), url()))
  }

  @Test
  fun `an undecodable body is no image`() {
    server.enqueue(MockResponse().setBody("<html>not an image</html>"))
    assertNull(load(loader(), url()))
  }

  @Test
  fun `an error status is no image`() {
    server.enqueue(MockResponse().setResponseCode(404))
    assertNull(load(loader(), url()))
  }

  @Test
  fun `a redirect to http is refused`() {
    val http = url("/b.png").replaceFirst("https://", "http://")
    server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", http))

    assertNull(load(loader(), url()))
    assertNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals(1, server.requestCount)
  }

  @Test
  fun `a redirect to https is followed`() {
    server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", url("/b.png")))
    server.enqueue(image())

    assertNotNull(load(loader(), url()))
    assertEquals(2, server.requestCount)
  }

  @Test
  fun `a slow server times out into no image`() {
    server.enqueue(image().setHeadersDelay(3, TimeUnit.SECONDS))
    assertNull(load(loader(timeoutMs = 300), url()))
  }

  @Test
  fun `a cache hit makes no second request`() {
    server.enqueue(image())
    val loader = loader()

    val first = load(loader, url())
    val second = load(loader, url())

    assertNotNull(first)
    assertEquals(first, second)
    assertEquals(1, server.requestCount)
  }

  @Test
  fun `the cache keeps the five most recent images`() {
    val loader = loader()
    repeat(6) { server.enqueue(image()) }
    for (i in 0 until 6) load(loader, url("/$i.png"))

    // 1..5 are cached, 0 was evicted.
    server.enqueue(image())
    load(loader, url("/5.png"))
    assertEquals(6, server.requestCount)
    load(loader, url("/0.png"))
    assertEquals(7, server.requestCount)
  }

  @Test
  fun `clear empties the cache`() {
    server.enqueue(image())
    server.enqueue(image())
    val loader = loader()
    load(loader, url())
    loader.clear()
    load(loader, url())
    assertEquals(2, server.requestCount)
  }

  @Test
  fun `sample size is the largest power of two keeping the long side at least the slot`() {
    assertEquals(1, NottiInAppImageLoader.sampleSize(400, 200, 400))
    assertEquals(1, NottiInAppImageLoader.sampleSize(400, 200, 300))
    assertEquals(2, NottiInAppImageLoader.sampleSize(400, 200, 200))
    assertEquals(4, NottiInAppImageLoader.sampleSize(200, 400, 100))
    assertEquals(1, NottiInAppImageLoader.sampleSize(400, 200, 0))
  }
}
