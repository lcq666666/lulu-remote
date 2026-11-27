package com.lulu.remote

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class PairingWorkerBridge(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "lulu.remote/pairing_worker")
    private val active = mutableMapOf<Int, Connection>()
    private val worker = ComponentName(WORKER_PACKAGE, "$WORKER_PACKAGE.PairingService")

    init {
        channel.setMethodCallHandler { call, result ->
            val id = call.argument<Int>("id")
            if (id == null) {
                result.error("invalid_request", null, null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "start" -> {
                    val request = call.argument<String>("request")
                    if (request == null || active.containsKey(id)) {
                        result.error("invalid_request", null, null)
                        return@setMethodCallHandler
                    }
                    val connection = Connection(id, request)
                    val bound = try {
                        context.packageManager.checkSignatures(context.packageName, WORKER_PACKAGE) ==
                            PackageManager.SIGNATURE_MATCH && context.bindService(
                            Intent().setComponent(worker), connection, Context.BIND_AUTO_CREATE
                        )
                    } catch (_: SecurityException) {
                        false
                    }
                    if (bound) {
                        active[id] = connection
                        result.success(null)
                    } else {
                        result.error("worker_unavailable", null, null)
                    }
                }
                "stop" -> {
                    stop(id)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        active.keys.toList().forEach { stop(it) }
        channel.setMethodCallHandler(null)
    }

    private fun stop(id: Int) {
        val connection = active.remove(id) ?: return
        connection.send(STOP)
        context.unbindService(connection)
    }

    private inner class Connection(private val id: Int, private var request: String?) : ServiceConnection {
        private var remote: Messenger? = null
        private val client = Messenger(Handler(Looper.getMainLooper()) { message ->
            if (active[id] === this) {
                when (message.what) {
                    REPLY -> message.data.getString("reply")?.let {
                        channel.invokeMethod("reply", mapOf("id" to id, "reply" to it))
                    }
                    FINISHED -> finished()
                }
            }
            true
        })

        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            if (active[id] !== this) return
            remote = Messenger(service)
            val payload = request
            request = null
            if (payload == null || !send(START, payload)) finished()
        }

        override fun onServiceDisconnected(name: ComponentName) = finished()
        override fun onBindingDied(name: ComponentName) = finished()
        override fun onNullBinding(name: ComponentName) = finished()

        private fun finished() {
            if (active[id] !== this) return
            stop(id)
            channel.invokeMethod("finished", mapOf("id" to id))
        }

        fun send(type: Int, payload: String? = null): Boolean {
            val service = remote ?: return false
            val message = Message.obtain(null, type).apply {
                replyTo = client
                if (payload != null) data = Bundle().apply { putString("request", payload) }
            }
            return try {
                service.send(message)
                true
            } catch (_: RemoteException) {
                false
            }
        }
    }

    private companion object {
        const val WORKER_PACKAGE = "com.lulu.remote.pairing"
        const val START = 1
        const val STOP = 2
        const val REPLY = 3
        const val FINISHED = 4
    }
}
