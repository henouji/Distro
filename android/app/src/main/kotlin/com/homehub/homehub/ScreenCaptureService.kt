package com.homehub.homehub

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import java.nio.ByteBuffer

/**
 * Mirrors the screen into a tiny virtual display and streams the averaged
 * picture color to Dart as [red, green, blue, luma].
 */
class ScreenCaptureService : Service() {
    companion object {
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"
        const val EXTRA_FPS = "fps"
        private const val CHANNEL_ID = "tv_sync"
        private const val NOTIFICATION_ID = 4107
        private const val SAMPLE_WIDTH = 64
        private const val BLACK_ROW = 20

        @Volatile
        var sink: EventChannel.EventSink? = null
    }

    private val main = Handler(Looper.getMainLooper())
    private var thread: HandlerThread? = null
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var intervalMs = 200L
    private var lastFrame = 0L
    private var running = false
    private var sessionSink: EventChannel.EventSink? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val data: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(EXTRA_DATA)
        }
        if (running) return START_NOT_STICKY
        if (intent == null || data == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        // Android 14+ requires the foreground service before getMediaProjection.
        startInForeground()
        try {
            begin(
                intent.getIntExtra(EXTRA_RESULT_CODE, 0),
                data,
                intent.getIntExtra(EXTRA_FPS, 5),
            )
        } catch (error: Exception) {
            val message = error.message ?: "Screen capture failed on this TV."
            main.post { sink?.error("capture_failed", message, null) }
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "TV Sync", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("TV Sync is running")
            .setContentText("The light is following the screen.")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun begin(resultCode: Int, data: Intent, fps: Int) {
        intervalMs = 1000L / fps.coerceIn(1, 30)
        sessionSink = sink
        val manager = getSystemService(MediaProjectionManager::class.java)
        val projection = manager.getMediaProjection(resultCode, data)
            ?: throw IllegalStateException("Screen capture permission expired. Try again.")
        this.projection = projection
        val thread = HandlerThread("HomeHubTvSync").also { it.start() }
        this.thread = thread
        val handler = Handler(thread.looper)
        // Must be registered before createVirtualDisplay on Android 14+.
        projection.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() {
                    main.post { stopSelf() }
                }
            },
            handler,
        )
        val metrics = resources.displayMetrics
        val width = SAMPLE_WIDTH
        val height = (SAMPLE_WIDTH * metrics.heightPixels / maxOf(1, metrics.widthPixels))
            .coerceAtLeast(1)
        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        this.reader = reader
        reader.setOnImageAvailableListener({ onImage(it) }, handler)
        display = projection.createVirtualDisplay(
            "HomeHubTvSync",
            width,
            height,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface,
            null,
            handler,
        )
        running = true
    }

    private fun onImage(reader: ImageReader) {
        val image = try {
            reader.acquireLatestImage()
        } catch (_: IllegalStateException) {
            null
        } ?: return
        try {
            val now = SystemClock.elapsedRealtime()
            if (now - lastFrame < intervalMs) return
            lastFrame = now
            val plane = image.planes[0]
            val color = analyze(
                plane.buffer,
                image.width,
                image.height,
                plane.rowStride,
                plane.pixelStride,
            )
            main.post { sink?.success(color) }
        } finally {
            image.close()
        }
    }

    private fun analyze(
        buffer: ByteBuffer,
        width: Int,
        height: Int,
        rowStride: Int,
        pixelStride: Int,
    ): List<Double> {
        fun channel(index: Int) = buffer.get(index).toInt() and 0xFF
        fun rowMax(y: Int): Int {
            var max = 0
            for (x in 0 until width) {
                val i = y * rowStride + x * pixelStride
                max = maxOf(max, channel(i), channel(i + 1), channel(i + 2))
            }
            return max
        }

        // Skip letterbox bars so widescreen films are not dimmed.
        var top = 0
        while (top < height && rowMax(top) < BLACK_ROW) top++
        if (top == height) return listOf(0.0, 0.0, 0.0, 0.0)
        var bottom = height - 1
        while (bottom > top && rowMax(bottom) < BLACK_ROW) bottom--

        var lumaSum = 0.0
        var count = 0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var weights = 0.0
        for (y in top..bottom) {
            for (x in 0 until width) {
                val i = y * rowStride + x * pixelStride
                val r = channel(i)
                val g = channel(i + 1)
                val b = channel(i + 2)
                val max = maxOf(r, g, b)
                val min = minOf(r, g, b)
                lumaSum += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
                count++
                // Vivid, bright pixels define the scene color; greys barely count.
                val saturation = if (max == 0) 0.0 else (max - min).toDouble() / max
                val weight = 0.02 + saturation * saturation * (max / 255.0)
                red += r * weight
                green += g * weight
                blue += b * weight
                weights += weight
            }
        }
        return listOf(red / weights, green / weights, blue / weights, lumaSum / count)
    }

    override fun onDestroy() {
        running = false
        display?.release()
        display = null
        reader?.setOnImageAvailableListener(null, null)
        thread?.quitSafely()
        try {
            thread?.join(500)
        } catch (_: InterruptedException) {
        }
        thread = null
        reader?.close()
        reader = null
        try {
            projection?.stop()
        } catch (_: Exception) {
        }
        projection = null
        // Only end the stream this session was feeding, not a newer one.
        val owner = sessionSink
        main.post { if (owner != null && sink === owner) owner.endOfStream() }
        super.onDestroy()
    }
}
