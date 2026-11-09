package com.xsh.notibridge.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.widget.Toast
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.xsh.notibridge.BuildConfig
import com.xsh.notibridge.NotiApp
import com.xsh.notibridge.data.LogBuffer
import com.xsh.notibridge.service.NotifyListener
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun DebugScreen(modifier: Modifier) {
    val ctx = LocalContext.current
    val app = NotiApp.instance
    var tick by remember { mutableIntStateOf(0) }
    @Suppress("UNUSED_EXPRESSION") tick
    val fmt = remember { SimpleDateFormat("HH:mm:ss", Locale.getDefault()) }
    val info = listOf(
        "版本" to "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
        "系统" to "Android ${Build.VERSION.RELEASE} / API ${Build.VERSION.SDK_INT} · ${Build.MANUFACTURER} ${Build.MODEL}",
        "设备 ID" to app.store.deviceId,
        "设备名称" to app.store.deviceName,
        "通知使用权" to if (NotifyListener.isGranted(ctx)) "已开启" else "未开启",
        "监听服务" to if (NotifyListener.connected) "运行中" else "未连接",
        "电池优化" to if (Perms.ignoringBattery(ctx)) "已豁免" else "受限",
        "已配对电脑" to app.store.pairedComputers().joinToString("\n") { "${it.macName} · ${it.platformLabel} · ${it.host}:${it.port} · ${it.macId.take(8)}" }.ifEmpty { "无" },
        "待通知取消配对" to app.store.pendingUnpairs().joinToString { it.macName }.ifEmpty { "无" },
    )
    val logs = LogBuffer.snapshot().reversed()
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
        SectionCard {
            info.forEachIndexed { i, (k, v) ->
                if (i > 0) Divider()
                RowItem(k, v)
            }
        }
        SectionCard(Modifier.padding(top = 12.dp)) {
            RowItem("重新绑定通知监听", "通知不再转发时可以试试", onClick = {
                NotifyListener.requestRebind(ctx)
                Toast.makeText(ctx, "已请求系统重新绑定", Toast.LENGTH_SHORT).show()
            })
        }
        Row {
            SectionTitle("日志（${logs.size}）")
            androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
            TextButton(onClick = { tick++ }) { Text("刷新") }
            TextButton(onClick = {
                val text = info.joinToString("\n") { "${it.first}: ${it.second}" } + "\n\n" +
                    logs.joinToString("\n") { "${fmt.format(Date(it.time))} ${if (it.ok) "I" else "W"} ${it.msg}" }
                (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("NotiBridge", text))
                Toast.makeText(ctx, "已复制", Toast.LENGTH_SHORT).show()
            }) { Text("复制") }
            TextButton(onClick = { LogBuffer.clear(); tick++ }) { Text("清空") }
        }
        SectionCard {
            Column(Modifier.padding(12.dp)) {
                if (logs.isEmpty()) Hint("暂无日志")
                logs.take(200).forEach {
                    Text("${fmt.format(Date(it.time))} ${it.msg}", fontSize = 11.sp, fontFamily = FontFamily.Monospace,
                        color = if (it.ok) MaterialTheme.colorScheme.onSurfaceVariant else Danger)
                }
            }
        }
    }
}
