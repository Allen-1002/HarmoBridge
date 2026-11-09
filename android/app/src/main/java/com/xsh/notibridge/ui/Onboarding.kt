package com.xsh.notibridge.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.xsh.notibridge.NotiApp
import com.xsh.notibridge.service.NotifyListener

private class Step(val title: String, val desc: String)

private val STEPS = listOf(
    Step("欢迎使用 NotiBridge", "把手机通知安全地同步到你的 Mac 或 Windows 电脑，可以同时连接多台。数据只在你自己的设备之间加密传输，不经过任何服务器。"),
    Step("选择使用方式", "纯软件即可同步通知和验证码。想在电脑上接打电话，需要额外的 ESP32 模块。之后可以在设置里更改。"),
    Step("允许读取通知", "在系统设置的“通知使用权”里找到 NotiBridge 并打开。安卓会提示这项权限可以读取所有通知内容，NotiBridge 只把它们加密发给你配对的电脑。"),
    Step("允许后台运行", "部分手机会在后台清理通知监听。允许 NotiBridge 不受电池优化限制，熄屏后也能及时同步。"),
    Step("连接电脑", "在电脑上打开 NotiBridge，点“配对新手机”。之后可以在“电脑连接”里继续添加其他电脑。"),
    Step("设置完成", "之后不需要保持 App 打开，熄屏或切到后台后，通知也会自动同步到电脑。"),
)

@Composable
fun OnboardingScreen(resumeTick: Int, onFinish: () -> Unit) {
    val ctx = LocalContext.current
    var step by remember { mutableIntStateOf(0) }
    var mode by remember { mutableStateOf(UiPrefs.useMode) }
    rememberDataTick()
    @Suppress("UNUSED_EXPRESSION") resumeTick // 从系统设置回来时刷新权限状态
    val granted = NotifyListener.isGranted(ctx)
    val battery = Perms.ignoringBattery(ctx)
    val paired = NotiApp.instance.store.pairedComputers().isNotEmpty()
    val scroll = rememberScrollState()

    val canNext = when (step) {
        2 -> granted
        4 -> paired
        else -> true
    }
    fun finish() {
        UiPrefs.onboarded = true
        onFinish()
    }

    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface).safeDrawingPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (i in 0 until STEPS.size - 1) {
                    Box(Modifier.animateContentSize().width(if (i == step) 22.dp else 8.dp).height(8.dp).clip(RoundedCornerShape(4.dp))
                        .background(if (i <= step) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant))
                }
            }
            Spacer(Modifier.weight(1f))
            if (step in 1 until STEPS.size - 1 && !(step == 4 && paired)) {
                TextButton(onClick = { finish() }) { Text("稍后设置") }
            }
        }
        Column(Modifier.weight(1f).verticalScroll(scroll).padding(horizontal = 16.dp), verticalArrangement = ColGap) {
            Text(STEPS[step].title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(top = 12.dp))
            Text(STEPS[step].desc, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            when (step) {
                0 -> {
                    Hero(Icons.Filled.Notifications)
                    SectionCard {
                        Feature(Icons.Filled.Notifications, "通知同步", "微信、短信、邮件等通知实时出现在电脑通知中心")
                        Feature(Icons.Filled.CheckCircle, "验证码自动复制", "收到验证码短信，电脑上直接粘贴")
                        Feature(Icons.Filled.Lock, "本地加密", "只在你的手机和电脑之间传输，配对后加密")
                    }
                    SectionCard {
                        Text("需要的权限", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(start = 16.dp, top = 14.dp))
                        PermLine("通知使用权", "必需", "读取通知并转发到电脑；可以在设置里按应用屏蔽")
                        PermLine("不受电池优化限制", "推荐", "防止系统在后台停止通知监听")
                        PermLine("本地网络", "自动", "在同一 Wi-Fi 下把通知加密发送到电脑，不经过任何服务器")
                        PermLine("安装应用", "更新时", "下载新版本后由你确认安装，安装包会校验哈希和签名")
                    }
                }
                1 -> {
                    ModeOption(mode == "software", Icons.Filled.Notifications, "纯软件（推荐）",
                        "同步通知、验证码自动复制。不需要任何额外硬件。不能接打电话。") { mode = "software"; UiPrefs.useMode = "software" }
                    ModeOption(mode == "esp32", Icons.Filled.Phone, "使用 ESP32",
                        "在上面的基础上，还可以在电脑上接听、拨打电话。需要一块 ESP32 模块插在电脑 USB 上，由电脑端 NotiBridge 自动检测并刷写固件。") {
                        mode = "esp32"; UiPrefs.useMode = "esp32"
                    }
                    if (mode == "esp32") Hint("ESP32 通话固件尚在开发中，目前可以先完成检测流程；固件发布后在电脑端一键刷写即可。")
                }
                2 -> {
                    Hero(Icons.Filled.Lock)
                    SectionCard {
                        RowItem("通知使用权", trailing = { Chip(if (granted) "已开启" else "未开启", if (granted) Success else Warning) })
                        Button(onClick = { Perms.openListenerSettings(ctx) }, modifier = Modifier.fillMaxWidth().padding(16.dp)) {
                            Text(if (granted) "打开系统设置查看" else "去开启")
                        }
                    }
                    Hint("如果系统提示“受限设置”，先到 设置 › 应用 › NotiBridge 右上角菜单里点“允许受限设置”，再回来开启。")
                }
                3 -> {
                    SectionCard {
                        RowItem("不受电池优化限制", trailing = { Chip(if (battery) "已允许" else "未允许", if (battery) Success else Warning) })
                        Button(onClick = { Perms.requestIgnoreBattery(ctx) }, enabled = !battery,
                            modifier = Modifier.fillMaxWidth().padding(16.dp)) { Text(if (battery) "已允许" else "允许") }
                    }
                    Hint("小米、华为、OPPO、vivo 等手机还可能需要在系统的“自启动 / 后台运行”管理里允许 NotiBridge。")
                }
                4 -> ComputersPanel()
                else -> {
                    Hero(Icons.Filled.CheckCircle)
                    Text("可以试试让朋友给你发一条消息，电脑上会立即弹出通知。", color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.fillMaxWidth())
                }
            }
            Spacer(Modifier.height(16.dp))
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Button(onClick = {
                if (step >= STEPS.size - 1) finish() else step++
            }, enabled = canNext, modifier = Modifier.fillMaxWidth().height(50.dp)) {
                Text(when (step) { 0 -> "开始设置"; STEPS.size - 1 -> "进入 NotiBridge"; else -> "下一步" })
            }
            if (step in 1 until STEPS.size - 1) TextButton(onClick = { step-- }) { Text("上一步") }
        }
    }
}

