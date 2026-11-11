package com.homehub.homehub

import android.app.AppOpsManager
import android.app.UiModeManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Process
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    companion object {
        var tvSyncPreparing = false
            private set
        private const val ICON_SIZE = 96
        private const val BACKGROUND_BLOCKED =
            "HomeHub on the TV is in the background and is not allowed to open apps. " +
                "Allow \"Display over other apps\" for HomeHub on the TV."
    }

    private var resumed = false
    private var lightingPermissionResult: MethodChannel.Result? = null
    private var lightingRequest: Intent? = null

    private fun startLighting(intent: Intent, result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            result.success(null)
        } catch (error: Exception) {
            result.error("lighting_start", "Cannot start background lighting. Open HomeHub and retry.", null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4108) {
            val result = lightingPermissionResult ?: return
            lightingPermissionResult = null
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                val intent = lightingRequest
                lightingRequest = null
                if (intent != null) startLighting(intent, result)
                else result.error("lighting_start", "Open HomeHub and retry.", null)
            } else {
                lightingRequest = null
                result.error("notifications", "Allow notifications to run background lighting with a visible Stop control.", null)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        resumed = true
    }

    override fun onPause() {
        resumed = false
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "homehub/lighting").setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "pin", "motionStart" -> {
                    val id = call.argument<String>("lightId")
                    val intent = Intent(this, LightingService::class.java).setAction(call.method)
                        .putExtra("lightId", id)
                    if (call.method == "pin" && id.isNullOrBlank()) {
                        result.error("light", "Choose a light for notification controls.", null)
                    } else if (call.method == "pin" &&
                        (tvSyncPreparing || ScreenCaptureService.sink != null)
                    ) {
                        result.error("sync", "Stop TV Sync before showing notification light controls.", null)
                    } else if (lightingPermissionResult != null) {
                        result.error("busy", "Notification permission is already being requested.", null)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        lightingPermissionResult = result
                        lightingRequest = intent
                        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 4108)
                    } else {
                        startLighting(intent, result)
                    }
                }
                "stop", "hide", "motionStop" -> {
                    if (LightingService.running) {
                        startService(Intent(this, LightingService::class.java).setAction(call.method))
                    } else if (call.method == "motionStop") {
                        getSharedPreferences("lighting_runtime", MODE_PRIVATE).edit()
                            .putBoolean("motion", false)
                            .apply()
                    }
                    result.success(null)
                }
                "status" -> result.success(
                    mapOf(
                        "running" to (LightingService.running && LightingService.schedulesEnabled),
                        "motionEnabled" to (LightingService.running && LightingService.motionEnabled),
                        "quickLightId" to if (LightingService.running) LightingService.controlsLightId else null,
                        "batteryOptimized" to !getSystemService(PowerManager::class.java)
                            .isIgnoringBatteryOptimizations(packageName),
                        "error" to LightingService.error,
                    ),
                )
                "batterySettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("settings", "Open Android settings and allow unrestricted battery use for HomeHub.", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, "homehub/screen_capture").setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> {
                    if (LightingService.running && LightingService.controlsLightId != null) {
                        result.error("light_controls", "Hide notification light controls before starting TV Sync.", null)
                    } else {
                        tvSyncPreparing = true
                        result.success(null)
                    }
                }
                "start" -> requestCapture(call.argument<Int>("fps") ?: 5, result)
                "stop" -> {
                    tvSyncPreparing = false
                    stopService(Intent(this, ScreenCaptureService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "homehub/screen_capture/colors").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    ScreenCaptureService.sink = events
                }

                override fun onCancel(arguments: Any?) {
                    ScreenCaptureService.sink = null
                }
            },
        )
        MethodChannel(messenger, "homehub/tv").setMethodCallHandler { call, result ->
            when (call.method) {
                "isTv" -> result.success(isTv())
                "listApps" -> Thread {
                    val apps = try {
                        listApps()
                    } catch (_: Exception) {
                        emptyList()
                    }
                    runOnUiThread { result.success(apps) }
                }.start()
                "currentApp" -> result.success(currentApp())
                "launchApp" -> launchApp(call.argument<String>("package"), result)
                "moveToBack" -> result.success(moveTaskToBack(true))
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Light updates run in Dart; capture is pointless once the engine is gone.
        ScreenCaptureService.sink = null
        tvSyncPreparing = false
        stopService(Intent(this, ScreenCaptureService::class.java))
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** Android 10+ only lets background apps open activities with this grant. */
    private fun canOpenActivities() =
        resumed || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || Settings.canDrawOverlays(this)

    private fun requestCapture(requestedFps: Int, result: MethodChannel.Result) {
        if (LightingService.running && LightingService.controlsLightId != null) {
            result.error("light_controls", "Hide notification light controls before starting TV Sync.", null)
            return
        }
        if (CaptureConsentActivity.callback != null) {
            result.error("busy", "Screen capture permission is already being requested.", null)
            return
        }
        if (!canOpenActivities()) {
            result.error("background", BACKGROUND_BLOCKED, null)
            return
        }
        CaptureConsentActivity.callback = { started, error ->
            if (error != null) result.error("start_failed", error, null) else result.success(started)
        }
        try {
            startActivity(
                Intent(this, CaptureConsentActivity::class.java)
                    .putExtra(CaptureConsentActivity.EXTRA_FPS, requestedFps.coerceIn(1, 30))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
            )
        } catch (error: Exception) {
            CaptureConsentActivity.callback = null
            result.error("start_failed", error.message ?: "Screen capture could not start.", null)
        }
    }

    private fun isTv(): Boolean {
        val uiMode = getSystemService(UiModeManager::class.java)
        return uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    private fun listApps(): List<Map<String, Any>> {
        val apps = LinkedHashMap<String, Map<String, Any>>()
        for (category in listOf(Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER)) {
            val query = Intent(Intent.ACTION_MAIN).addCategory(category)
            for (info in packageManager.queryIntentActivities(query, 0)) {
                val name = info.activityInfo.packageName
                if (name == packageName || apps.containsKey(name)) continue
                val app = HashMap<String, Any>()
                app["package"] = name
                app["label"] = info.loadLabel(packageManager).toString()
                iconPng(info.loadIcon(packageManager))?.let { app["icon"] = it }
                apps[name] = app
            }
        }
        return apps.values.sortedBy { (it["label"] as String).lowercase() }
    }

    private fun iconPng(drawable: Drawable): ByteArray? = try {
        val bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888)
        val icon = drawable.mutate()
        icon.setBounds(0, 0, ICON_SIZE, ICON_SIZE)
        icon.draw(Canvas(bitmap))
        ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            out.toByteArray()
        }
    } catch (_: Exception) {
        null
    }

    private fun hasUsageAccess(): Boolean {
        val ops = getSystemService(AppOpsManager::class.java)
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName)
        } else {
            @Suppress("DEPRECATION")
            ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName)
        }
        if (mode == AppOpsManager.MODE_DEFAULT) {
            return checkSelfPermission(android.Manifest.permission.PACKAGE_USAGE_STATS) ==
                PackageManager.PERMISSION_GRANTED
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun currentApp(): Map<String, Any?> {
        if (!hasUsageAccess()) return mapOf("usageAccess" to false)
        val stats = getSystemService(UsageStatsManager::class.java)
        val now = System.currentTimeMillis()
        val events = stats.queryEvents(now - 12 * 60 * 60 * 1000L, now)
        val event = UsageEvents.Event()
        var current: String? = null
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            @Suppress("DEPRECATION")
            if (event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND &&
                event.packageName != "com.android.systemui" &&
                event.className != CaptureConsentActivity::class.java.name
            ) {
                current = event.packageName
            }
        }
        if (current == null) return mapOf("usageAccess" to true)
        val label = try {
            packageManager.getApplicationInfo(current, 0).loadLabel(packageManager).toString()
        } catch (_: PackageManager.NameNotFoundException) {
            current
        }
        return mapOf("usageAccess" to true, "package" to current, "label" to label)
    }

    private fun launchApp(name: String?, result: MethodChannel.Result) {
        val launch = name?.let {
            packageManager.getLeanbackLaunchIntentForPackage(it)
                ?: packageManager.getLaunchIntentForPackage(it)
        }
        if (launch == null) {
            result.error("not_found", "That app is not installed on the TV.", null)
            return
        }
        if (!canOpenActivities()) {
            result.error("background", BACKGROUND_BLOCKED, null)
            return
        }
        try {
            startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            result.success(null)
        } catch (error: Exception) {
            result.error("launch_failed", error.message ?: "The TV could not open that app.", null)
        }
    }
}
