package com.xsh.notibridge.core

import org.bouncycastle.math.ec.rfc8032.Ed25519
import org.json.JSONObject

/** 自动更新的纯逻辑，与 Mac UpdateCore.swift / Windows UpdateCore.cs 一致。 */
object UpdateCore {
    const val LATEST_URL = "https://api.github.com/repos/Allen-1002/NotiBridge/releases/latest"
    const val RELEASES_PAGE = "https://github.com/Allen-1002/NotiBridge/releases/latest"
    const val USER_AGENT = "NotiBridge-Updater"
    const val SUMS_ASSET = "SHA256SUMS.txt"
    const val SUMS_SIG_ASSET = "SHA256SUMS.txt.sig"

    /**
     * 发布签名公钥（Ed25519，32 字节原始格式，Base64）。私钥只在发布者电脑上
     * （~/.config/notibridge/release-signing-ed25519.pem，scripts/sign_release.sh 使用）。
     * 与 Mac UpdateCore.swift、Windows UpdateCore.cs 中的值必须相同。
     */
    const val RELEASE_PUBLIC_KEY_B64 = "+wkZaT1HzXMHhcMF6xz67byo2x0iNeXMoL4PSO1ApQo="

    /** 校验 SHA256SUMS.txt 的 Ed25519 签名（.sig 内容为 Base64 的 64 字节签名，允许末尾换行） */
    fun verifySumsSignature(sums: ByteArray, signatureFile: ByteArray, publicKeyB64: String = RELEASE_PUBLIC_KEY_B64): Boolean =
        try {
            val sig = BridgeCrypto.fromB64(String(signatureFile, Charsets.UTF_8).trim())
            val pk = BridgeCrypto.fromB64(publicKeyB64)
            sig.size == 64 && pk.size == 32 && Ed25519.verify(sig, 0, pk, 0, sums, 0, sums.size)
        } catch (e: IllegalArgumentException) {
            false
        }

    fun androidAssetName(version: String) = "NotiBridge-$version-Android.apk"

    fun parseVersion(s: String): List<Int>? {
        var t = s.trim().removePrefix("v").removePrefix("V")
        val cut = t.indexOfFirst { it == '-' || it == '+' }
        if (cut >= 0) t = t.substring(0, cut)
        val parts = t.split('.')
        if (parts.isEmpty() || parts.size > 4) return null
        return parts.map { p -> if (p.isNotEmpty() && p.all { it in '0'..'9' }) p.toIntOrNull() ?: return null else return null }
    }

    fun compare(a: String, b: String): Int? {
        val x = parseVersion(a) ?: return null
        val y = parseVersion(b) ?: return null
        for (i in 0 until maxOf(x.size, y.size)) {
            val l = x.getOrElse(i) { 0 }
            val r = y.getOrElse(i) { 0 }
            if (l != r) return if (l < r) -1 else 1
        }
        return 0
    }

    fun isNewer(latest: String, current: String) = compare(latest, current) == 1

    fun parseSha256Sums(text: String): Map<String, String> {
        val out = mutableMapOf<String, String>()
        for (raw in text.lines()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            val sp = line.indexOfFirst { it == ' ' || it == '\t' }
            if (sp < 0) continue
            val hash = line.substring(0, sp).lowercase()
            if (hash.length != 64 || !hash.all { it in '0'..'9' || it in 'a'..'f' }) continue
            var name = line.substring(sp).trim().removePrefix("*")
            name = name.substringAfterLast('/')
            if (name.isNotEmpty()) out[name] = hash
        }
        return out
    }

    data class Asset(val name: String, val url: String, val size: Long)
    data class Release(val version: String, val page: String, val body: String, val assets: List<Asset>) {
        fun asset(n: String) = assets.firstOrNull { it.name == n }
    }

    /** 解析 GitHub Release JSON；草稿、预发布或无 tag 返回 null。 */
    fun parseRelease(json: String): Release? {
        val o = JSONObject(json)
        if (o.optBoolean("draft") || o.optBoolean("prerelease")) return null
        val tag = o.str("tag_name") ?: return null
        val arr = o.optJSONArray("assets")
        val assets = (0 until (arr?.length() ?: 0)).map {
            val a = arr!!.getJSONObject(it)
            Asset(a.optString("name"), a.optString("browser_download_url"), a.optLong("size"))
        }
        return Release(tag.trim().removePrefix("v").removePrefix("V"), o.str("html_url") ?: RELEASES_PAGE, o.optString("body"), assets)
    }

    /** 更新说明摘要：正文第一行的重点提示（例如“安全更新，必须重新配对”）+“更新内容”一节，去掉表格和 Markdown 符号。 */
    fun notesSnippet(body: String, maxChars: Int = 400): String {
        val all = body.lines()
        var lines = all
        val headline = all.map { it.trim() }.firstOrNull { it.isNotEmpty() && !it.startsWith("#") && !it.startsWith("|") && !it.startsWith("---") }
        val start = all.indexOfFirst { it.startsWith("#") && it.contains("更新内容") }
        if (start >= 0) {
            val rest = all.drop(start + 1)
            val end = rest.indexOfFirst { it.startsWith("## ") }.let { if (it < 0) rest.size else it }
            lines = rest.take(end)
            if (headline != null && lines.none { it.trim() == headline }) lines = listOf(headline) + lines
        }
        val cleaned = lines.map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("|") }.joinToString("\n") { l ->
            var s = l.trimStart('#', '>').trim()
            if (s.startsWith("- ") || s.startsWith("* ")) s = "• " + s.substring(2)
            s.replace("**", "").replace("`", "").trim()
        }
        return if (cleaned.length <= maxChars) cleaned else cleaned.take(maxChars) + "…"
    }
}
