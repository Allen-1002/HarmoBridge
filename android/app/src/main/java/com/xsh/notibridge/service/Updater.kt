package com.xsh.notibridge.service

import android.content.Context
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

    fun check(ctx: Context, force: Boolean): Info {
        cached(ctx)?.let { if (!force && System.currentTimeMillis() - it.checkedAt < INTERVAL_MS) return it }
        val r = UpdateCore.parseRelease(text(UpdateCore.LATEST_URL, "application/vnd.github+json"))
            ?: throw Exception("最新 Release 无效（草稿或预发布）")
        val apk = r.asset(UpdateCore.androidAssetName(r.version))
        var sha: String? = null
        if (apk != null) {
            r.asset(UpdateCore.SUMS_ASSET)?.let { s ->
                sha = runCatching { UpdateCore.parseSha256Sums(text(s.url))[apk.name] }.getOrNull()
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
        val expect = info.sha ?: throw Exception("SHA256SUMS.txt 里没有安卓安装包的校验值，已停止更新")
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
            throw Exception("安装包签名与当前 App 不一致，已停止更新")
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
        return theirs.isNotEmpty() && mine.intersect(theirs).isNotEmpty()
    }

    fun canInstall(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 26 || ctx.packageManager.canRequestPackageInstalls()

    fun openInstallPermission(ctx: Context) {
        ctx.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun install(ctx: Context, apk: File) {
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", apk)
        ctx.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun openPage(ctx: Context, url: String) {
        ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url.ifEmpty { UpdateCore.RELEASES_PAGE }))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
