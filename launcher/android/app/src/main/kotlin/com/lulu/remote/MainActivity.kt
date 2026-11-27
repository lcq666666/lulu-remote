package com.lulu.remote

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Android side of the Moonlight launch.
 *
 * Two paths, in order:
 *
 * (a) launchGame — direct Game Intent with LULU's OWN pairing cert.
 *     This is an UNVERIFIED prototype. The extra keys below come from the
 *     research report / DeepWiki on moonlight-vplus (Game.kt /
 *     ServerHelper.java), NOT from a run against Moonlight Android v12.2.
 *     Test on a real phone with Moonlight Android installed before
 *     calling it working:
 *       - If the Game activity finishes immediately, the AppId is wrong
 *         (read it from /applist after pairing) or the cert is rejected.
 *       - If it works, LULU's in-app pairing is complete on Android too.
 *     If it does not work, the fallback is forking Moonlight Android
 *     (whole fork GPL-3.0) — out of v1 scope. Do not pretend otherwise.
 *
 * (b) launchShortcut — ShortcutTrampoline Intent (UUID + AppId).
 *     Works ONLY with Moonlight's own pairing (Moonlight's cert, not
 *     LULU's). It is the fallback for devices paired the old way, and
 *     the reason the v1 pairing flow must prove path (a) on a real phone.
 */
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isMoonlightInstalled" -> {
                        result.success(packageManager.getLaunchIntentForPackage("com.limelight") != null)
                    }
                    "launchGame" -> {
                        val host = call.argument<String>("host") ?: ""
                        val port = call.argument<Int>("port") ?: 47989
                        val httpsPort = call.argument<Int>("httpsPort") ?: 47984
                        val appName = call.argument<String>("appName") ?: "Desktop"
                        val appId = call.argument<Int>("appId") ?: -1
                        val uuid = call.argument<String>("uuid") ?: ""
                        val pcName = call.argument<String>("pcName") ?: ""
                        val hdr = call.argument<Boolean>("hdr") ?: false
                        val serverCert = call.argument<List<Int>>("serverCert")
                            ?.map { it.toByte() }?.toByteArray() ?: ByteArray(0)
                        result.success(
                            launchGame(
                                host, port, httpsPort, appName, appId,
                                uuid, pcName, hdr, serverCert,
                            )
                        )
                    }
                    "launchShortcut" -> {
                        val uuid = call.argument<String>("uuid") ?: ""
                        val appId = call.argument<Int>("appId") ?: -1
                        result.success(launchShortcut(uuid, appId))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun launchGame(
        host: String,
        port: Int,
        httpsPort: Int,
        appName: String,
        appId: Int,
        uuid: String,
        pcName: String,
        hdr: Boolean,
        serverCert: ByteArray,
    ): Boolean {
        // Extra keys per the research report (moonlight-vplus Game.kt).
        // TODO(verify): confirm each key against Moonlight Android v12.2
        // source (com.limelight.Game / NvConnection) on a real phone.
        // Unknown extras are ignored by Android, so a wrong key fails
        // silently — the only proof is a stream that actually starts.
        val intent = Intent().apply {
            component = ComponentName("com.limelight", "com.limelight.Game")
            putExtra("Host", host)
            putExtra("Port", port)
            putExtra("HttpsPort", httpsPort)
            putExtra("AppName", appName)
            putExtra("AppId", appId)
            putExtra("UUID", uuid)
            putExtra("PcName", pcName)
            putExtra("HDR", hdr)
            putExtra("ServerCert", serverCert)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    private fun launchShortcut(uuid: String, appId: Int): Boolean {
        // Proven by Frostoman's moonlight-androidtv-widget: an external
        // launcher can start Moonlight via ShortcutTrampoline with the
        // paired PC's UUID + AppId. Moonlight resolves the PC from its
        // own database and handles Wake-on-LAN.
        // The exact extra keys are not documented in the upstream source
        // read for this scaffold, so the known aliases are all sent;
        // unknown extras are ignored.
        val intent = Intent().apply {
            component = ComponentName(
                "com.limelight",
                "com.limelight.ShortcutTrampoline",
            )
            putExtra("UUID", uuid)
            putExtra("PC_UUID", uuid)
            putExtra("AppId", appId)
            putExtra("APP_ID", appId)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }
}
