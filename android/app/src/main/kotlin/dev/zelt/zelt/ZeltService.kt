package dev.zelt.zelt

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service so Android is less likely to kill the process that runs
 * the relay and polls mailboxes. The network code itself runs in the Flutter
 * engine; this service only holds the process at foreground priority.
 */
class ZeltService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannels(this)
        val n = statusNotification(this, intent?.getStringExtra("text") ?: "")
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(STATUS_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(STATUS_ID, n)
        }
        return START_STICKY
    }

    companion object {
        private const val STATUS_CHANNEL = "relay"
        private const val MESSAGE_CHANNEL = "messages"
        private const val STATUS_ID = 1
        private const val MESSAGE_ID = 2

        private fun ensureChannels(ctx: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = ctx.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(STATUS_CHANNEL, "Relay status", NotificationManager.IMPORTANCE_MIN)
            )
            nm.createNotificationChannel(
                NotificationChannel(MESSAGE_CHANNEL, "Messages", NotificationManager.IMPORTANCE_HIGH)
            )
        }

        private fun builder(ctx: Context, channel: String): Notification.Builder =
            if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, channel)
            else @Suppress("DEPRECATION") Notification.Builder(ctx)

        private fun openApp(ctx: Context): PendingIntent {
            val i = Intent(ctx, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            return PendingIntent.getActivity(ctx, 0, i, PendingIntent.FLAG_IMMUTABLE)
        }

        private fun statusNotification(ctx: Context, text: String): Notification =
            builder(ctx, STATUS_CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_zelt)
                .setContentTitle("zelt is running")
                .setContentText(text.ifEmpty { "Relaying for friends" })
                .setOngoing(true)
                .setContentIntent(openApp(ctx))
                .build()

        fun updateStatus(ctx: Context, text: String) {
            ensureChannels(ctx)
            ctx.getSystemService(NotificationManager::class.java)
                .notify(STATUS_ID, statusNotification(ctx, text))
        }

        /** Content-free on purpose: the lock screen never shows who wrote or what. */
        fun notifyMessage(ctx: Context, count: Int) {
            ensureChannels(ctx)
            val n = builder(ctx, MESSAGE_CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_zelt)
                .setContentTitle(if (count == 1) "New message" else "$count new messages")
                .setAutoCancel(true)
                .setVisibility(Notification.VISIBILITY_SECRET)
                .setContentIntent(openApp(ctx))
                .build()
            ctx.getSystemService(NotificationManager::class.java).notify(MESSAGE_ID, n)
        }

        fun clearMessages(ctx: Context) {
            ctx.getSystemService(NotificationManager::class.java).cancel(MESSAGE_ID)
        }
    }
}
