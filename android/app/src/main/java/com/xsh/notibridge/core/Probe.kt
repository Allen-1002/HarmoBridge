package com.xsh.notibridge.core

import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

data class ProbeResult(val id: String, val name: String, val platform: String)

/**
 * 未认证的“你是谁”探测（{"t":"info"}），用于局域网发现时 TXT 记录读不到的情况。
 * 阻塞调用，请在后台线程使用。旧版 Mac 回 error，按 Mac 处理；连不上返回 null。
 */
fun probeComputer(host: String, port: Int, timeoutMs: Long = 3000): ProbeResult? {
    var result: ProbeResult? = null
    val latch = CountDownLatch(1)
    val h = if (host.contains(':')) "[$host]" else host
    val req = try {
        Request.Builder().url("ws://$h:$port").build()
    } catch (e: IllegalArgumentException) {
        return null
    }
    val ws = ComputerLink.http.newWebSocket(req, object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            webSocket.send("{\"t\":\"info\"}")
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            try {
                val o = JSONObject(text)
                when (o.optString("t")) {
                    "info" -> result = ProbeResult(o.optString("macId"), o.optString("macName"), o.optString("platform", "mac"))
                    "error" -> result = ProbeResult("", "", "mac")
                }
            } catch (e: Exception) {
                // 忽略
            }
            latch.countDown()
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = latch.countDown()
        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = latch.countDown()
    })
    latch.await(timeoutMs, TimeUnit.MILLISECONDS)
    ws.cancel()
    return result
}
