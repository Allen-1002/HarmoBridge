package com.xsh.notibridge.service

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Parcelable
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.xsh.notibridge.NotiApp
import com.xsh.notibridge.core.Filter
import com.xsh.notibridge.core.OtpMessage
import com.xsh.notibridge.core.OutgoingNotification
import com.xsh.notibridge.core.PendingUnpair
import com.xsh.notibridge.data.Records

/**
 * 系统通知监听服务：用户在“通知使用权”里允许后由系统绑定、按需拉起。
 * 收到通知 → 去重、过滤 → 加密转发到每台已配对电脑；通知在手机上被清除时同步撤回。
 */
class NotifyListener : NotificationListenerService() {
    private val app get() = NotiApp.instance

    override fun onListenerConnected() {
        connected = true
        app.store.log(true, "通知监听已连接")
        PendingUnpair.flush(app.store)
    }

    override fun onListenerDisconnected() {
        connected = false
        app.store.log(false, "通知监听已断开")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            handlePosted(sbn)
        } catch (e: Exception) {
            app.store.log(false, "处理通知失败：${e.javaClass.simpleName} ${e.message}")
        }
    }

    private fun handlePosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val n = sbn.notification ?: return
        // 常驻通知（音乐、导航、下载进度、前台服务）和分组摘要不转发
        if (sbn.isOngoing || n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val (title, text) = extractContent(n)
        if (title.isBlank() && text.isBlank()) return

        // 同一条通知被应用反复刷新但内容没变：只发一次
        val fp = "$title\n$text"
        synchronized(sent) {
            if (sent[sbn.key] == fp) return
            sent[sbn.key] = fp
            if (sent.size > 500) sent.remove(sent.keys.first())
        }

        val appName = appLabel(this, sbn.packageName)
        val settings = app.store.loadSettings()
        // 先按应用屏蔽和敏感过滤决定，再提取验证码（见 Filter.decide）
        val d = Filter.decide(settings, sbn.packageName, title, text)
        val computers = app.store.pairedComputers()
        var result = d.reason
        var targets = ""
        when (d.action) {
            Filter.Action.OTP -> if (computers.isEmpty()) result = "未配对电脑" else {
                app.forwarder.forwardOtp(OtpMessage(sbn.key, sbn.packageName, appName, d.otp))
                targets = computers.joinToString("、") { it.macName }
            }
            Filter.Action.FORWARD -> if (computers.isEmpty()) result = "未配对电脑" else {
                app.forwarder.forward(OutgoingNotification(sbn.key, sbn.packageName, appName, title, text, sbn.postTime, false))
                synchronized(forwardedKeys) { forwardedKeys.add(sbn.key) }
                targets = computers.joinToString("、") { it.macName }
            }
            Filter.Action.DROP -> {}
        }
        // 只记录元数据（不含标题、正文、验证码）；敏感内容连元数据也不记
        if (d.record) app.records.add(Records.Record(System.currentTimeMillis(), sbn.key, sbn.packageName, appName, result, targets))
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        synchronized(sent) { sent.remove(sbn.key) }
        val was = synchronized(forwardedKeys) { forwardedKeys.remove(sbn.key) }
        if (was) runCatching { app.forwarder.cancel(listOf(sbn.key)) }
    }

    override fun onDestroy() {
        super.onDestroy()
        connected = false
    }

    companion object {
        @Volatile
        var connected = false
            private set
        private val sent = LinkedHashMap<String, String>()
        private val forwardedKeys = LinkedHashSet<String>()

        fun isGranted(ctx: Context): Boolean {
            val flat = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners") ?: return false
            val me = ComponentName(ctx, NotifyListener::class.java)
            return flat.split(':').any { ComponentName.unflattenFromString(it) == me }
        }

        fun requestRebind(ctx: Context) {
            if (Build.VERSION.SDK_INT >= 24) runCatching { requestRebind(ComponentName(ctx, NotifyListener::class.java)) }
        }

        fun appLabel(ctx: Context, pkg: String): String = try {
            val pm = ctx.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            pkg
        }

        /** 标题 + 正文：优先聊天样式的最后一条消息，其次长文本、多行文本、普通正文。 */
        fun extractContent(n: Notification): Pair<String, String> {
            val ex = n.extras
            val cs = { k: String -> ex.getCharSequence(k)?.toString()?.trim() ?: "" }
            var title = cs(Notification.EXTRA_TITLE)
            var text = cs(Notification.EXTRA_BIG_TEXT).ifEmpty { cs(Notification.EXTRA_TEXT) }
            @Suppress("DEPRECATION")
            val msgs: Array<Parcelable>? = runCatching { ex.getParcelableArray(Notification.EXTRA_MESSAGES) }.getOrNull()
            val last = msgs?.lastOrNull() as? android.os.Bundle
            if (last != null) {
                val body = last.getCharSequence("text")?.toString()?.trim() ?: ""
                if (body.isNotEmpty()) {
                    text = body
                    val conv = cs(Notification.EXTRA_CONVERSATION_TITLE)
                    @Suppress("DEPRECATION")
                    val sender = last.getCharSequence("sender")?.toString()
                        ?: if (Build.VERSION.SDK_INT >= 28) last.getParcelable<android.app.Person>("sender_person")?.name?.toString() else null
                    if (conv.isNotEmpty() && !sender.isNullOrEmpty()) {
                        title = conv
                        text = "$sender：$body"
                    } else if (!sender.isNullOrEmpty() && title.isEmpty()) {
                        title = sender
                    }
                }
            } else if (text.isEmpty()) {
                val lines = ex.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
                if (!lines.isNullOrEmpty()) text = lines.joinToString("\n")
            }
            return title to text
        }
    }
}
