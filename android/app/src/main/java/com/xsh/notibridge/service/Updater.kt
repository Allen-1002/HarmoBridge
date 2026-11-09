package com.xsh.notibridge.service

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.pm.PackageInstaller
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import com.xsh.notibridge.BuildConfig
import com.xsh.notibridge.NotiApp
import com.xsh.notibridge.core.UpdateCore
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * 从 GitHub Releases 检查并下载新版 APK：校验 SHA256SUMS.txt 里的哈希、校验签名与当前安装的一致，
 * 再交给系统安装器（需要用户允许“安装未知应用”并点安装）。阻塞方法，请在后台线程调用。
 */
object Updater {
    data class Info(val current: String, val latest: String, val hasUpdate: Boolean, val page: String,
                    val notes: String, val apkUrl: String?, val apkSize: Long, val sha: String?, val checkedAt: Long)

    private const val INTERVAL_MS = 6 * 3600 * 1000L

    val current: String get() = BuildConfig.VERSION_NAME

    fun cached(ctx: Context): Info? {
        val p = NotiApp.instance.store.ui
        val latest = p.getString("updLatest", "") ?: ""
        if (latest.isEmpty()) return null
        return Info(current, latest, UpdateCore.isNewer(latest, current), p.getString("updPage", "") ?: "",
            p.getString("updNotes", "") ?: "", p.getString("updApk", null), p.getLong("updSize", 0),
            p.getString("updSha", null), p.getLong("updAt", 0))
    }

    private fun get(url: String, accept: String? = null): HttpURLConnection {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 15000
        c.readTimeout = 20000
        c.instanceFollowRedirects = true
        c.setRequestProperty("User-Agent", UpdateCore.USER_AGENT)
        accept?.let { c.setRequestProperty("Accept", it) }
        return c
    }

    private fun text(url: String, accept: String? = null): String {
        val c = get(url, accept)
        try {
            if (c.responseCode != 200) throw Exception("GitHub 返回 HTTP ${c.responseCode}")
            return c.inputStream.bufferedReader().readText()
        } finally {
            c.disconnect()
        }
    }

    private fun bytes(url: String): ByteArray {
        val c = get(url)
        try {
            if (c.responseCode != 200) throw Exception("GitHub 返回 HTTP ${c.responseCode}")
            return c.inputStream.use { it.readBytes() }
        } finally {
            c.disconnect()
        }
    }

    fun check(ctx: Context, force: Boolean): Info {
        cached(ctx)?.let { if (!force && System.currentTimeMillis() - it.checkedAt < INTERVAL_MS) return it }
        val r = UpdateCore.parseRelease(text(UpdateCore.LATEST_URL, "application/vnd.github+json"))
            ?: throw Exception("最新 Release 无效（草稿或预发布）")
        val apk = r.asset(UpdateCore.androidAssetName(r.version))
        var sha: String? = null
        if (apk != null) {
            // 1.1.0 起：SHA256SUMS.txt 必须带发布者的 Ed25519 签名，验证通过才信任里面的哈希
            val sums = r.asset(UpdateCore.SUMS_ASSET)
            val sig = r.asset(UpdateCore.SUMS_SIG_ASSET)
            if (sums != null && sig != null) {
                sha = runCatching {
                    val data = bytes(sums.url)
                    if (!UpdateCore.verifySumsSignature(data, bytes(sig.url))) {
                        NotiApp.instance.store.log(false, "发布签名校验失败，忽略这个版本的安装包")
                        null
                    } else UpdateCore.parseSha256Sums(String(data, Charsets.UTF_8))[apk.name]
                }.getOrNull()
            }
        }
        val info = Info(current, r.version, UpdateCore.isNewer(r.version, current), r.page,
            UpdateCore.notesSnippet(r.body), apk?.url, apk?.size ?: 0, sha, System.currentTimeMillis())
        NotiApp.instance.store.ui.edit().putString("updLatest", info.latest).putString("updPage", info.page)
            .putString("updNotes", info.notes).putString("updApk", info.apkUrl).putLong("updSize", info.apkSize)
            .putString("updSha", info.sha).putLong("updAt", info.checkedAt).apply()
        NotiApp.instance.store.log(true, "检查更新：最新 ${info.latest}，当前 $current")
        return info
    }

