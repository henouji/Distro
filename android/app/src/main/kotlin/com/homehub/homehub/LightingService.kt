package com.homehub.homehub

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.RemoteViews
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class LightingService : Service() {
    companion object {
        private const val CHANNEL_ID = "dynamic_lighting"
        private const val NOTIFICATION_ID = 4108
        private const val MOTION_STOP_GRACE_MS = 300_000L
        var running = false
            private set
        var schedulesEnabled = false
            private set
        var motionEnabled = false
            private set
        var controlsLightId: String? = null
            private set
        var error: String? = null
            private set
    }

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var ready = false
    private var busy = false
    private var quickInfo: Map<*, *>? = null
    private var scheduleError: String? = null
    private var motionError: String? = null
    private var controlError: String? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val main = Handler(Looper.getMainLooper())
    private val startupTimeout = Runnable {
        if (!ready) {
            error = "Lighting could not initialize. Reopen HomeHub and retry."
            stopSelf()
        }
    }
    private val stopWhenIdle = Runnable {
        if (!schedulesEnabled && !motionEnabled && controlsLightId == null) {
            stopSelf()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val saved = getSharedPreferences("lighting_runtime", MODE_PRIVATE)
        schedulesEnabled = saved.getBoolean("schedules", false)
        motionEnabled = saved.getBoolean("motion", false)
        controlsLightId = saved.getString("lightId", null)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!running && intent?.action in listOf("start", "pin")) {
            schedulesEnabled = false
            controlsLightId = null
        }
        when (intent?.action) {
            "start" -> {
                schedulesEnabled = true
                main.removeCallbacks(stopWhenIdle)
            }
            "stop" -> {
                schedulesEnabled = false
                scheduleError = null
            }
            "pin" -> {
                controlsLightId = intent.getStringExtra("lightId")
                quickInfo = null
                controlError = null
                main.removeCallbacks(stopWhenIdle)
            }
            "hide" -> {
                controlsLightId = null
                quickInfo = null
                controlError = null
            }
            "stopAll" -> {
                schedulesEnabled = false
                motionEnabled = false
                controlsLightId = null
                motionError = null
                main.removeCallbacks(stopWhenIdle)
                main.postDelayed(stopWhenIdle, MOTION_STOP_GRACE_MS)
            }
            "motionStart" -> {
                motionEnabled = true
                motionError = null
                main.removeCallbacks(stopWhenIdle)
            }
            "motionStop" -> {
                motionEnabled = false
                motionError = null
                main.removeCallbacks(stopWhenIdle)
                main.postDelayed(stopWhenIdle, MOTION_STOP_GRACE_MS)
            }
        }
        getSharedPreferences("lighting_runtime", MODE_PRIVATE).edit()
            .putBoolean("schedules", schedulesEnabled)
            .putBoolean("motion", motionEnabled)
            .putString("lightId", controlsLightId)
            .apply()
        if (!schedulesEnabled && !motionEnabled && controlsLightId == null) {
            error = null
            if (!running || intent?.action !in listOf("motionStop", "stopAll")) {
                stopSelf()
                return START_NOT_STICKY
            }
            updateNotification()
            return START_STICKY
        }
        if (running) {
            if (intent?.action == "control" &&
                intent.getStringExtra("lightId") == controlsLightId
            ) {
                control(intent.getStringExtra("control") ?: "refresh")
            } else if (intent?.action == "pin") {
                control("refresh")
            }
            updateNotification()
            return START_STICKY
        }
        error = null
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Lighting controls", NotificationManager.IMPORTANCE_LOW),
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID, notification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification())
        }
        try {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "HomeHub:Lighting")
                .also { it.acquire() }
            @Suppress("DEPRECATION")
            wifiLock = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager)
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "HomeHub:Lighting")
                .also { it.acquire() }
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val backgroundEngine = FlutterEngine(applicationContext)
            engine = backgroundEngine
            channel = MethodChannel(backgroundEngine.dartExecutor.binaryMessenger, "homehub/lighting")
                .also { bridge ->
                    bridge.setMethodCallHandler { call, result ->
                        when (call.method) {
                            "ready" -> {
                                ready = true
                                result.success(null)
                                control("refresh")
                            }
                            "configuration" -> result.success(
                                mapOf("schedules" to schedulesEnabled, "motion" to motionEnabled),
                            )
                            "report" -> {
                                scheduleError = call.argument<String>("error")
                                motionError = call.argument<String>("motionError")
                                updateNotification()
                                result.success(null)
                                control("refresh")
                            }
                            else -> result.notImplemented()
                        }
                    }
                }
            backgroundEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "lightingMain"),
            )
            running = true
            main.postDelayed(startupTimeout, 30_000)
        } catch (failure: Exception) {
            error = "Lighting controls could not start. Reopen HomeHub and retry."
            manager.notify(NOTIFICATION_ID, notification())
            stopSelf()
        }
        return START_STICKY
    }

    private fun control(action: String) {
        val id = controlsLightId ?: return
        if (!ready || busy) return
        if (MainActivity.tvSyncPreparing || ScreenCaptureService.sink != null) {
            controlError = "Stop TV Sync before using notification light controls."
            updateNotification()
            return
        }
        busy = true
        channel?.invokeMethod("control", mapOf("lightId" to id, "action" to action),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    busy = false
                    if (controlsLightId != id) {
                        control("refresh")
                        return
                    }
                    val info = result as? Map<*, *>
                    controlError = info?.get("error") as? String
                    if (controlError == null) quickInfo = info
                    updateNotification()
                }
                override fun error(code: String, message: String?, details: Any?) {
                    busy = false
                    if (controlsLightId != id) {
                        control("refresh")
                        return
                    }
                    controlError = "The notification light command failed. Open HomeHub and retry."
                    updateNotification()
                }
                override fun notImplemented() {
                    error("unavailable", null, null)
                }
            },
        )
    }

    private fun updateNotification() {
        error = listOfNotNull(scheduleError, motionError, controlError)
            .joinToString("\n").ifEmpty { null }
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
    }

    private fun actionIntent(action: String, control: String? = null): PendingIntent {
        val intent = Intent(this, LightingService::class.java)
            .setAction(action)
            .setData(android.net.Uri.Builder().scheme("homehub").authority("lighting")
                .appendPath(action).appendPath(control ?: "").appendPath(controlsLightId ?: "").build())
            .putExtra("lightId", controlsLightId)
            .putExtra("control", control)
        return PendingIntent.getService(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setColor(getColor(R.color.lighting_notification_surface))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(if (error != null) "Lighting needs attention" else "HomeHub lighting")
            .setContentText(if (error != null) "Open HomeHub to see the error." else
                when {
                    schedulesEnabled && motionEnabled -> "Schedules and camera motion lighting are running."
                    schedulesEnabled -> "Dynamic lighting schedules are running."
                    motionEnabled -> "Camera motion lighting is monitoring."
                    else -> "Quick light controls are ready."
                })
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, "Stop all", actionIntent("stopAll")).build())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setColorized(true)
        }
        if (controlsLightId != null) {
            val views = RemoteViews(packageName, R.layout.lighting_notification)
            // Decorated collapsed notifications allow only 48dp of custom content.
            val compact = RemoteViews(packageName, R.layout.lighting_notification_compact)
            val info = quickInfo
            views.setTextViewText(R.id.light_name, info?.get("name") as? String ?: "Light controls")
            views.setTextViewText(R.id.light_status, when {
                error != null -> "Command failed - open HomeHub"
                busy -> "Updating light..."
                info == null -> "Connecting..."
                else -> "${if (info["on"] == true) "On" else "Off"} / ${info["brightness"]}% brightness"
            })
            for (layout in listOf(views, compact)) {
                layout.setTextViewText(R.id.light_power, if (info?.get("on") == true) "Off" else "On")
                for ((view, command) in listOf(
                    R.id.light_power to "toggle", R.id.light_dim to "dim", R.id.light_brighten to "brighten",
                )) {
                    layout.setOnClickPendingIntent(view, actionIntent("control", command))
                }
            }
            for ((view, command) in listOf(
                R.id.light_warm to "warm", R.id.light_cool to "cool",
                R.id.light_red to "red", R.id.light_amber to "amber",
                R.id.light_green to "green", R.id.light_blue to "blue",
            )) {
                views.setOnClickPendingIntent(view, actionIntent("control", command))
            }
            compact.setOnClickPendingIntent(R.id.light_white, actionIntent("control", "white"))
            compact.setOnClickPendingIntent(R.id.light_color, actionIntent("control", "color"))
            for ((view, capability) in listOf(
                R.id.light_dim to "hasBrightness", R.id.light_brighten to "hasBrightness",
                R.id.light_white to "hasTemperature", R.id.light_color to "hasColor",
            )) {
                compact.setViewVisibility(view,
                    if (info?.get(capability) == true) View.VISIBLE else View.GONE)
            }
            views.setViewVisibility(R.id.brightness_controls,
                if (info?.get("hasBrightness") == true) View.VISIBLE else View.GONE)
            views.setViewVisibility(R.id.temperature_controls,
                if (info?.get("hasTemperature") == true) View.VISIBLE else View.GONE)
            views.setViewVisibility(R.id.color_controls,
                if (info?.get("hasColor") == true) View.VISIBLE else View.GONE)
            builder.setStyle(Notification.DecoratedCustomViewStyle())
                .setCustomContentView(compact)
                .setCustomBigContentView(views)
                .addAction(Notification.Action.Builder(null, "Refresh", actionIntent("control", "refresh")).build())
        }
        return builder.build()
    }

    override fun onDestroy() {
        running = false
        main.removeCallbacks(startupTimeout)
        engine?.destroy()
        engine = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }
}
