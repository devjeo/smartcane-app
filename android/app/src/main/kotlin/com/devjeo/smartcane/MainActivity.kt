package com.devjeo.smartcane

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val ongoingChannel = "callkit_ongoing_channel_id"
    private val incomingChannel = "callkit_incoming_channel_id_v2"

    // Removes leftover call notifications posted by flutter_callkit_incoming.
    //  - callId:   that call's own notification (its id is callId.hashCode(),
    //              which is how the plugin numbers it).
    //  - clearAll: also remove any older "incoming call" notification that is
    //              more than 60 s old (a ringing call is never that old).
    private fun clearCallNotifications(callId: String?, clearAll: Boolean) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (callId != null) nm.cancel(callId.hashCode())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val now = System.currentTimeMillis()
                for (sbn in nm.activeNotifications) {
                    val ch = sbn.notification.channelId
                    val old = now - sbn.postTime > 60_000
                    if (ch == ongoingChannel || (clearAll && ch == incomingChannel && old)) {
                        nm.cancel(sbn.tag, sbn.id)
                    }
                }
            }
        } catch (e: Exception) {
            // ignore
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "smartcane/callkit_cleanup")
            .setMethodCallHandler { call, result ->
                if (call.method == "stopCallService") {
                    try {
                        val callId = call.argument<String>("callId")
                        val clearAll = call.argument<Boolean>("clearAll") ?: false
                        // 1) stop the plugin's ongoing-call foreground service
                        stopService(
                            Intent().setClassName(
                                packageName,
                                "com.hiennv.flutter_callkit_incoming.CallkitNotificationService"
                            )
                        )
                        // 2) remove the call notification(s). Some phones (Xiaomi/
                        //    Poco) keep them after the call; the plugin may also
                        //    re-post one a moment later, so repeat a little later.
                        clearCallNotifications(callId, clearAll)
                        val h = Handler(Looper.getMainLooper())
                        h.postDelayed({ clearCallNotifications(callId, clearAll) }, 700)
                        h.postDelayed({ clearCallNotifications(callId, clearAll) }, 2500)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}