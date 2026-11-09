package com.xsh.notibridge.ui

import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.xsh.notibridge.BuildConfig
import com.xsh.notibridge.NotiApp
import com.xsh.notibridge.core.SettingsSync
import com.xsh.notibridge.core.SyncSettings
import com.xsh.notibridge.data.Discovery
import com.xsh.notibridge.service.NotifyListener
import com.xsh.notibridge.service.Updater
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(resumeTick: Int, onRerunOnboarding: () -> Unit) {
    var tab by remember { mutableIntStateOf(0) }
    var route by remember { mutableStateOf("") }
    val ctx = LocalContext.current
    val app = NotiApp.instance
    var notices by remember { mutableStateOf<List<String>>(emptyList()) }

    LaunchedEffect(resumeTick) {
        notices = notices + app.store.takeUnpairNotices()
    }

    BackHandler(enabled = route.isNotEmpty()) { route = "" }

    if (route.isNotEmpty()) {
        val title = when (route) { "computers" -> "电脑连接"; "apps" -> "按应用屏蔽"; else -> "调试与诊断" }
        Scaffold(topBar = {
            TopAppBar(title = { Text(title) }, navigationIcon = {
                IconButton(onClick = { route = "" }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") }
            })
        }) { pad ->
            when (route) {
                "computers" -> Column(Modifier.padding(pad).verticalScroll(rememberScrollState()).padding(16.dp)) { ComputersPanel() }
                "apps" -> AppFilterScreen(Modifier.padding(pad))
                else -> DebugScreen(Modifier.padding(pad))
            }
        }
    } else {
        Scaffold(bottomBar = {
            NavigationBar {
                listOf(Triple("首页", Icons.Filled.Home, 0), Triple("通知", Icons.Filled.Notifications, 1), Triple("设置", Icons.Filled.Settings, 2))
                    .forEach { (label, icon, i) ->
                        NavigationBarItem(selected = tab == i, onClick = { tab = i }, icon = { Icon(icon, label) }, label = { Text(label) })
                    }
            }
        }) { pad ->
            Box(Modifier.padding(pad).fillMaxSize()) {
                when (tab) {
                    0 -> HomeTab(resumeTick, onOpen = { route = it }, onRerunOnboarding = onRerunOnboarding)
                    1 -> NotificationsTab()
                    else -> SettingsTab(resumeTick, onOpen = { route = it }, onRerunOnboarding = onRerunOnboarding)
                }
            }
        }
    }

    if (notices.isNotEmpty()) {
        AlertDialog(
            onDismissRequest = { notices = emptyList() },
            title = { Text("电脑已取消配对") },
            text = { Text("${notices.joinToString("、")} 已在电脑上取消了与这台手机的配对，已从列表中移除。需要时可以重新配对。") },
            confirmButton = { TextButton(onClick = { notices = emptyList() }) { Text("知道了") } },
        )
    }
    @Suppress("UNUSED_EXPRESSION") ctx
}

private fun updateSettings(change: (SyncSettings) -> Unit) {
    val store = NotiApp.instance.store
    val s = store.loadSettings()
    change(s)
    store.saveSettings(s)
    SettingsSync.run(store)
}

@Composable
private fun HomeTab(resumeTick: Int, onOpen: (String) -> Unit, onRerunOnboarding: () -> Unit) {
    val ctx = LocalContext.current
    val app = NotiApp.instance
    rememberDataTick()
    @Suppress("UNUSED_EXPRESSION") resumeTick
    val granted = NotifyListener.isGranted(ctx)
    val battery = Perms.ignoringBattery(ctx)
    val computers = app.store.pairedComputers()
    val settings = app.store.loadSettings()
    val missing = listOf(granted, computers.isNotEmpty()).count { !it }

    Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = ColGap) {
        Text("NotiBridge", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp))
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Brush.linearGradient(listOf(Accent, AccentEnd))).padding(20.dp)) {
            if (missing > 0) {
                Column {
                    Text("还差 $missing 步完成设置", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    Text("完成后，手机通知会自动同步到你的电脑", color = Color.White.copy(alpha = 0.9f), modifier = Modifier.padding(top = 6.dp))
                    Button(onClick = onRerunOnboarding, modifier = Modifier.padding(top = 14.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Accent)) { Text("继续设置") }
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(if (settings.paused) "同步已暂停" else "正在同步", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        Text(if (settings.paused) "通知暂时留在手机上" else "新通知会加密发送到 ${computers.size} 台电脑",
                            color = Color.White.copy(alpha = 0.9f), modifier = Modifier.padding(top = 6.dp))
                    }
                    Switch(checked = !settings.paused, onCheckedChange = { on -> updateSettings { it.paused = !on } })
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            StatTile(app.records.todayCount().toString(), "今日收到通知", Modifier.weight(1f))
            StatTile(computers.size.toString(), "已配对电脑", Modifier.weight(1f))
        }
        SectionTitle("连接状态")
        SectionCard {
            RowItem("通知读取", if (granted) (if (NotifyListener.connected) "已开启，监听运行中" else "已开启") else "未开启通知使用权",
                onClick = { Perms.openListenerSettings(ctx) },
                trailing = { Chip(if (granted) "正常" else "未开启", if (granted) Success else Danger) })
            Divider()
            RowItem("电脑", if (computers.isEmpty()) "尚未配对 Mac 或 Windows 电脑" else computers.joinToString("、") { "${it.macName}（${it.platformLabel}）" },
                onClick = { onOpen("computers") },
                trailing = { Chip(if (computers.isEmpty()) "未配对" else "已配对", if (computers.isEmpty()) Warning else Success) })
            Divider()
            RowItem("后台运行", if (battery) "不受电池优化限制" else "可能被系统在后台停止",
                onClick = { if (!battery) Perms.requestIgnoreBattery(ctx) },
                trailing = { Chip(if (battery) "已允许" else "建议允许", if (battery) Success else Warning) })
        }
        Hint("通知由系统交给 NotiBridge 后立即转发，切到后台或熄屏后依然有效。", Modifier.padding(horizontal = 8.dp))
    }
}

@Composable
private fun StatTile(value: String, label: String, modifier: Modifier) {
    SectionCard(modifier) {
        Column(Modifier.padding(16.dp)) {
            Text(value, fontSize = 28.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
            Hint(label)
        }
    }
}

@Composable
private fun NotificationsTab() {
    val app = NotiApp.instance
    rememberDataTick()
    val list = app.records.all()
    val fmt = remember { SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("通知", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            if (list.isNotEmpty()) TextButton(onClick = { app.records.clear() }) { Text("清空") }
        }
        if (list.isEmpty()) {
            Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                Text("还没有收到通知", style = MaterialTheme.typography.titleMedium)
                Hint("完成设置后，这里会显示最近同步的通知（仅保存在本机）", Modifier.padding(top = 6.dp))
            }
        } else {
            LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items(list, key = { "${it.time}-${it.key}" }) { r ->
                    SectionCard {
                        Column(Modifier.padding(14.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(r.appName, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, modifier = Modifier.weight(1f))
                                Chip(r.result, if (r.result == "已转发" || r.result == "验证码已发送") Success else MaterialTheme.colorScheme.onSurfaceVariant)
                                Spacer(Modifier.padding(4.dp))
                                Hint(fmt.format(Date(r.time)))
                            }
                            if (r.title.isNotEmpty()) Text(r.title, style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 6.dp))
                            if (r.text.isNotEmpty()) Text(r.text, style = MaterialTheme.typography.bodyMedium, maxLines = 3, overflow = TextOverflow.Ellipsis,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsTab(resumeTick: Int, onOpen: (String) -> Unit, onRerunOnboarding: () -> Unit) {
    val ctx = LocalContext.current
    val app = NotiApp.instance
    rememberDataTick()
    @Suppress("UNUSED_EXPRESSION") resumeTick
    val s = app.store.loadSettings()
    val granted = NotifyListener.isGranted(ctx)
    val battery = Perms.ignoringBattery(ctx)
    val computers = app.store.pairedComputers()
    var esp32 by remember { mutableStateOf(UiPrefs.useMode == "esp32") }
    var update by remember { mutableStateOf(Updater.cached(ctx)) }
    var checking by remember { mutableStateOf(false) }
    var progress by remember { mutableStateOf<Float?>(null) }
    var downloaded by remember { mutableStateOf<File?>(null) }
    var updateError by remember { mutableStateOf("") }
    var confirmClear by remember { mutableStateOf(false) }

    fun check(force: Boolean) {
        checking = true
        updateError = ""
        Discovery.io.execute {
            val r = runCatching { Updater.check(ctx, force) }
            mainHandler.post {
                checking = false
                r.onSuccess { update = it }.onFailure { updateError = "检查失败：${it.message}" }
            }
        }
    }

    fun downloadAndInstall(info: Updater.Info) {
        if (!Updater.canInstall(ctx)) {
            Toast.makeText(ctx, "请允许 NotiBridge 安装应用，然后回来再点一次", Toast.LENGTH_LONG).show()
            Updater.openInstallPermission(ctx)
            return
        }
        downloaded?.let { if (it.exists()) { Updater.install(ctx, it); return } }
        progress = 0f
        updateError = ""
        Discovery.io.execute {
            val r = runCatching { Updater.download(ctx, info) { p -> mainHandler.post { progress = p } } }
            mainHandler.post {
                progress = null
                r.onSuccess { downloaded = it; Updater.install(ctx, it) }.onFailure { updateError = it.message ?: "下载失败" }
            }
        }
    }

    LaunchedEffect(Unit) { check(false) }

    Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp)) {
        Text("设置", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp))
        SectionTitle("同步")
        SectionCard {
            ToggleItem("同步通知到电脑", checked = !s.paused) { on -> updateSettings { it.paused = !on } }
            Divider()
            ToggleItem("验证码复制到电脑剪贴板", "只发送验证码数字，不发送短信全文", s.copyOtp) { on -> updateSettings { it.copyOtp = on } }
            Divider()
            ToggleItem("不转发银行、支付类通知", "含余额、转账、付款等字样的通知留在手机上", s.blockSensitive) { on ->
                updateSettings { it.blockSensitive = on }
            }
        }
        Hint("这三个开关会和电脑端双向同步。", Modifier.padding(start = 8.dp, top = 6.dp))

        SectionTitle("设备与权限")
        SectionCard {
            RowItem("通知使用权", if (granted) "已开启" else "未开启", onClick = { Perms.openListenerSettings(ctx) })
            Divider()
            RowItem("后台运行", if (battery) "不受电池优化限制" else "建议允许不受电池优化限制",
                onClick = { if (battery) Perms.openAppDetails(ctx) else Perms.requestIgnoreBattery(ctx) })
            Divider()
            RowItem("电脑连接", if (computers.isEmpty()) "未配对" else computers.joinToString("、") { "${it.macName}（${it.platformLabel}）" },
                onClick = { onOpen("computers") })
            Divider()
            ToggleItem("使用 ESP32 通话模块",
                if (esp32) "在电脑端 NotiBridge 中检测和刷写 ESP32（固件开发中）" else "纯软件：同步通知和验证码，不能接打电话", esp32) { on ->
                esp32 = on
                UiPrefs.useMode = if (on) "esp32" else "software"
            }
        }

        SectionTitle("过滤")
        SectionCard {
            RowItem("按应用屏蔽", if (s.blockedBundles.isEmpty()) "所有应用的通知都会同步" else "已屏蔽 ${s.blockedBundles.size} 个应用",
                onClick = { onOpen("apps") })
        }

        SectionTitle("软件更新")
        SectionCard {
            val u = update
            val has = u?.hasUpdate == true
            RowItem(if (has) "有新版本 ${u!!.latest}" else "软件更新",
                when {
                    checking -> "正在检查…"
                    updateError.isNotEmpty() -> updateError
                    u == null -> "当前版本 ${BuildConfig.VERSION_NAME}"
                    has -> "当前版本 ${u.current}" + if (u.notes.isNotEmpty()) "\n${u.notes}" else ""
                    else -> "当前版本 ${u.current}，已是最新"
                }, titleColor = if (has) MaterialTheme.colorScheme.primary else null)
            progress?.let { p ->
                LinearProgressIndicator(progress = { p }, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
            }
            Divider()
            if (has && u!!.apkUrl != null) {
                RowItem(if (downloaded != null) "安装新版本" else "下载并安装", "下载后校验哈希和签名，再由你确认安装",
                    onClick = { if (progress == null) downloadAndInstall(u) })
            } else if (has) {
                RowItem("查看新版本", "这个版本没有安卓安装包，在浏览器中打开发布页", onClick = { Updater.openPage(ctx, u!!.page) })
            } else {
                RowItem("检查更新", "从 GitHub 获取最新版本信息", onClick = { if (!checking) check(true) })
            }
        }

        SectionTitle("其他")
        SectionCard {
            RowItem("重新运行设置向导", onClick = onRerunOnboarding)
            Divider()
            RowItem("调试与诊断", "权限、连接、日志等详细信息", onClick = { onOpen("debug") })
            Divider()
            RowItem("清除所有数据", "删除配对密钥、设置和通知记录，回到首次使用", titleColor = Danger, onClick = { confirmClear = true })
        }
        Hint("NotiBridge ${BuildConfig.VERSION_NAME} · 安卓版，与鸿蒙、Mac、Windows 版使用同一套加密协议", Modifier.padding(8.dp))
        Spacer(Modifier.height(24.dp))
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("清除所有数据？") },
            text = { Text("会删除所有电脑的配对密钥、同步设置和本机通知记录，并回到首次使用。电脑上的配对需要在电脑端手动删除。此操作不能撤销。") },
            confirmButton = {
                TextButton(onClick = {
                    confirmClear = false
                    app.forwarder.close()
                    app.records.clear()
                    app.store.clearAll()
                    Toast.makeText(ctx, "已清除所有数据", Toast.LENGTH_SHORT).show()
                    onRerunOnboarding()
                }) { Text("清除", color = Danger) }
            },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("取消") } },
        )
    }
}
