package dev.zelt.zelt

import android.Manifest
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import java.io.File
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
                    "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull())
                    "kinfo" -> result.success(VaultKey.info())
                    "kwrap" -> try {
                        result.success(VaultKey.wrap(call.argument<ByteArray>("data")!!))
                    } catch (e: Exception) {
                        result.error("keystore", e.message, null)
                    }
                    "kunwrap" -> try {
                        result.success(VaultKey.unwrap(call.argument<ByteArray>("data")!!))
                    } catch (e: Exception) {
                        result.error("keystore", e.message, null)
                    }
                    "secure" -> {
                        // Blocks screenshots, screen recording and the recents
                        // thumbnail while a secret (the pairing QR) is shown.
                        val on = call.argument<Boolean>("on") == true
                        runOnUiThread {
                            if (on) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    "installApk" -> installApk(call.argument<String>("path")!!, result)
                    "background" -> {
                        // Keep the engine (and the relay) alive instead of finishing.
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Hands a verified APK to the system installer. Android shows its own
     * confirmation and refuses the update unless it is signed with the same
     * key as the installed app.
     */
    private fun installApk(path: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
            )
            result.error("permission", "Allow zelt to install updates, then tap Update again.", null)
            return
        }
        try {
            val installer = packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            params.setAppPackageName(packageName)
            val id = installer.createSession(params)
            installer.openSession(id).use { session ->
                File(path).inputStream().use { input ->
                    session.openWrite("zelt.apk", 0, -1).use { out ->
                        input.copyTo(out)
                        session.fsync(out)
                    }
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                val pi = PendingIntent.getBroadcast(
                    this, id, Intent(this, InstallResultReceiver::class.java), flags
                )
                session.commit(pi.intentSender)
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("install", e.message, null)
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
