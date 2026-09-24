package com.mdk.sugarminer.sdk

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
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * The foreground service. Its only jobs are:
 *  1. post an always-visible notification (never optional, never hidden),
 *  2. give the user a Stop button in that notification,
 *  3. hold a partial wake lock so the CPU keeps running with the screen off,
 *  4. keep the app process alive so the Dart hashing isolate survives.
 *
 * All the actual mining lives in Dart; this class has no idea what a nonce is,
 * which is exactly how it should be.
 */
class SugarMiningService : Service() {

    companion object {
        const val CHANNEL_ID = "sugar_miner_sdk"
        const val NOTIFICATION_ID = 7331
        const val ACTION_START = "com.mdk.sugarminer.sdk.START"
        const val ACTION_UPDATE = "com.mdk.sugarminer.sdk.UPDATE"
        const val ACTION_STOP = "com.mdk.sugarminer.sdk.STOP"
        const val ACTION_STOP_BY_USER = "com.mdk.sugarminer.sdk.STOP_BY_USER"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_ICON = "iconName"
        const val EXTRA_COLOR = "colorArgb"

        /**
         * Set when the user themselves stopped mining, so the SDK never starts
         * again on its own. Written in the same shared-preferences file the Dart
         * `shared_preferences` plugin uses, so both sides see one flag.
         */
        const val PREF_FILE = "FlutterSharedPreferences"
        const val PREF_STOPPED_BY_USER = "flutter.sugar_sdk_user_stopped"

        @Volatile
        var running: Boolean = false
            private set

        @Volatile
        private var wakeLock: PowerManager.WakeLock? = null
    }

    private var iconName: String = "ic_sugar_miner"
    private var colorArgb: Int = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.getStringExtra(EXTRA_ICON)?.let { iconName = it }
        intent?.getIntExtra(EXTRA_COLOR, 0)?.let { if (it != 0) colorArgb = it }

        when (intent?.action) {
            ACTION_STOP -> {
                stopMining()
                return START_NOT_STICKY
            }
            ACTION_STOP_BY_USER -> {
                // The stop button in the notification. The user's word is final:
                // record it so the SDK will not resume by itself, then go.
                getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(PREF_STOPPED_BY_USER, true)
                    .apply()
                stopMining()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "Mining"
                val text = intent.getStringExtra(EXTRA_TEXT) ?: ""
                notify(title, text)
                return START_STICKY
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Mining"
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Starting the hashing core…"
                goForeground(title, text)
                return START_STICKY
            }
        }
    }

    private fun goForeground(title: String, text: String) {
        val notification = build(title, text)
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            0
        }
        try {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
        } catch (e: Exception) {
            stopSelf()
            return
        }
        running = true
        acquireWakeLock()
    }

    private fun notify(title: String, text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, build(title, text))
    }

    private fun build(title: String, text: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val openApp = launch?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        // Always present, never optional: the user must be able to stop mining
        // from the notification, whatever the host app configured.
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, SugarMiningService::class.java).setAction(ACTION_STOP_BY_USER),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val iconRes = resources.getIdentifier(iconName, "drawable", packageName)
            .takeIf { it != 0 } ?: R.drawable.ic_sugar_miner

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(iconRes)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            // a mining notification is never silent or dismissible: it is the
            // user's proof that their phone is working for someone else
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(0, "Stop mining", stopIntent)
            .apply {
                if (openApp != null) setContentIntent(openApp)
                if (colorArgb != 0) setColor(colorArgb)
            }
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Mining",
            // DEFAULT, never IMPORTANCE_MIN/NONE — the user must be able to see it
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Shown while this app is mining in the background."
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "sugar_miner_sdk:mining").apply {
            setReferenceCounted(false)
            // bounded: if this process dies the CPU is released, always
            acquire(60 * 60 * 1000L)
        }
    }

    private fun stopMining() {
        running = false
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
        super.onDestroy()
    }
}
