package dev.zelt.zelt

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zelt/service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        askNotificationPermission()
                        val i = Intent(this, ZeltService::class.java)
                            .putExtra("text", call.argument<String>("text") ?: "")
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                        result.success(null)
                    }
                    "update" -> {
                        ZeltService.updateStatus(this, call.argument<String>("text") ?: "")
                        result.success(null)
                    }
                    "notify" -> {
                        ZeltService.notifyMessage(this, call.argument<Int>("count") ?: 1)
                        result.success(null)
                    }
                    "clearNotifications" -> {
                        ZeltService.clearMessages(this)
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, ZeltService::class.java))
                        result.success(null)
                    }
                    "background" -> {
                        // Keep the engine (and the relay) alive instead of finishing.
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }
}
