package com.mdk.sugarminer.sdk

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.view.FlutterCallbackInformation

/**
 * Runs the miner's Dart code with no activity on screen — the piece that makes
 * mining survive a phone restart.
 *
 * The host app registers one entrypoint (see `SugarMinerSdk.registerHeadlessEntrypoint`
 * in the Dart API); its handle is stored on the device, and this class spins up an
 * ordinary FlutterEngine to call it. Plugins are registered the same way the app's
 * own activity does, so `shared_preferences` and the SDK's method channel work
 * exactly as they do in the foreground.
 *
 * The user's choice is not re-checked here: [SugarBootReceiver] has already
 * verified consent, the user's stop, and notification permission before calling
 * [start], and the Dart side re-checks consent again for good measure.
 */
object HeadlessMinerEngine {

    @Volatile
    private var engine: FlutterEngine? = null

    @Volatile
    private var starting = false

    fun isRunning(): Boolean = engine != null

    /** Starts the mining entrypoint, or does nothing if it is already up. */
    @Synchronized
    fun start(context: Context) {
        if (engine != null || starting) return

        val appContext = context.applicationContext
        val prefs = appContext.getSharedPreferences(SugarMiningService.PREF_FILE, Context.MODE_PRIVATE)
        val handle = prefs.getLong(SugarMiningService.PREF_BOOT_CALLBACK, -1L)
        if (handle <= 0L) {
            // the app never registered a headless entrypoint, so there is nothing
            // to call — better to do nothing than to guess (running main() here
            // would pop UI out of nowhere)
            return
        }

        starting = true
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(appContext)
            loader.ensureInitializationComplete(appContext, null)

            val info = FlutterCallbackInformation.lookupCallbackInformation(handle) ?: return
            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                info.callbackName,
                info.callbackLibraryPath
            )

            val newEngine = FlutterEngine(appContext)
            registerPlugins(appContext, newEngine)
            newEngine.dartExecutor.executeDartEntrypoint(entrypoint)
            engine = newEngine
        } catch (_: Exception) {
            engine = null
        } finally {
            starting = false
        }
    }

    /**
     * The app's own GeneratedPluginRegistrant, found by name. This is how a
     * library can give a headless engine the same plugins the app's activity has
     * (shared_preferences, this SDK's channel, and anything else the app uses).
     */
    private fun registerPlugins(context: Context, engine: FlutterEngine) {
        try {
            val registrant = Class.forName("${context.packageName}.GeneratedPluginRegistrant")
            val method = registrant.getDeclaredMethod("registerWith", FlutterEngine::class.java)
            method.isAccessible = true
            method.invoke(null, engine)
        } catch (_: Exception) {
            // No registrant, or a release build stripped it: the miner still runs,
            // it just may lack other plugins' channels.
        }
    }

    /** Tears the engine down (used when mining is stopped for good). */
    @Synchronized
    fun stop() {
        try {
            engine?.destroy()
        } catch (_: Exception) {
        }
        engine = null
    }
}
