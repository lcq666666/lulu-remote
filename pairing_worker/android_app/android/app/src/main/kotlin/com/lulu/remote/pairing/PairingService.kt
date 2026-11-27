// SPDX-License-Identifier: GPL-3.0-only
package com.lulu.remote.pairing

import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.os.RemoteException
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class PairingService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val jobs = mutableMapOf<IBinder, Job>()
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        val client = message.replyTo ?: return@Handler true
        if (callerIsLauncher(message.sendingUid)) {
            when (message.what) {
                START -> message.data.getString("request")?.let { start(client, it) }
                STOP -> finish(client, notify = false)
            }
        }
        true
    })

    override fun onBind(intent: Intent): IBinder = messenger.binder

    override fun onDestroy() {
        jobs.values.toList().forEach { finish(it.client, notify = false) }
        super.onDestroy()
    }

    private fun callerIsLauncher(uid: Int): Boolean {
        return try {
            val launcher = packageManager.getApplicationInfo("com.lulu.remote", 0)
            uid == launcher.uid &&
                packageManager.checkSignatures(uid, Process.myUid()) == PackageManager.SIGNATURE_MATCH
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun start(client: Messenger, request: String) {
        if (jobs.containsKey(client.binder)) return
        val death = IBinder.DeathRecipient {
            mainHandler.post { finish(client, notify = false) }
        }
        try {
            client.binder.linkToDeath(death, 0)
        } catch (_: RemoteException) {
            return
        }
        val engine = try {
            FlutterEngine(this)
        } catch (_: RuntimeException) {
            client.binder.unlinkToDeath(death, 0)
            send(client, FINISHED)
            return
        }
        jobs[client.binder] = Job(client, engine, death)
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "lulu.remote/pairing_worker_engine")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    result.success(null)
                    channel.invokeMethod("run", request, object : MethodChannel.Result {
                        override fun success(result: Any?) = complete()
                        override fun error(code: String, message: String?, details: Any?) = complete()
                        override fun notImplemented() = complete()

                        private fun complete() {
                            mainHandler.post { finish(client) }
                        }
                    })
                }
                "reply" -> {
                    send(client, REPLY, call.arguments as String)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        try {
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        } catch (_: RuntimeException) {
            finish(client)
        }
    }

    private fun finish(client: Messenger, notify: Boolean = true) {
        val job = jobs.remove(client.binder) ?: return
        job.client.binder.unlinkToDeath(job.death, 0)
        job.engine.destroy()
        if (notify) send(client, FINISHED)
    }

    private fun send(client: Messenger, type: Int, reply: String? = null) {
        val message = Message.obtain(null, type)
        if (reply != null) message.data = Bundle().apply { putString("reply", reply) }
        try {
            client.send(message)
        } catch (_: RemoteException) {
            // Binder death also cancels the corresponding Dart engine.
        }
    }

    private data class Job(val client: Messenger, val engine: FlutterEngine, val death: IBinder.DeathRecipient)

    private companion object {
        const val START = 1
        const val STOP = 2
        const val REPLY = 3
        const val FINISHED = 4
    }
}
