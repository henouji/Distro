package com.homehub.homehub

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle

/**
 * Invisible activity that asks for screen-capture consent and starts
 * [ScreenCaptureService]. Being translucent, it can be launched on top of the
 * app currently playing on the TV without stopping it.
 */
class CaptureConsentActivity : Activity() {
    companion object {
        const val EXTRA_FPS = "fps"
        private const val REQUEST_CAPTURE = 4108

        /** Receives (started, errorMessage) once the request completes. */
        var callback: ((Boolean, String?) -> Unit)? = null

        private fun deliver(started: Boolean, error: String? = null) {
            val pending = callback
            callback = null
            pending?.invoke(started, error)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return
        val manager = getSystemService(MediaProjectionManager::class.java)
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CAPTURE)
        } catch (_: ActivityNotFoundException) {
            deliver(false, "This TV does not let apps capture the screen.")
            finishQuietly()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_CAPTURE) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        if (resultCode != RESULT_OK || data == null) {
            deliver(false)
            finishQuietly()
            return
        }
        val service = Intent(this, ScreenCaptureService::class.java)
            .putExtra(ScreenCaptureService.EXTRA_RESULT_CODE, resultCode)
            .putExtra(ScreenCaptureService.EXTRA_DATA, data)
            .putExtra(ScreenCaptureService.EXTRA_FPS, intent.getIntExtra(EXTRA_FPS, 5))
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(service)
            } else {
                startService(service)
            }
            deliver(true)
        } catch (error: Exception) {
            deliver(false, error.message ?: "Screen capture could not start.")
        }
        finishQuietly()
    }

    override fun onDestroy() {
        // Covers the system killing the request before a result arrives.
        if (isFinishing) deliver(false)
        super.onDestroy()
    }

    private fun finishQuietly() {
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
