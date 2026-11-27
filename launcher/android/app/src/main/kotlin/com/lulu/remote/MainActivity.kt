package com.lulu.remote

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "lulu.remote/launch"

    private var pairingWorker: PairingWorkerBridge? = null

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        pairingWorker?.dispose()
        pairingWorker = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pairingWorker = PairingWorkerBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lulu.remote/activation")
            .setMethodCallHandler { call, result ->
                if (call.method == "readAndroidId") {
                    result.success(android.provider.Settings.Secure.getString(
                        contentResolver, android.provider.Settings.Secure.ANDROID_ID))
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isMoonlightInstalled" -> {
                        result.success(packageManager.getLaunchIntentForPackage("com.limelight") != null)
                    }
                    "openMoonlight" -> result.success(
                        openMoonlight(packageManager.getLaunchIntentForPackage("com.limelight"))
                    )
                    "launchShortcut" -> {
                        val uuid = call.argument<String>("uuid") ?: ""
                        val appName = call.argument<String>("appName") ?: ""
                        val appId = call.argument<Int>("appId")
                        result.success(launchShortcut(uuid, appName, appId))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun launchShortcut(uuid: String, appName: String, appId: Int?): Boolean {
        // Moonlight Android v12.2's exported ShortcutTrampoline resolves the
        // host from Moonlight's own database and reads AppId as a String.
        val intent = Intent().apply {
            component = ComponentName("com.limelight", "com.limelight.ShortcutTrampoline")
            putExtra("UUID", uuid)
            putExtra("AppName", appName)
            if (appId != null) putExtra("AppId", appId.toString())
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return openMoonlight(intent)
    }

    private fun openMoonlight(intent: Intent?): Boolean {
        if (intent == null) return false
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }
}
