package com.mdk.sugarminer.sdk

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Small platform surface for the SDK: start/stop the mining notification, report
 * what the phone is doing, and ask for the notification permission.
 *
 * There is deliberately no method here that hides the notification, fakes the
 * app's identity, or starts mining on its own. Those are not omissions.
 */
class SugarMinerPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null

    private companion object {
        const val PERMISSION_REQUEST_CODE = 0x5E6A // "SEJA"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "sugar_miner_sdk")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceState" -> result.success(deviceState())

            "hasNotificationPermission" -> result.success(hasNotificationPermission())

            "requestNotificationPermission" -> requestNotificationPermission(result)

            "startForeground" -> {
                val intent = Intent(appContext, SugarMiningService::class.java).apply {
                    action = SugarMiningService.ACTION_START
                    putExtra(SugarMiningService.EXTRA_TITLE, call.argument<String>("title"))
                    putExtra(SugarMiningService.EXTRA_TEXT, call.argument<String>("text"))
                }
                ContextCompat.startForegroundService(appContext, intent)
                result.success(true)
            }

            "updateNotification" -> {
                val intent = Intent(appContext, SugarMiningService::class.java).apply {
                    action = SugarMiningService.ACTION_UPDATE
                    putExtra(SugarMiningService.EXTRA_TITLE, call.argument<String>("title"))
                    putExtra(SugarMiningService.EXTRA_TEXT, call.argument<String>("text"))
                }
                ContextCompat.startForegroundService(appContext, intent)
                result.success(true)
            }

            "stopForeground" -> {
                val intent = Intent(appContext, SugarMiningService::class.java).apply {
                    action = SugarMiningService.ACTION_STOP
                }
                appContext.startService(intent)
                result.success(true)
            }

            "isForeground" -> result.success(SugarMiningService.running)

            "openBatterySettings" -> {
                val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    appContext.startActivity(intent)
                } catch (_: Exception) {
                }
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    /** What the phone is doing, for the Dart-side policy engine. */
    private fun deviceState(): Map<String, Any?> {
        val battery = appContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))

        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL ||
            (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0

        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val percent = if (level >= 0 && scale > 0) level * 100 / scale else -1

        val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        var onWifi = false
        var connectionCostly = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            cm.activeNetwork?.let { network ->
                cm.getNetworkCapabilities(network)?.let { caps ->
                    onWifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    connectionCostly = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                }
            }
        }

        val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        val thermal = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            pm.currentThermalStatus
        } else {
            0
        }

        return mapOf(
            "charging" to charging,
            "batteryPercent" to percent,
            "onWifi" to onWifi,
            "metered" to connectionCostly,
            "screenOn" to pm.isInteractive,
            "thermalStatus" to thermal,
            "powerSaveMode" to pm.isPowerSaveMode,
        )
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (hasNotificationPermission()) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            // no UI attached: cannot ask, and mining without a visible
            // notification is not something this SDK will do
            result.success(false)
            return
        }
        if (pendingResult != null) {
            result.success(false)
            return
        }
        pendingResult = result
        ActivityCompat.requestPermissions(
            act,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST_CODE
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingResult?.success(granted)
        pendingResult = null
        return true
    }
}
