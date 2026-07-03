package io.github.flochrislas.eztunein

import android.content.Context
import android.net.wifi.WifiManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Extends AudioServiceActivity so media-button intents (Bluetooth / headset /
 * car) are routed to the audio_service session.
 *
 * Also exposes a tiny MethodChannel ("ez_tunein/wifi_lock") that holds a
 * WifiManager.WifiLock while audio is playing. audio_service keeps a wake lock
 * and a foreground service, but not a Wi-Fi lock; the app's ICY metadata /
 * recording socket (a separate connection from ExoPlayer) needs the Wi-Fi radio
 * kept awake under Doze to keep feeding the recorder with the screen off. This
 * replaces the Wi-Fi lock flutter_foreground_task used to provide.
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
