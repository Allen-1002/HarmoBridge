package com.xsh.notibridge.core

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

enum class LinkState { IDLE, CONNECTING, PAIRING, AWAITING_SAS, AUTHENTICATING, ONLINE, ERROR }

interface LinkListener {
    fun onState(state: LinkState, detail: String) {}
    fun onLog(ok: Boolean, msg: String) {}
    fun onSas(sas: String) {}
    fun onAck(seq: Int, result: String) {}
    fun onSettingsChanged() {}
    fun onUnpairedByComputer(c: Computer) {}
    fun onPaired(c: Computer) {}
}

/** 对方是 1.0.x（协议 v1） */
const val OUTDATED_TEXT = "对方版本过旧，请把电脑和手机都更新到 1.1.0"
/** 电脑回 unknown_device：v2 起只提示，不自动删除（这个回复未经认证，局域网上任何人都能伪造） */
const val UNKNOWN_DEVICE_TEXT = "这台电脑可能已取消配对，请重新配对或手动删除"

val ERROR_TEXT = mapOf(
    "unknown_device" to UNKNOWN_DEVICE_TEXT,
    "upgrade_required" to OUTDATED_TEXT,
    "bad_point" to "配对数据无效，请重试",
    "pairing_closed" to "电脑未开启配对或配对码已过期，请在电脑上点“配对新手机”",
    "bad_pin" to "配对码错误",
    "auth_failed" to "认证失败：密钥不匹配，请重新配对",
    "replay" to "电脑拒绝了重复或乱序的消息",
    "bad_msg" to "电脑无法解密消息",
)

/**
 * 手机 → 一台电脑的局域网 WebSocket 链路，与鸿蒙端 MacLink.ets 行为一致（docs/protocol.md）。
 * 所有状态都在一个单线程调度器上处理，OkHttp 回调线程只负责投递。
 * foreground=true：界面使用，有心跳和有限次退避重连；false：转发服务里按需连接。
 */
