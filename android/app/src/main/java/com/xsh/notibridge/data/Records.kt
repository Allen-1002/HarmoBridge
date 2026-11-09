package com.xsh.notibridge.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Calendar

/**
 * 最近处理过的通知记录（仅保存在本机），首页统计和“通知”页用。
 * 1.1.0 起**只保存元数据**：应用名 / 包名、时间、处理结果、发往哪些电脑；不保存标题和正文。
 * 敏感内容（被敏感过滤拦下的、银行/支付类验证码）不记录。最多 200 条、256 KB，超过 7 天的自动删除；
 * 可以在设置里关闭记录或清空。
 */
class Records(ctx: Context) {
    data class Record(
        val time: Long, val key: String, val pkg: String, val appName: String, val result: String,
        val targets: String = "",
    )

    companion object {
        const val MAX_ENTRIES = 200
        const val MAX_BYTES = 256 * 1024
        const val MAX_AGE_MS = 7L * 24 * 3600 * 1000
        private const val FILE = "records_v2.json"
        /** 1.0.x 的记录文件（含通知标题和正文），升级时删除 */
        private const val LEGACY_FILE = "records.json"
    }

    private val prefs = ctx.getSharedPreferences("notibridge_records", Context.MODE_PRIVATE)
    private val file = File(ctx.filesDir, FILE)
    private var cache: MutableList<Record>? = null
    val listeners = mutableSetOf<() -> Unit>()

    init {
        val legacy = File(ctx.filesDir, LEGACY_FILE)
        if (legacy.exists()) legacy.delete()
        File(ctx.filesDir, "$LEGACY_FILE.tmp").delete()
    }

    var enabled: Boolean
        get() = prefs.getBoolean("enabled", true)
        set(v) {
            prefs.edit().putBoolean("enabled", v).apply()
            if (!v) clear() else notifyChanged()
        }

    @Synchronized
    fun all(now: Long = System.currentTimeMillis()): List<Record> = load().filter { now - it.time < MAX_AGE_MS }

    @Synchronized
    fun add(r: Record) {
        if (!enabled) return
        val l = load()
        l.add(0, r)
        trim(l, r.time)
        save(l)
        notifyChanged()
    }

    @Synchronized
    fun clear() {
        cache = mutableListOf()
        file.delete()
        notifyChanged()
    }

    fun todayCount(): Int {
        val c = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        return all().count { it.time >= c.timeInMillis }
    }

    private fun notifyChanged() = listeners.toList().forEach { runCatching { it() } }

    /** 条数、时间、字节数三重上限 */
    private fun trim(l: MutableList<Record>, now: Long) {
        l.removeAll { now - it.time >= MAX_AGE_MS }
        while (l.size > MAX_ENTRIES) l.removeAt(l.size - 1)
        while (l.isNotEmpty() && encode(l).toByteArray(Charsets.UTF_8).size > MAX_BYTES) l.removeAt(l.size - 1)
    }

    private fun encode(l: List<Record>): String {
        val a = JSONArray()
        l.forEach {
            a.put(JSONObject().put("time", it.time).put("key", it.key).put("pkg", it.pkg).put("app", it.appName)
                .put("result", it.result).put("targets", it.targets))
        }
        return a.toString()
    }

    private fun load(): MutableList<Record> {
        cache?.let { return it }
        val l = try {
            val a = JSONArray(file.readText())
            MutableList(a.length()) {
                val o = a.getJSONObject(it)
                Record(o.optLong("time"), o.optString("key"), o.optString("pkg"), o.optString("app"),
                    o.optString("result"), o.optString("targets"))
            }
        } catch (e: Exception) {
            mutableListOf()
        }
        cache = l
        return l
    }

    private fun save(l: List<Record>) {
        runCatching {
            val tmp = File(file.path + ".tmp")
            tmp.writeText(encode(l))
            tmp.renameTo(file)
        }
    }
}
