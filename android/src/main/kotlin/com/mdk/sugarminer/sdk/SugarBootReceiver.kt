package com.mdk.sugarminer.sdk

import android.Manifest
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.core.content.ContextCompat

/**
 * What happens after the phone restarts.
 *
 * A mining worker that forgets the user's choice is not a worker; a miner that
 * *ignores* the user's choice is malware. So this receiver runs exactly one
 * check before doing anything:
 *
 *   1. did the user agree to the mining disclosure?   (`consent granted`)
 *   2. did the user stop it themselves?               (`stopped by user`)
 *   3. can we post the notification we are obliged to show? (`POST_NOTIFICATIONS`)
 *
 * All three yes → resume mining, notification first, exactly as if the app had
 * been opened. Any of them no → do nothing at all, and stay quiet.
 *
 * It also doubles as the re-arm tick: Android (and some OEMs especially) kill
 * background services after a while, so the same receiver is scheduled by
 * [scheduleReArm] and quietly puts the miner back if — and only if — the user's
 * choice still stands.
 */
class SugarBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val interesting = action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON" ||
            action == ACTION_RE_ARM
        if (!interesting) return

        // goAsync() buys a few extra seconds so the engine can spin up without
        // blocking the main thread (receivers are killed at ~10s)
        val pending = goAsync()
        Thread {
            try {
                resumeIfStillAllowed(context, action)
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun resumeIfStillAllowed(context: Context, action: String) {
        val prefs = context.getSharedPreferences(SugarMiningService.PREF_FILE, Context.MODE_PRIVATE)

        // ---- the user's decision, checked before anything else --------------
        val consented = prefs.getBoolean(SugarMiningService.PREF_CONSENT_GRANTED, false)
        val stoppedByUser = prefs.getBoolean(SugarMiningService.PREF_STOPPED_BY_USER, false)
        if (!consented || stoppedByUser) {
            // nothing to do, and nothing to announce
            return
        }

        // ---- the notification we are obliged to show -----------------------
        if (!canPostNotifications(context)) {
            // Mining without a visible notification is the one thing this SDK
            // does not do, so a reboot is not an excuse to start anyway.
            scheduleReArm(context)
            return
        }

        // ---- resume: notification first, then hashing ----------------------
        try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, SugarMiningService::class.java).apply {
                    action = SugarMiningService.ACTION_START
                    putExtra(SugarMiningService.EXTRA_TITLE, "Mining")
                    putExtra(
                        SugarMiningService.EXTRA_TEXT,
                        if (action == ACTION_RE_ARM) "resuming…" else "resuming after restart…"
                    )
                }
            )
        } catch (_: Exception) {
            // OEM policy or a background-start rule refused the service; the
            // headless engine below still gets a chance, and we re-arm anyway
        }

        HeadlessMinerEngine.start(context)
        scheduleReArm(context)
    }

    private fun canPostNotifications(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
    }

    companion object {
        const val ACTION_RE_ARM = "com.mdk.sugarminer.sdk.RE_ARM"

        /** Roughly how often the miner checks that it is still alive. */
        const val RE_ARM_INTERVAL_MS = 15 * 60 * 1000L

        /** Re-arm a little sooner the first time after a service death. */
        const val RE_ARM_FIRST_MS = 2 * 60 * 1000L

        /**
         * Schedules the next liveness check. Inexact on purpose: exact alarms
         * need a special permission, and a miner has no business demanding one.
         */
        fun scheduleReArm(context: Context, delayMs: Long = RE_ARM_INTERVAL_MS) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, SugarBootReceiver::class.java).setAction(ACTION_RE_ARM)
            val pi = PendingIntent.getBroadcast(
                context,
                0,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val at = SystemClock.elapsedRealtime() + delayMs
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    // setAndAllowWhileIdle: still fires in Doze, no special permission
                    am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
                } else {
                    am.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
                }
            } catch (_: Exception) {
                // no alarm permission on some ROMs — the service alone must do
            }
        }

        /** Called when the user stops mining: no more self-restarts, ever. */
        fun cancelReArm(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, SugarBootReceiver::class.java).setAction(ACTION_RE_ARM)
            val pi = PendingIntent.getBroadcast(
                context,
                0,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_NO_CREATE
            )
            if (pi != null) {
                am.cancel(pi)
                pi.cancel()
            }
        }
    }
}
