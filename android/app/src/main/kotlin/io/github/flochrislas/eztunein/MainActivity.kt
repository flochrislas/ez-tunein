package io.github.flochrislas.eztunein

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Extends AudioServiceActivity so media-button intents (Bluetooth / headset /
 * car) are routed to the audio_service session.
 *
 * Also exposes two tiny MethodChannels:
 *  - "ez_tunein/wifi_lock" holds a WifiManager.WifiLock while audio is playing.
 *    audio_service keeps a wake lock and a foreground service, but not a Wi-Fi
 *    lock; the app's ICY metadata / recording socket (a separate connection from
 *    ExoPlayer) needs the Wi-Fi radio kept awake under Doze to keep feeding the
 *    recorder with the screen off. This replaces the Wi-Fi lock
 *    flutter_foreground_task used to provide.
 *  - "ez_tunein/notifications" requests the Android 13+ POST_NOTIFICATIONS
 *    runtime permission. Without it audio_service can't post its foreground-
 *    service media notification, so no lock-screen/notification controls show
 *    AND the foreground service can't hold the app awake — playback then dies
 *    ~20s after the screen turns off.
 */
class MainActivity : AudioServiceActivity() {
    private var wifiLock: WifiManager.WifiLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ez_tunein/wifi_lock"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> { acquireWifiLock(); result.success(null) }
                "release" -> { releaseWifiLock(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ez_tunein/notifications"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> { requestNotificationPermission(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    // Fire the OS permission dialog if POST_NOTIFICATIONS isn't already granted
    // (Android 13 / API 33+ only — it's install-time granted below that). We
    // don't need the result back in Dart: audio_service re-posts its notification
    // on the next playbackState change once the user grants it.
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    @Suppress("DEPRECATION") // WIFI_MODE_FULL_HIGH_PERF is what a live stream needs.
    private fun acquireWifiLock() {
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "ez_tunein:stream")
        }
        wifiLock?.let { if (!it.isHeld) it.acquire() }
    }

    private fun releaseWifiLock() {
        wifiLock?.let { if (it.isHeld) it.release() }
    }

    override fun onDestroy() {
        releaseWifiLock()
        super.onDestroy()
    }
}
