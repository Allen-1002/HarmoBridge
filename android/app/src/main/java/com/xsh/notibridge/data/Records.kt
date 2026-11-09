package com.xsh.notibridge.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Calendar

/** 最近收到的通知（仅保存在本机，最多 200 条），首页统计和“通知”页用。 */
class Records(ctx: Context) {
    data class Record(
        val time: Long, val key: String, val pkg: String, val appName: String,
        val title: String, val text: String, val result: String,
    )

    private val file = File(ctx.filesDir, "records.json")
    private var cache: MutableList<Record>? = null
    val listeners = mutableSetOf<() -> Unit>()

    @Synchronized
    fun all(): List<Record> = load().toList()

    @Synchronized
    fun add(r: Record) {
        val l = load()
        l.add(0, r)
        while (l.size > 200) l.removeAt(l.size - 1)
        save(l)
        listeners.toList().forEach { runCatching { it() } }
    }

    @Synchronized
    fun clear() {
        cache = mutableListOf()
        file.delete()
        listeners.toList().forEach { runCatching { it() } }
    }

    fun todayCount(): Int {
        val c = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        return all().count { it.time >= c.timeInMillis }
    }

    private fun load(): MutableList<Record> {
        cache?.let { return it }
        val l = try {
            val a = JSONArray(file.readText())
            MutableList(a.length()) {
                val o = a.getJSONObject(it)
                Record(o.optLong("time"), o.optString("key"), o.optString("pkg"), o.optString("app"),
                    o.optString("title"), o.optString("text"), o.optString("result"))
            }
        } catch (e: Exception) {
            mutableListOf()
        }
        cache = l
        return l
    }

    private fun save(l: List<Record>) {
        val a = JSONArray()
        l.forEach {
            a.put(JSONObject().put("time", it.time).put("key", it.key).put("pkg", it.pkg).put("app", it.appName)
                .put("title", it.title).put("text", it.text).put("result", it.result))
        }
        runCatching {
            val tmp = File(file.path + ".tmp")
            tmp.writeText(a.toString())
            tmp.renameTo(file)
        }
    }
}
