package com.mdk.sugarminer.sdk

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.text.method.LinkMovementMethod
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ClickableSpan
import android.text.util.Linkify
import android.view.View
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.content.ContextCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Attaching the miner to an app that does not want to write Dart.
 *
 * The host app puts its configuration in its own AndroidManifest, calls
 * [install] once from its launcher activity, and nothing else:
 *
 * ```xml
 * <meta-data android:name="com.mdk.sugarminer.PAYOUT_ADDRESS" android:value="sugar1q…" />
 * <meta-data android:name="com.mdk.sugarminer.APP_NAME"      android:value="Sweet Widgets" />
 * <meta-data android:name="com.mdk.sugarminer.MINING_NOTICE" android:value="…a real sentence…" />
 * ```
 *
 * ```kotlin
 * override fun onCreate(savedInstanceState: Bundle?) {
 *     super.onCreate(savedInstanceState)
 *     SugarMinerNative.install(this)          // ← the whole integration
 * }
 * ```
 *
 * What that one line does, in order, and nothing else:
 *
 *  1. reads the metadata; **any missing or unusable field stops it dead**,
 *  2. if consent for *this exact* notice and terms is not already recorded in the
 *     prefs the Dart side reads, shows a dialog with that notice, the terms link
 *     and the privacy link — the same words, whether the app is Dart-driven or not,
 *  3. on "agree": records the consent (with the notice version, so editing the
 *     words asks again), asks for POST_NOTIFICATIONS, offers the battery
 *     exemption, and starts the SDK's own headless entrypoint,
 *  4. on "no thanks": records the refusal, and the miner will not start — not now,
 *     not after a reboot, not from the re-arm alarm.
 *
 * There is deliberately no way to skip step 2. No "auto-consent" flag, no
 * "silent" variant, no way to start the engine without the prefs showing that a
 * human agreed to these words.
 */
object SugarMinerNative {

    private const val NS = "com.mdk.sugarminer."
    private const val ENTRYPOINT = "sugarMinerSdkHeadless"
    private const val ENTRYPOINT_LIBRARY = "package:sugar_miner_sdk/src/native_boot.dart"

    /** Metadata read from the host app's manifest. */
    data class Config(
        val payoutAddress: String,
        val appName: String,
        val ownerName: String,
        val miningNotice: String,
        val noticeVersion: String,
        val termsUrl: String,
        val termsVersion: String,
        val privacyUrl: String,
        val cpuSharePercent: Int,
        val dailyCapMinutes: Int,
        val requireUnmetered: Boolean,
    ) {
        /** Identical to MiningDisclosure.consentVersion on the Dart side. */
        val consentVersion: String
            get() = "$noticeVersion|terms:$termsVersion|privacy:$privacyUrl"
    }