    /** 下载并校验，返回已校验的 APK 文件。progress: 0..1 */
    fun download(ctx: Context, info: Info, progress: (Float) -> Unit): File {
        val url = info.apkUrl ?: throw Exception("这个版本没有安卓安装包")
        val expect = info.sha ?: throw Exception("没有通过发布签名校验的安卓安装包校验值（缺少或无效的 SHA256SUMS.txt.sig），已停止更新")
        val dir = File(ctx.cacheDir, "updates").apply { deleteRecursively(); mkdirs() }
        val f = File(dir, UpdateCore.androidAssetName(info.latest))
        val c = get(url)
        val md = MessageDigest.getInstance("SHA-256")
        try {
            if (c.responseCode != 200) throw Exception("下载失败 HTTP ${c.responseCode}")
            val total = c.contentLengthLong.takeIf { it > 0 } ?: info.apkSize
            var done = 0L
            c.inputStream.use { ins ->
                f.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = ins.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        md.update(buf, 0, n)
                        done += n
                        if (total > 0) progress((done.toFloat() / total).coerceAtMost(1f))
                    }
                }
            }
        } finally {
            c.disconnect()
        }
        val got = md.digest().joinToString("") { "%02x".format(it) }
        if (got != expect.lowercase()) {
            f.delete()
            throw Exception("安装包校验失败（SHA256 不一致），已删除")
        }
        if (!sameSigner(ctx, f)) {
            f.delete()
            throw Exception("手机上装的 NotiBridge 不是用发布签名打包的（例如从 Android Studio 直接安装的调试版），Android 不允许直接覆盖更新。请卸载后从 GitHub 安装一次新版，之后就能自动更新了")
        }
        NotiApp.instance.store.log(true, "新版本 ${info.latest} 已下载并校验")
        return f
    }

    @Suppress("DEPRECATION")
    private fun signatures(pi: PackageInfo?): Set<String> {
        if (pi == null) return emptySet()
        val sigs = if (Build.VERSION.SDK_INT >= 28) {
            pi.signingInfo?.let { if (it.hasMultipleSigners()) it.apkContentsSigners else it.signingCertificateHistory }
        } else pi.signatures
        return sigs?.map { MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).joinToString("") { b -> "%02x".format(b) } }?.toSet()
            ?: emptySet()
    }

    @Suppress("DEPRECATION")
    private fun sameSigner(ctx: Context, apk: File): Boolean {
        val flag = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val mine = signatures(ctx.packageManager.getPackageInfo(ctx.packageName, flag))
        val theirs = signatures(ctx.packageManager.getPackageArchiveInfo(apk.path, flag))
        // 部分系统读不出安装包的签名（返回空）：这时交给系统安装器判断，签名不同系统会拒绝安装
        if (theirs.isEmpty()) {
            NotiApp.instance.store.log(false, "读不出安装包的签名，交给系统安装器校验")
            return true
        }
        return mine.intersect(theirs).isNotEmpty()
    }

    fun canInstall(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 26 || ctx.packageManager.canRequestPackageInstalls()

    fun openInstallPermission(ctx: Context) {
        ctx.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /**
     * 安装下载好的 APK。优先用 PackageInstaller 会话（系统弹出确认安装界面，安装结果会回调），
     * 部分系统上 ACTION_VIEW 打开安装包没有任何反应；会话失败时再退回 ACTION_VIEW。
     */
    fun install(ctx: Context, apk: File) {
        val store = NotiApp.instance.store
        try {
            val pi = ctx.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            params.setAppPackageName(ctx.packageName)
            if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
            val id = pi.createSession(params)
            pi.openSession(id).use { s ->
                apk.inputStream().use { ins ->
                    s.openWrite("base.apk", 0, apk.length()).use { out ->
                        ins.copyTo(out)
                        s.fsync(out)
                    }
                }
                val intent = Intent(ctx, InstallResultReceiver::class.java).setAction(InstallResultReceiver.ACTION)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                s.commit(PendingIntent.getBroadcast(ctx, id, intent, flags).intentSender)
            }
            store.log(true, "已提交安装，等待确认")
        } catch (e: Exception) {
            store.log(false, "系统安装接口失败（${e.message}），改用安装包方式打开")
            installViaIntent(ctx, apk)
        }
    }

    fun installViaIntent(ctx: Context, apk: File) {
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", apk)
        ctx.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** 最近一次安装结果（失败原因），界面显示用 */
    @Volatile var lastInstallError: String = ""

    /** PackageInstaller 的安装结果：需要用户确认时打开系统确认界面；失败时记录原因。 */
    class InstallResultReceiver : BroadcastReceiver() {
        companion object { const val ACTION = "com.xsh.notibridge.INSTALL_RESULT" }

        override fun onReceive(context: Context, intent: Intent) {
            val store = NotiApp.instance.store
            when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    @Suppress("DEPRECATION")
                    val confirm = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    else intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    if (confirm != null) context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                PackageInstaller.STATUS_SUCCESS -> store.log(true, "新版本已安装")
                else -> {
                    val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "状态 $status"
                    lastInstallError = when (status) {
                        PackageInstaller.STATUS_FAILURE_ABORTED -> "已取消安装"
                        PackageInstaller.STATUS_FAILURE_CONFLICT, PackageInstaller.STATUS_FAILURE_INCOMPATIBLE ->
                            "安装失败：安装包签名与手机上的 NotiBridge 不一致，请卸载后从 GitHub 安装一次（$msg）"
                        PackageInstaller.STATUS_FAILURE_STORAGE -> "安装失败：手机存储空间不足"
                        else -> "安装失败：$msg"
                    }
                    store.log(false, lastInstallError)
                }
            }
        }
    }

    fun openPage(ctx: Context, url: String) {
        ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url.ifEmpty { UpdateCore.RELEASES_PAGE }))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
