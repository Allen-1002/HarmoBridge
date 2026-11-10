package com.xsh.notibridge.ui

import android.os.Handler
import android.os.Looper
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.xsh.notibridge.NotiApp
import com.xsh.notibridge.core.Computer
import com.xsh.notibridge.core.ComputerLink
import com.xsh.notibridge.core.DEFAULT_PORT
import com.xsh.notibridge.core.LinkListener
import com.xsh.notibridge.core.LinkState
import com.xsh.notibridge.core.OutgoingNotification
import com.xsh.notibridge.core.PendingUnpair
import com.xsh.notibridge.core.UnpairOutcome
import com.xsh.notibridge.data.Discovery
import com.xsh.notibridge.data.FoundComputer

private val main = Handler(Looper.getMainLooper())

/** 一次配对的界面状态 */
private class PairTarget(val host: String, val port: Int, val name: String)

/** 电脑连接：已配对列表、局域网查找、手动输入地址、PIN + 校验码配对。引导页和设置页共用。 */
@Composable
fun ComputersPanel(onPaired: () -> Unit = {}) {
    val ctx = LocalContext.current
    val app = NotiApp.instance
    rememberDataTick()
    val paired = app.store.pairedComputers()
    val found = remember { mutableStateListOf<FoundComputer>() }
    var searching by remember { mutableStateOf(false) }
    var pairTarget by remember { mutableStateOf<PairTarget?>(null) }
    var manual by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<Computer?>(null) }
    val discovery = remember { Discovery(ctx.applicationContext) }

    fun search() {
        found.clear()
        searching = true
        discovery.start({ f ->
            if (found.none { it.host == f.host && it.port == f.port }) found.add(f)
            // 局域网里发现了“手机上已删除、还没通知到”的电脑：顺便通知它
            if (f.id.isNotEmpty()) {
                app.store.updatePendingAddress(f.id, f.host, f.port)
                PendingUnpair.flush(app.store, f.id, true)
                if (app.store.findComputer(f.id) != null) app.store.updateAddress(f.id, f.host, f.port)
            }
        }, { searching = false })
    }

    DisposableEffect(Unit) {
        search()
        onDispose { discovery.stop() }
    }

    Column(verticalArrangement = ColGap) {
        if (paired.isNotEmpty()) {
            SectionTitle("已配对的电脑")
            SectionCard {
                paired.forEachIndexed { i, c ->
                    if (i > 0) Divider()
                    RowItem(c.macName, "${c.platformLabel} · ${c.host}:${c.port}", trailing = {
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            TextButton(onClick = { sendTest(ctx, c) }) { Text("测试") }
                            TextButton(onClick = { deleting = c }) { Text("删除", color = Danger) }
                        }
                    })
                }
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionTitle("局域网中的电脑")
            Spacer(Modifier.weight(1f))
            if (searching) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            else TextButton(onClick = { search() }) { Text("重新查找") }
        }
        SectionCard {
            if (found.isEmpty()) {
                RowItem(
                    if (searching) "正在查找…" else "没有找到电脑",
                    "在电脑上打开 NotiBridge 并点“添加设备”，确认手机和电脑连着同一个 Wi-Fi",
                )
            }
            found.forEachIndexed { i, f ->
                if (i > 0) Divider()
                val isPaired = f.id.isNotEmpty() && paired.any { it.macId == f.id }
                RowItem(f.displayName, "${f.platformLabel} · ${f.host}:${f.port}${if (isPaired) " · 已配对" else ""}",
                    onClick = { pairTarget = PairTarget(f.host, f.port, f.displayName) })
            }
            Divider()
            RowItem("手动输入电脑地址", "找不到时，输入电脑端显示的 IP 地址", onClick = { manual = true })
        }
        Hint("配对时手机会生成一次性密钥，和电脑交换后核对 8 位校验码，之后所有通知都加密传输。", Modifier.padding(horizontal = 8.dp))
    }

    if (manual) ManualDialog(onDismiss = { manual = false }) { h, p ->
        manual = false
        pairTarget = PairTarget(h, p, h)
    }
    pairTarget?.let { t ->
        PairDialog(t, onDismiss = { pairTarget = null }, onDone = {
            pairTarget = null
            onPaired()
        })
    }
    deleting?.let { c ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("删除 ${c.macName}？") },
            text = { Text("电脑上也会同步取消配对（电脑不在线时，下次连上自动通知）。之后需要重新配对才能同步通知。") },
            confirmButton = {
                TextButton(onClick = {
                    deleting = null
                    app.store.forget(c.macId, notifyLater = true)
                    PendingUnpair.flush(app.store, c.macId, true) { _, r ->
                        main.post {
                            val msg = when (r) {
                                UnpairOutcome.DELIVERED -> "${c.macName} 已同步取消配对"
                                UnpairOutcome.NOT_PAIRED -> "${c.macName} 一直没有确认取消配对，请在电脑上检查并手动删除这台手机"
                                UnpairOutcome.OLD_VERSION -> "${c.macName} 的版本较旧，请在电脑上手动取消配对"
                                UnpairOutcome.OFFLINE -> "${c.macName} 不在线或暂时无法确认，下次连上时自动通知它取消配对"
                            }
                            Toast.makeText(ctx, msg, Toast.LENGTH_LONG).show()
                        }
                    }
                }) { Text("删除", color = Danger) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消") } },
        )
    }
}

