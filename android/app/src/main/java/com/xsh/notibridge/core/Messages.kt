package com.xsh.notibridge.core

import org.json.JSONArray
import org.json.JSONObject

/** 一台已配对的电脑（Mac 或 Windows）。协议字段名沿用 macId。 */
data class Computer(
    var host: String,
    var port: Int,
    val macId: String,
    var macName: String,
    var platform: String = "mac",
) {
    val platformLabel: String get() = if (platform == "windows") "Windows" else "Mac"

    fun toJson(): JSONObject = JSONObject()
        .put("host", host).put("port", port).put("macId", macId).put("macName", macName).put("platform", platform)

    companion object {
        fun fromJson(o: JSONObject) = Computer(
            o.optString("host"), o.optInt("port", DEFAULT_PORT), o.optString("macId"),
            o.optString("macName", "电脑"), o.optString("platform", "mac"),
        )

        fun listFromJson(s: String?): MutableList<Computer> {
            if (s.isNullOrEmpty()) return mutableListOf()
            return try {
                val a = JSONArray(s)
                MutableList(a.length()) { fromJson(a.getJSONObject(it)) }
            } catch (e: Exception) {
                mutableListOf()
            }
        }

        fun listToJson(l: List<Computer>): String = JSONArray().also { a -> l.forEach { a.put(it.toJson()) } }.toString()
    }
}

const val DEFAULT_PORT = 47800
const val SERVICE_TYPE = "_notibridge._tcp"

/** 两端同步的开关（docs/protocol.md kind=settings）。blockedBundles 只在手机本地。 */
data class SyncSettings(
    var paused: Boolean = false,
    var blockSensitive: Boolean = true,
    var copyOtp: Boolean = true,
    var blockedBundles: MutableSet<String> = mutableSetOf(),
    var updatedAt: Long = 0,
)

/** 发往电脑的一条通知。 */
data class OutgoingNotification(
    val id: String,
    val bundleName: String,
    val appName: String,
    val title: String,
    val text: String,
    val time: Long,
    val test: Boolean,
)

data class OtpMessage(val id: String, val bundleName: String, val appName: String, val code: String)

/** 外层帧。null 字段不输出。 */
class Envelope(val t: String) {
    var deviceId: String? = null
    var deviceName: String? = null
    var macId: String? = null
    var macName: String? = null
    var platform: String? = null
    var pub: String? = null
    var nonce: String? = null
    var box: String? = null
    var code: String? = null

    fun json(): String {
        val o = JSONObject().put("t", t)
        deviceId?.let { o.put("deviceId", it) }
        deviceName?.let { o.put("deviceName", it) }
        macId?.let { o.put("macId", it) }
        macName?.let { o.put("macName", it) }
        platform?.let { o.put("platform", it) }
        pub?.let { o.put("pub", it) }
        nonce?.let { o.put("nonce", it) }
        box?.let { o.put("box", it) }
        code?.let { o.put("code", it) }
        return o.toString()
    }

    companion object {
        fun parse(s: String): Envelope? = try {
            val o = JSONObject(s)
            Envelope(o.getString("t")).apply {
                deviceId = o.str("deviceId")
                deviceName = o.str("deviceName")
                macId = o.str("macId")
                macName = o.str("macName")
                platform = o.str("platform")
                pub = o.str("pub")
                nonce = o.str("nonce")
                box = o.str("box")
                code = o.str("code")
            }
        } catch (e: Exception) {
            null
        }
    }
}

internal fun JSONObject.str(k: String): String? = if (has(k) && !isNull(k)) optString(k) else null
