package dev.zelt.zelt

import android.Manifest
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
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
                    "saveImage" -> saveImage(
                        call.argument<ByteArray>("bytes")!!,
                        call.argument<String>("name")!!,
                        call.argument<String>("mime")!!,
                        result,
                    )
                    "writeBackup" -> writeBackup(
                        call.argument<ByteArray>("bytes")!!,
                        call.argument<String>("name")!!,
                        result,
                    )
                    "readBackup" -> readBackup(call.argument<String>("name")!!, result)
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

    /**
     * Saves an image (re-encoded by the app, never received bytes) to
     * Pictures/Zelt, where the gallery shows it. Needs no permission on
     * Android 10+; older versions get it in the app's own pictures folder.
     */
    /**
     * The backup file in Downloads/Zelt (visible to file managers, USB and
     * sync apps), replaced in place on every backup. Runs off the UI thread:
     * a backup can be tens of megabytes.
     */
    private fun backupUri(name: String): Uri? {
        if (Build.VERSION.SDK_INT < 29) return null
        val projection = arrayOf(MediaStore.Downloads._ID)
        val sel = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?"
        contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI, projection, sel,
            arrayOf(name, Environment.DIRECTORY_DOWNLOADS + "/Zelt/"), null,
        )?.use { c ->
            if (c.moveToFirst()) {
                return Uri.withAppendedPath(MediaStore.Downloads.EXTERNAL_CONTENT_URI, c.getLong(0).toString())
            }
        }
        return null
    }

    private fun legacyBackupFile(name: String) =
        File(File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "Zelt").apply { mkdirs() }, name)

    private fun writeBackup(bytes: ByteArray, name: String, result: MethodChannel.Result) {
        Thread {
            try {
                val where: String
                if (Build.VERSION.SDK_INT >= 29) {
                    val existing = backupUri(name)
                    if (existing != null) {
                        contentResolver.openOutputStream(existing, "wt").use { it!!.write(bytes) }
                    } else {
                        val values = ContentValues().apply {
                            put(MediaStore.Downloads.DISPLAY_NAME, name)
                            put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Zelt")
                            put(MediaStore.Downloads.IS_PENDING, 1)
                        }
                        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                            ?: throw IllegalStateException("no Downloads folder")
                        contentResolver.openOutputStream(uri).use { it!!.write(bytes) }
                        values.clear()
                        values.put(MediaStore.Downloads.IS_PENDING, 0)
                        contentResolver.update(uri, values, null, null)
                    }
                    where = "Download/Zelt/$name"
                } else {
                    val f = legacyBackupFile(name)
                    val tmp = File(f.path + ".part")
                    tmp.writeBytes(bytes)
                    if (!tmp.renameTo(f)) throw IllegalStateException("cannot write ${f.path}")
                    where = f.path
                }
                runOnUiThread { result.success(where) }
            } catch (e: Exception) {
                runOnUiThread { result.error("backup", e.message, null) }
            }
        }.start()
    }

    private fun readBackup(name: String, result: MethodChannel.Result) {
        Thread {
            try {
                val bytes: ByteArray? = if (Build.VERSION.SDK_INT >= 29) {
                    backupUri(name)?.let { uri -> contentResolver.openInputStream(uri).use { it!!.readBytes() } }
                } else {
                    legacyBackupFile(name).takeIf { it.exists() }?.readBytes()
                }
                runOnUiThread { result.success(bytes) }
            } catch (e: Exception) {
                runOnUiThread { result.error("backup", e.message, null) }
            }
        }.start()
    }

    private fun saveImage(bytes: ByteArray, name: String, mime: String, result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name)
                    put(MediaStore.Images.Media.MIME_TYPE, mime)
                    put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Zelt")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("no gallery")
                contentResolver.openOutputStream(uri).use { it!!.write(bytes) }
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                result.success("Pictures/Zelt")
            } else {
                val dir = File(getExternalFilesDir(Environment.DIRECTORY_PICTURES), "Zelt").apply { mkdirs() }
                val f = File(dir, name)
                f.writeBytes(bytes)
                MediaScannerConnection.scanFile(this, arrayOf(f.path), arrayOf(mime), null)
                result.success(dir.path)
            }
        } catch (e: Exception) {
            result.error("save", e.message, null)
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