@Composable
private fun Hero(icon: ImageVector) {
    Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.size(112.dp).clip(RoundedCornerShape(32.dp)).background(Brush.linearGradient(listOf(Accent, AccentEnd))),
            contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = Color.White, modifier = Modifier.size(56.dp))
        }
    }
}

@Composable
private fun Feature(icon: ImageVector, title: String, desc: String) {
    RowItem(title, desc, leading = {
        Box(Modifier.size(40.dp).clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center) { Icon(icon, null, tint = MaterialTheme.colorScheme.primary) }
    })
}

@Composable
private fun PermLine(name: String, tag: String, reason: String) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(name, style = MaterialTheme.typography.bodyMedium)
            Chip(tag, if (tag == "必需") Danger else MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Hint(reason)
    }
}

@Composable
private fun ModeOption(selected: Boolean, icon: ImageVector, title: String, desc: String, onClick: () -> Unit) {
    val border = if (selected) MaterialTheme.colorScheme.primary else Color.Transparent
    Box(Modifier.clip(RoundedCornerShape(20.dp)).border(2.dp, border, RoundedCornerShape(20.dp)).clickable(onClick = onClick)) {
        SectionCard {
            RowItem(title, desc, leading = { Icon(icon, null, tint = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) },
                trailing = { if (selected) Icon(Icons.Filled.CheckCircle, null, tint = MaterialTheme.colorScheme.primary) })
        }
    }
}
