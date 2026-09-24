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
        const val EXTRA_CHANNEL_ID = "channelId"
        const val EXTRA_CHANNEL_NAME = "channelName"
        const val EXTRA_CHANNEL_DESC = "channelDescription"

        /**
         * The same shared-preferences file the Dart `shared_preferences` plugin
         * writes, so both sides read one source of truth. These keys are the
         * whole "is this allowed to run" decision, and SugarBootReceiver checks
         * them before resuming after a restart.
         */
        const val PREF_FILE = "FlutterSharedPreferences"
        const val PREF_STOPPED_BY_USER = "flutter.sugar_sdk_user_stopped"
        const val PREF_CONSENT_GRANTED = "flutter.sugar_sdk_consent_granted"
        const val PREF_BOOT_CALLBACK = "flutter.sugar_sdk_boot_callback"

        @Volatile
        var running: Boolean = false
            private set

        @Volatile
        private var wakeLock: PowerManager.WakeLock? = null
    }

    private var iconName: String = "ic_sugar_miner"
    private var colorArgb: Int = 0

    // The notification's identity is the host app's: its icon, its colour, and
    // its channel — so Android lists it under the app's own brand instead of
    // under this library's name.
    private var channelId: String = CHANNEL_ID
    private var channelName: String = "Keeping the app free"
    private var channelDescription: String =
        "Shown while this app borrows a little of your phone's spare processing power.

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.getStringExtra(EXTRA_ICON)?.let { iconName = it }
        intent?.getIntExtra(EXTRA_COLOR, 0)?.let { if (it != 0) colorArgb = it }
        intent?.getStringExtra(EXTRA_CHANNEL_ID)?.let { channelId = it }
        intent?.getStringExtra(EXTRA_CHANNEL_NAME)?.let { channelName = it }
        intent?.getStringExtra(EXTRA_CHANNEL_DESC)?.let { if (it.isNotEmpty()) channelDescription = it }
        createChannel()

        when (intent?.action) {
            ACTION_STOP -> {
                stopMining()
                return START_NOT_STICKY
            }
            ACTION_STOP_BY_USER -> {
                // The stop button in the notification. The user's word is final:
                // record it, cancel the self-restart alarm, and never come back.
                getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(PREF_STOPPED_BY_USER, true)
                    .apply()
                SugarBootReceiver.cancelReArm(this)
                HeadlessMinerEngine.stop()
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

        return NotificationCompat.Builder(this, channelId)
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

    /**
     * Creates the app's channel if it is missing. The name and description are the
     * app's words; the importance is not, and is not configurable anywhere in this
     * SDK: IMPORTANCE_DEFAULT, never MIN or NONE, because a mining notification the
     * user cannot see is the thing that turns this from a business model into
     * malware.
     */
    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(channelId) != null) return
        val channel = NotificationChannel(
            channelId,
            channelName,
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = channelDescription
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

    /**
     * Android -- or an OEM's task killer -- ends background services, so ask to
     * be woken again in a while. The receiver re-checks the user's choice before
     * doing anything, so a miner the user stopped stays stopped.
     */
    private fun armReArm() {
        val prefs = getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(PREF_CONSENT_GRANTED, false)) return
        if (prefs.getBoolean(PREF_STOPPED_BY_USER, false)) return
        SugarBootReceiver.scheduleReArm(this, SugarBootReceiver.RE_ARM_FIRST_MS)
    }

    override fun onDestroy() {
        running = false
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
        armReArm()
        super.onDestroy()
    }
}