    fun readConfig(context: Context): Config? {
        val pm = context.packageManager
        val info = if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(
                PackageManager.GET_META_DATA.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(context.packageName, PackageManager.GET_META_DATA)
        }
        val meta = info.applicationInfo?.metaData ?: return null

        fun text(key: String): String = meta.getString(NS + key)?.trim().orEmpty()
        fun int(key: String, fallback: Int): Int =
            meta.getString(NS + key)?.trim()?.toIntOrNull() ?: fallback
        fun flag(key: String, fallback: Boolean): Boolean =
            meta.getString(NS + key)?.trim()?.let { it == "true" || it == "1" } ?: fallback

        val address = text("PAYOUT_ADDRESS")
        val notice = text("MINING_NOTICE")
        // A payout address the miner would refuse, or no notice at all, means this
        // app is not configured to mine — and mining is not something to guess at.
        if (!Regex("^(sugar1|tugar1)[0-9a-z]{25,}$").matches(address)) return null
        if (notice.length < 40) return null

        return Config(
            payoutAddress = address,
            appName = text("APP_NAME").ifEmpty { "This app" },
            ownerName = text("OWNER_NAME").ifEmpty { "the app developer" },
            miningNotice = notice,
            noticeVersion = text("NOTICE_VERSION").ifEmpty { "1.0.0" },
            termsUrl = text("TERMS_URL"),
            termsVersion = text("TERMS_VERSION"),
            privacyUrl = text("PRIVACY_URL"),
            cpuSharePercent = int("CPU_SHARE_PERCENT", 25).coerceIn(1, 80),
            dailyCapMinutes = int("DAILY_CAP_MINUTES", 480).coerceAtLeast(0),
            requireUnmetered = flag("REQUIRE_UNMETERED", true),
        )
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(
            SugarMiningService.PREF_FILE, Context.MODE_PRIVATE)

    private fun consentRecorded(context: Context, version: String): Boolean {
        val p = prefs(context)
        return p.getBoolean(SugarMiningService.PREF_CONSENT_GRANTED, false) &&
            p.getString("flutter.sugar_sdk_consent_version", "") == version &&
            !p.getBoolean(SugarMiningService.PREF_STOPPED_BY_USER, false)
    }

    /**
     * The whole integration. Safe to call from `onCreate` on every launch: it
     * starts the miner if the user has already agreed, and asks once if not.
     */
    fun install(activity: Activity) {
        val config = readConfig(activity) ?: return

        if (consentRecorded(activity, config.consentVersion)) {
            startMining(activity)
            return
        }

        // The user said no before, or has stopped mining. Asking again on every
        // launch would be nagging; the app's own UI is the place to change that
        // answer, not a dialog that reappears until it gets a yes.
        if (refused(activity)) return

        showConsentDialog(activity, config)
    }

    private fun refused(context: Context): Boolean {
        val p = prefs(context)
        return p.getBoolean(SugarMiningService.PREF_STOPPED_BY_USER, false) ||
            p.contains("flutter.sugar_sdk_consent_refused")
    }

    private fun showConsentDialog(activity: Activity, config: Config) {
        // The dialog the user sees: the integrator's notice in full, plus where to
        // read the details, plus what happens either way. Links are tappable.
        val body = SpannableStringBuilder()
        body.append(config.miningNotice)
        body.append("\n\n")
        body.append("Mining runs only while you allow it, always shows a notification, "
            + "and stops when you say so.")
        if (config.termsUrl.isNotEmpty()) {
            body.append("\n\nTerms: ")
            body.append(link(config.termsUrl, config.termsUrl) { open(activity, config.termsUrl) })
            if (config.termsVersion.isNotEmpty()) body.append(" (v${config.termsVersion})")
        }
        if (config.privacyUrl.isNotEmpty()) {
            body.append("\nPrivacy: ")
            body.append(link(config.privacyUrl, config.privacyUrl) { open(activity, config.privacyUrl) })
        }
        body.append("\n\nUses up to ${config.cpuSharePercent}% of one processor core, pauses on "
            + "heat, low battery and mobile data"
            + (if (config.dailyCapMinutes > 0) ", and stops after ${config.dailyCapMinutes} minutes a day."
               else "."))

        val text = TextView(activity).apply {
            text = body
            movementMethod = LinkMovementMethod.getInstance()
            Linkify.addLinks(this, Linkify.WEB_URLS)
            setPadding(48, 32, 48, 16)
            textSize = 14f
        }
        val scroll = ScrollView(activity).apply { addView(text) }

        AlertDialog.Builder(activity)
            .setTitle("May ${config.appName} mine SUGAR?")
            .setView(scroll)
            .setCancelable(false)
            .setPositiveButton("Agree and start") { _, _ -> agree(activity, config) }
            .setNegativeButton("No thanks") { _, _ -> refuse(activity) }
            .show()
    }

    private fun link(label: String, url: String, onClick: () -> Unit) =
        SpannableStringBuilder(label).apply {
            setSpan(object : ClickableSpan() {
                override fun onClick(widget: View) = onClick()
            }, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }

    private fun open(activity: Activity, url: String) {
        try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        } catch (_: Exception) {
        }
    }

    private fun agree(activity: Activity, config: Config) {
        val p = prefs(activity)
        val when_ = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(Date())
        // The same four values the Dart consent store writes, so the two paths can
        // never disagree about whether this user agreed, or to which words.
        p.edit()
            .putBoolean(SugarMiningService.PREF_CONSENT_GRANTED, true)
            .putString("flutter.sugar_sdk_consent_version", config.consentVersion)
            .putString("flutter.sugar_sdk_consent_at", when_)
            .putBoolean(SugarMiningService.PREF_STOPPED_BY_USER, false)
            .remove("flutter.sugar_sdk_consent_refused")
            .apply()

        requestNotificationPermission(activity)
        offerBatteryExemption(activity)
        startMining(activity)
    }

    private fun refuse(activity: Activity) {
        prefs(activity).edit()
            .putBoolean(SugarMiningService.PREF_CONSENT_GRANTED, false)
            .putBoolean(SugarMiningService.PREF_STOPPED_BY_USER, true)
            .putBoolean("flutter.sugar_sdk_consent_refused", true)
            .apply()
        HeadlessMinerEngine.stop()
    }

    /** Where the user's own screen or our dialog turns the answer back on. */
    fun forgetRefusal(context: Context) {
        prefs(context).edit()
            .putBoolean(SugarMiningService.PREF_STOPPED_BY_USER, false)
            .remove("flutter.sugar_sdk_consent_refused")
            .apply()
    }

    private fun requestNotificationPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT < 33) return
        val granted = activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0x5E6B)
        }
    }

    private fun offerBatteryExemption(activity: Activity) {
        if (Build.VERSION.SDK_INT < 23) return
        val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(activity.packageName)) return
        try {
            activity.startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:${activity.packageName}"))
            )
        } catch (_: Exception) {
            // Some OEMs refuse the direct intent; the SDK's own settings shortcut
            // (ServiceBridge.openBatterySettings) remains available to the app.
        }
    }

    private fun startMining(context: Context) {
        // Belt and braces: the engine is only ever started for a consent that is
        // already on disk for this exact version of the notice.
        val config = readConfig(context) ?: return
        if (!consentRecorded(context, config.consentVersion)) return

        // The notification is not optional, and neither is the service that owns
        // it: without POST_NOTIFICATIONS this would be silent mining, which this
        // SDK does not do. The re-arm path behaves the same way.
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        // The service first: it owns the notification, and without it Android
        // would kill the process the moment the engine started working.
        ContextCompat.startForegroundService(
            context,
            Intent(context, SugarMiningService::class.java)
                .setAction(SugarMiningService.ACTION_START)
        )
        HeadlessMinerEngine.startNamed(context, ENTRYPOINT, ENTRYPOINT_LIBRARY)
    }

    /**
     * Stops mining for good, from the app. "For good" is literal: the re-arm alarm
     * is cancelled and the flag the boot receiver checks is set, so nothing brings
     * it back until the user asks again (via [forgetRefusal] plus [install]).
     */
    fun stop(context: Context) {
        SugarBootReceiver.cancelReArm(context)
        HeadlessMinerEngine.stop()
        ContextCompat.startForegroundService(
            context,
            Intent(context, SugarMiningService::class.java)
                .setAction(SugarMiningService.ACTION_STOP_BY_USER)
        )
    }
}
