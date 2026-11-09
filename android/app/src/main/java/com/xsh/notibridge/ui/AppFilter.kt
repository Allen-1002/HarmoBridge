package com.xsh.notibridge.ui

import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import com.xsh.notibridge.NotiApp
import com.xsh.notibridge.data.Discovery

private class AppEntry(val pkg: String, val label: String, val icon: Bitmap?)

/** 按应用屏蔽：桌面上的应用 + 发过通知的应用；被屏蔽的应用通知留在手机上。 */
@Composable
fun AppFilterScreen(modifier: Modifier) {
    val ctx = LocalContext.current
    val app = NotiApp.instance
    rememberDataTick()
    var apps by remember { mutableStateOf<List<AppEntry>?>(null) }
    var query by remember { mutableStateOf("") }
    LaunchedEffect(Unit) {
        Discovery.io.execute {
            val pm = ctx.packageManager
            val pkgs = linkedSetOf<String>()
            app.records.all().forEach { pkgs.add(it.pkg) }
            pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
                .forEach { pkgs.add(it.activityInfo.packageName) }
            pkgs.remove(ctx.packageName)
            val list = pkgs.map { p ->
                val info = runCatching { pm.getApplicationInfo(p, 0) }.getOrNull()
                AppEntry(p, info?.let { pm.getApplicationLabel(it).toString() } ?: p,
                    info?.let { runCatching { pm.getApplicationIcon(it).toBitmap(96, 96) }.getOrNull() })
            }.sortedBy { it.label.lowercase() }
            android.os.Handler(android.os.Looper.getMainLooper()).post { apps = list }
        }
    }
    val blocked = app.store.loadSettings().blockedBundles
    Column(modifier.fillMaxSize()) {
        OutlinedTextField(query, { query = it }, label = { Text("搜索应用") }, singleLine = true,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth())
        val list = apps
        if (list == null) {
            CircularProgressIndicator(Modifier.padding(32.dp))
        } else {
            val shown = list.filter { query.isBlank() || it.label.contains(query, true) || it.pkg.contains(query, true) }
                .sortedByDescending { it.pkg in blocked }
            LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
                item { Hint("关闭开关的应用，通知不会同步到电脑。", Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
                items(shown, key = { it.pkg }) { a ->
                    val on = a.pkg !in blocked
                    val toggle = { v: Boolean ->
                        val s = app.store.loadSettings()
                        if (v) s.blockedBundles.remove(a.pkg) else s.blockedBundles.add(a.pkg)
                        app.store.saveSettings(s)
                    }
                    RowItem(a.label, a.pkg, onClick = { toggle(!on) },
                        leading = { a.icon?.let { Image(it.asImageBitmap(), null, Modifier.size(36.dp)) } },
                        trailing = { androidx.compose.material3.Switch(checked = on, onCheckedChange = toggle) })
                }
            }
        }
    }
}