private fun sendTest(ctx: android.content.Context, c: Computer) {
    val app = NotiApp.instance
    var link: ComputerLink? = null
    var done = false
    val finish = { msg: String ->
        if (!done) {
            done = true
            main.post { Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show() }
            link?.dispose()
        }
    }
    link = ComputerLink(app.store, object : LinkListener {
        override fun onState(state: LinkState, detail: String) {
            if (state == LinkState.ONLINE) {
                link?.sendNotification(OutgoingNotification("test-${System.currentTimeMillis()}", "com.xsh.notibridge",
                    "NotiBridge", "测试通知", "来自 ${app.store.deviceName} 的测试消息", System.currentTimeMillis(), true))
            } else if (state == LinkState.ERROR) finish("连接 ${c.macName} 失败：$detail")
        }

        override fun onAck(seq: Int, result: String) {
            if (result == "pong") return
            finish(when (result) {
                "shown" -> "${c.macName} 已显示测试通知"
                "paused" -> "${c.macName} 已暂停同步"
                "filtered" -> "${c.macName} 过滤了这条通知"
                else -> "${c.macName} 回复：$result"
            })
        }
    }, foreground = false, target = c)
    link.later(12_000) { finish("${c.macName} 没有回应") }
    link.connect()
}

@Composable
private fun ManualDialog(onDismiss: () -> Unit, onOk: (String, Int) -> Unit) {
    var host by remember { mutableStateOf("") }
    var port by remember { mutableStateOf(DEFAULT_PORT.toString()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("电脑地址") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(host, { host = it.trim() }, label = { Text("IP 地址，例如 192.168.1.20") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                OutlinedTextField(port, { port = it.filter(Char::isDigit).take(5) }, label = { Text("端口") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            }
        },
        confirmButton = {
            TextButton(enabled = host.isNotEmpty() && (port.toIntOrNull() ?: 0) in 1..65535,
                onClick = { onOk(host, port.toInt()) }) { Text("下一步") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
private fun PairDialog(t: PairTarget, onDismiss: () -> Unit, onDone: () -> Unit) {
    val app = NotiApp.instance
    var pin by remember { mutableStateOf("") }
    var state by remember { mutableStateOf(LinkState.IDLE) }
    var started by remember { mutableStateOf(false) }
    var sas by remember { mutableStateOf("") }
    var error by remember { mutableStateOf("") }
    var success by remember { mutableStateOf<Computer?>(null) }
    val link = remember {
        ComputerLink(app.store, object : LinkListener {
            override fun onState(s: LinkState, detail: String) = main.post {
                state = s
                if (s == LinkState.ERROR) error = describe(detail)
            }.let {}

            override fun onSas(code: String) = main.post { sas = code }.let {}
            override fun onLog(ok: Boolean, msg: String) {
                app.store.log(ok, msg)
                if (!ok && msg.startsWith("连接失败")) main.post { error = "连不上电脑，确认电脑端已打开、和手机连着同一个 Wi-Fi" }
            }

            override fun onPaired(c: Computer) = main.post { success = c }.let {}
        }, foreground = false)
    }
    DisposableEffect(Unit) { onDispose { link.dispose() } }

    val busy = started && success == null && state != LinkState.ERROR && state != LinkState.AWAITING_SAS
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(if (success != null) "配对成功" else "配对 ${t.name}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                when {
                    success != null -> Text("已与 ${success!!.macName}（${success!!.platformLabel}）配对。手机上的通知会加密同步到这台电脑。")
                    state == LinkState.AWAITING_SAS -> {
                        Text("请确认电脑上显示的校验码与下面一致：")
                        Text(sas, fontSize = 34.sp, fontWeight = FontWeight.Bold,
                            fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.align(Alignment.CenterHorizontally))
                        Hint("不一致说明有人在冒充电脑，请点“不一致”并重新配对。")
                    }
                    busy -> Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(12.dp))
                        Text(if (state == LinkState.PAIRING && sas.isNotEmpty()) "等待电脑确认…" else "正在连接 ${t.host}…")
                    }
                    else -> {
                        Text("在电脑的 NotiBridge 里点“添加设备”，输入电脑上显示的 6 位配对码。")
                        OutlinedTextField(pin, { pin = it.filter(Char::isDigit).take(6) }, label = { Text("配对码") },
                            singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                            textStyle = MaterialTheme.typography.headlineSmall.copy(fontFamily = FontFamily.Monospace))
                        if (error.isNotEmpty()) Text(error, color = Danger, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        },
        confirmButton = {
            when {
                success != null -> Button(onClick = onDone) { Text("完成") }
                state == LinkState.AWAITING_SAS -> Button(onClick = { link.confirmSas() }) { Text("一致，确认") }
                busy -> {}
                else -> Button(enabled = pin.length == 6, onClick = {
                    error = ""
                    sas = ""
                    started = true
                    link.startPairing(t.host, t.port, pin)
                }) { Text("配对") }
            }
        },
        dismissButton = {
            when {
                success != null -> {}
                state == LinkState.AWAITING_SAS -> OutlinedButton(onClick = { link.stop(); onDismiss() }) { Text("不一致") }
                else -> TextButton(onClick = { link.stop(); onDismiss() }) { Text("取消") }
            }
        },
    )
}

private fun describe(code: String): String = when (code) {
    "bad_pin" -> "配对码错误，请核对电脑上显示的配对码"
    "pairing_closed" -> "电脑未开启配对或配对码已过期，请在电脑上重新点“添加设备”"
    "连接失败", "连接超时" -> "连不上电脑，确认电脑端已打开、和手机连着同一个 Wi-Fi"
    "outdated" -> com.xsh.notibridge.core.OUTDATED_TEXT
    else -> com.xsh.notibridge.core.ERROR_TEXT[code] ?: code
}