class ComputerLink(
    private val backend: PhoneBackend,
    private val listener: LinkListener,
    private val foreground: Boolean = true,
    private var target: Computer? = null,
) {
    companion object {
        const val PHONE_PLATFORM = "android"
        val http: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
        const val CONNECT_TIMEOUT_MS = 10_000L
    }

    private val exec: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "hb-link").apply { isDaemon = true }
    }

    @Volatile
    var state: LinkState = LinkState.IDLE
        private set

    private var ws: WebSocket? = null

    // 配对临时数据
    private var pairPin = ""
    private var pairNonce: ByteArray? = null
    private var pairKeys: BridgeCrypto.PairingKeys? = null
    private var pendingMac: Computer? = null

    // 会话
    private var key: ByteArray? = null
    private var phoneNonce = ""
    private var sid = ""
    private var seq = 0
    /** 电脑发来的最后一个 cseq（防重放：必须严格递增） */
    private var lastCseq = 0
    private var ping: ScheduledFuture<*>? = null
    private var reconnect: ScheduledFuture<*>? = null
    private var retries = 0
    private var autoReconnect = false
    private var unpairOnly = false

    fun pairedComputer(): Computer? = target?.let { backend.findComputer(it.macId) }

    fun post(block: () -> Unit) {
        if (!exec.isShutdown) exec.execute { runCatching(block).onFailure { e -> listener.onLog(false, "内部错误：${e.message}") } }
    }

    fun later(ms: Long, block: () -> Unit): ScheduledFuture<*>? =
        if (exec.isShutdown) null else exec.schedule({ runCatching(block) }, ms, TimeUnit.MILLISECONDS)

    // ---------- 配对 ----------

    fun startPairing(host: String, port: Int, pin: String) = post {
        if (!Regex("^\\d{6}$").matches(pin)) {
            listener.onLog(false, "配对码应为 6 位数字")
            return@post
        }
        stopNow()
        pairPin = pin
        val nonce = BridgeCrypto.randomBytes(16)
        pairNonce = nonce
        pairKeys = null
        pendingMac = Computer(host, port, "", "", "mac")
        open(host, port, LinkState.PAIRING) {
            sendFrame(Envelope("pair_req").apply {
                v = BridgeCrypto.PROTOCOL_VERSION
                deviceId = backend.deviceId
                deviceName = backend.deviceName
                platform = PHONE_PLATFORM
                this.nonce = BridgeCrypto.b64(nonce)
            })
        }
    }

    /** 用户确认两端校验码一致后：发出确认码（电脑核对通过才保存配对） */
    fun confirmSas() = post {
        val k = pairKeys
        if (state != LinkState.AWAITING_SAS || k == null) return@post
        sendFrame(Envelope("pair_confirm").apply { confirm = BridgeCrypto.b64(k.confirmPhone) })
        setState(LinkState.PAIRING, "等待电脑确认")
    }

    // ---------- 会话 ----------

    fun connect() = post { connectNow() }

    private fun connectNow() {
        val mac = pairedComputer()
        val k = mac?.let { backend.keyFor(it.macId) }
        if (mac == null || k == null) {
            listener.onLog(false, "尚未与这台电脑配对")
            setState(LinkState.ERROR, "未配对")
            return
        }
        closeSocket()
        key = k
        autoReconnect = foreground
        phoneNonce = BridgeCrypto.b64(BridgeCrypto.randomBytes(16))
        open(mac.host, mac.port, LinkState.AUTHENTICATING) {
            sendFrame(Envelope("hello").apply { v = BridgeCrypto.PROTOCOL_VERSION; deviceId = backend.deviceId; nonce = phoneNonce })
        }
    }

    /** v1.2：手机上已删除这台电脑，用保留的密钥认证后只发 unpair。 */
    fun connectForUnpair(mac: Computer, k: ByteArray) = post {
        closeSocket()
        target = mac
        key = k
        unpairOnly = true
        autoReconnect = false
        phoneNonce = BridgeCrypto.b64(BridgeCrypto.randomBytes(16))
        open(mac.host, mac.port, LinkState.AUTHENTICATING) {
            sendFrame(Envelope("hello").apply { v = BridgeCrypto.PROTOCOL_VERSION; deviceId = backend.deviceId; nonce = phoneNonce })
        }
    }

    fun stop() = post { stopNow() }

    /** 停止并释放线程（链路不再使用时调用） */
    fun dispose() {
        post {
            stopNow()
            exec.shutdown()
        }
    }

    private fun stopNow() {
        autoReconnect = false
        clearReconnect()
        closeSocket()
        setState(LinkState.IDLE, "已断开")
    }

    fun sendNotification(n: OutgoingNotification) = post {
        if (state != LinkState.ONLINE) {
            listener.onLog(false, "未连接到电脑，消息未发送")
            return@post
        }
        sendInner(inner("notify").put("id", n.id).put("bundleName", n.bundleName).put("appName", n.appName)
            .put("title", n.title).put("text", n.text).put("time", n.time).put("test", n.test))
    }

    fun sendOtp(o: OtpMessage) = post {
        if (state != LinkState.ONLINE) return@post
        sendInner(inner("otp").put("id", o.id).put("bundleName", o.bundleName).put("appName", o.appName)
            .put("code", o.code).put("time", System.currentTimeMillis()))
    }

    fun sendCancel(ids: List<String>) = post {
        if (state != LinkState.ONLINE) return@post
        sendInner(inner("cancel").put("ids", JSONArray(ids)))
    }

    fun sendSettings() = post { sendSettingsNow() }

    // ---------- 内部 ----------

    private fun inner(kind: String): JSONObject = JSONObject().put("kind", kind).put("sid", sid).put("seq", ++seq)

    private fun open(host: String, port: Int, initial: LinkState, onOpen: () -> Unit) {
        setState(LinkState.CONNECTING, "连接 $host:$port")
        val req = try {
            Request.Builder().url("ws://${if (host.contains(':')) "[$host]" else host}:$port").build()
        } catch (e: IllegalArgumentException) {
            listener.onLog(false, "地址无效：$host")
            setState(LinkState.ERROR, "地址无效")
            return
        }
        lateinit var socket: WebSocket
        socket = http.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = post {
                if (ws !== socket) return@post
                retries = 0
                setState(initial, "已建立连接")
                onOpen()
            }

            override fun onMessage(webSocket: WebSocket, text: String) = post {
                if (ws === socket) onFrame(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = post {
                if (ws !== socket) return@post
                ws = null
                clearPing()
                if (state != LinkState.ERROR && state != LinkState.IDLE) setState(LinkState.IDLE, "连接关闭 ($code)")
                scheduleReconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = post {
                if (ws !== socket) return@post
                ws = null
                clearPing()
                val wasConnecting = state == LinkState.CONNECTING || state == LinkState.AUTHENTICATING
                listener.onLog(false, "连接失败：${t.message ?: t.javaClass.simpleName}（检查电脑地址、端口、是否同一 Wi-Fi）")
                if (state != LinkState.IDLE) setState(LinkState.ERROR, if (wasConnecting) "连接失败" else "连接中断")
                scheduleReconnect()
                if (wasConnecting) onConnectFailed()
            }
        })
        ws = socket
        // 看门狗：10 秒内没完成连接/认证就关闭报错
        later(CONNECT_TIMEOUT_MS) {
            if (ws === socket && (state == LinkState.CONNECTING || state == LinkState.AUTHENTICATING)) {
                listener.onLog(false, "连接超时（10 秒未完成连接或认证）")
                closeSocket()
                setState(LinkState.ERROR, "连接超时")
                scheduleReconnect()
                onConnectFailed()
            }
        }
    }

    /** 连不上已配对的电脑：可能换了 IP，按电脑 ID 重新查找。 */
    private fun onConnectFailed() {
        val mac = target ?: return
        if (key == null || pairNonce != null || unpairOnly) return
        backend.rediscover(mac) { moved ->
            post {
                if (moved && state == LinkState.ERROR && target?.macId == mac.macId) {
                    listener.onLog(true, "${mac.macName} 的地址已变化，正在用新地址重连")
                    retries = 0
                    connectNow()
                }
            }
        }
    }

    private fun onFrame(text: String) {
        val env = Envelope.parse(text)
        if (env == null) {
            listener.onLog(false, "收到无法解析的帧")
            return
        }
        try {
            when (env.t) {
                "pair_chal" -> onPairChallenge(env)
                "pair_ok" -> onPairOk(env)
                "challenge" -> onChallenge(env)
                "auth_ok" -> onAuthOk(env)
                "msg" -> onMsg(env)
                "error" -> onError(env.code ?: "")
                else -> listener.onLog(false, "未知帧类型 ${env.t}")
            }
        } catch (e: Exception) {
            listener.onLog(false, "处理 ${env.t} 失败：${e.message}")
            fail("协议处理失败")
        }
    }

    /** v2：收到电脑的 nonce 和 Yb，按 PIN 算 CPace 生成元、Ya 和共享点 K，发 pair_key，显示 SAS */
    private fun onPairChallenge(env: Envelope) {
        val nonce = pairNonce
        if (nonce == null || state != LinkState.PAIRING || pairKeys != null) {
            fail("配对数据缺失")
            return
        }
        if (env.v != BridgeCrypto.PROTOCOL_VERSION) {
            outdated()
            return
        }
        val macNonce = env.nonce?.let { runCatching { BridgeCrypto.fromB64(it) }.getOrNull() }
        val yb = env.pub?.let { runCatching { BridgeCrypto.fromB64(it) }.getOrNull() }
        if (macNonce?.size != 16 || yb?.size != 32) {
            fail("电脑的配对数据不完整")
            return
        }
        val ctx = BridgeCrypto.PairingContext(
            backend.deviceId, backend.deviceName, PHONE_PLATFORM,
            env.macId ?: "", env.macName ?: "", env.platform ?: "", nonce, macNonce,
        )
        val ya = BridgeCrypto.randomBytes(32)
        val keys = try {
            val yaPub = Cpace.scalarMultVfy(ya, ctx.generator(pairPin))
            val k = Cpace.scalarMultVfy(ya, yb)
            sendFrame(Envelope("pair_key").apply { pub = BridgeCrypto.b64(yaPub) })
            BridgeCrypto.pairingKeys(k, ctx, yaPub, yb)
        } catch (e: Cpace.LowOrderPoint) {
            fail("电脑发来的配对公钥无效")
            return
        }
        pairKeys = keys
        pendingMac = pendingMac?.copy(macId = env.macId ?: "", macName = env.macName ?: "电脑", platform = env.platform ?: "mac")
        listener.onSas(keys.sas)
        setState(LinkState.AWAITING_SAS, "请核对校验码 ${keys.sas}")
    }

    /** 核对电脑的确认码：通过才保存配对密钥（冒充电脑、不知道 PIN 的一方算不出来） */
    private fun onPairOk(env: Envelope) {
        val keys = pairKeys
        val c = env.confirm?.let { runCatching { BridgeCrypto.fromB64(it) }.getOrNull() }
        if (keys == null || c == null || !BridgeCrypto.constantTimeEqual(c, keys.confirmComputer)) {
            fail("电脑的配对确认无效")
            return
        }
        val k = keys.pairKey
        var mac = pendingMac
        if (mac != null) {
            if (mac.macId.isEmpty()) mac = mac.copy(macId = "host-${mac.host}")
            backend.saveComputer(mac, k)
            target = mac
        }
        listener.onLog(true, "与 ${mac?.macName} 配对成功")
        clearPairing()
        closeSocket()
        setState(LinkState.IDLE, "配对成功，可以连接")
        mac?.let { listener.onPaired(it) }
    }

    private fun onChallenge(env: Envelope) {
        val k = key
        val n = env.nonce
        if (k == null || n == null) {
            fail("认证数据缺失")
            return
        }
        if (env.v != BridgeCrypto.PROTOCOL_VERSION) {
            outdated()
            return
        }
        sid = n
        sendFrame(Envelope("auth").apply { box = BridgeCrypto.seal(k, "auth|$phoneNonce|$sid", BridgeCrypto.Direction.TO_COMPUTER) })
    }

    private fun onAuthOk(env: Envelope) {
        val k = key
        val b = env.box
        if (k == null || b == null || BridgeCrypto.open(k, b, BridgeCrypto.Direction.TO_PHONE) != "ok|$sid|$phoneNonce") {
            fail("电脑身份校验失败")
            return
        }
        seq = 0
        lastCseq = 0
        if (unpairOnly) {
            setState(LinkState.ONLINE, "已认证，正在通知电脑取消配对")
            sendInner(inner("unpair"))
            return
        }
        setState(LinkState.ONLINE, "已认证，在线")
        sendSettingsNow()
        if (foreground) startPing()
    }

    private fun sendSettingsNow() {
        if (state != LinkState.ONLINE) return
        val st = backend.loadSettings()
        sendInner(inner("settings").put("paused", st.paused).put("blockSensitive", st.blockSensitive)
            .put("copyOtp", st.copyOtp).put("updatedAt", st.updatedAt))
    }

    private fun applyRemoteSettings(o: JSONObject) {
        if (!o.has("updatedAt")) return
        val at = o.optLong("updatedAt")
        val st = backend.loadSettings()
        if (at <= st.updatedAt) return
        if (o.has("paused")) st.paused = o.optBoolean("paused")
        if (o.has("blockSensitive")) st.blockSensitive = o.optBoolean("blockSensitive")
        if (o.has("copyOtp")) st.copyOtp = o.optBoolean("copyOtp")
        st.updatedAt = at
        backend.writeSettings(st)
        listener.onSettingsChanged()
    }

    private fun onMsg(env: Envelope) {
        val k = key ?: return
        val b = env.box ?: return
        val o = JSONObject(BridgeCrypto.open(k, b, BridgeCrypto.Direction.TO_PHONE))
        if (o.optString("sid") != sid) {
            listener.onLog(false, "忽略会话不匹配的消息")
            return
        }
        // v2 防重放：电脑发来的每条消息 cseq 必须严格递增，重复或乱序的（尤其 unpair、settings）一律丢弃
        val cseq = if (o.has("cseq")) o.optInt("cseq", 0) else 0
        if (cseq <= lastCseq) {
            listener.onLog(false, "忽略重放或乱序的电脑消息 cseq=$cseq")
            return
        }
        lastCseq = cseq
        when (o.optString("kind")) {
            "ack" -> listener.onAck(o.optInt("seq"), o.optString("result"))
            "settings" -> applyRemoteSettings(o)
            "unpair" -> if (!unpairOnly) onUnpairedByComputer()
        }
    }

    private fun onUnpairedByComputer() {
        val mac = target ?: return
        autoReconnect = false
        clearReconnect()
        backend.forgetComputer(mac.macId)
        backend.addUnpairNotice(mac.macName)
        closeSocket()
        setState(LinkState.IDLE, "已在电脑上取消配对")
        listener.onUnpairedByComputer(mac)
    }

    private fun onError(code: String) {
        // v2：unknown_device 未经认证，只提示，不自动删除这台电脑（见 docs/protocol.md “取消配对”）
        if (code == "upgrade_required" || (code == "bad_pair_req" && pairNonce != null && pairKeys == null)) {
            // 旧版电脑不认识 v2 的 pair_req（缺 pub）会回 bad_pair_req
            outdated()
            return
        }
        listener.onLog(false, "电脑返回错误 $code：${ERROR_TEXT[code] ?: "未知错误"}")
        if (code in setOf("unknown_device", "auth_failed", "bad_pin", "pairing_closed")) autoReconnect = false
        fail(code)
    }

    /** 对方是 1.0.x（协议 v1）：停止重连并提示双方都更新 */
    private fun outdated() {
        autoReconnect = false
        listener.onLog(false, OUTDATED_TEXT)
        fail("outdated")
    }

    private fun sendInner(o: JSONObject) {
        val k = key ?: return
        sendFrame(Envelope("msg").apply { box = BridgeCrypto.seal(k, o.toString(), BridgeCrypto.Direction.TO_COMPUTER) })
    }

    private fun sendFrame(env: Envelope) {
        val w = ws ?: return
        if (!w.send(env.json())) listener.onLog(false, "发送失败（连接已关闭）")
    }

    private fun startPing() {
        clearPing()
        ping = if (exec.isShutdown) null else exec.scheduleWithFixedDelay({
            runCatching { if (state == LinkState.ONLINE) sendInner(inner("ping")) }
        }, 25, 25, TimeUnit.SECONDS)
    }

    private fun clearPing() {
        ping?.cancel(false)
        ping = null
    }

    private fun scheduleReconnect() {
        if (!autoReconnect || reconnect != null || retries >= 5) {
            if (autoReconnect && retries >= 5) {
                listener.onLog(false, "多次重连失败，已停止自动重连")
                autoReconnect = false
            }
            return
        }
        val delay = minOf(30_000L, 2000L shl retries)
        retries++
        listener.onLog(false, "${delay / 1000} 秒后第 $retries 次重连")
        reconnect = later(delay) {
            reconnect = null
            if (autoReconnect) connectNow()
        }
    }

    private fun clearReconnect() {
        reconnect?.cancel(false)
        reconnect = null
        retries = 0
    }

    private fun fail(detail: String) {
        clearPairing()
        setState(LinkState.ERROR, detail)
        closeSocket()
    }

    private fun clearPairing() {
        pairPin = ""
        pairNonce = null
        pairKeys = null
    }

    private fun closeSocket() {
        clearPing()
        val w = ws
        ws = null
        w?.close(1000, null)
    }

    private fun setState(s: LinkState, detail: String) {
        state = s
        listener.onState(s, detail)
        backend.log(s != LinkState.ERROR, "link[${target?.macId?.take(8) ?: "new"}] $s $detail")
    }
}
