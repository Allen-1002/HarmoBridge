package com.xsh.notibridge.core

import java.util.concurrent.ScheduledFuture

/**
 * 通知转发：每台已配对电脑一个 PeerForwarder，各自排队、各自按需连接，一台电脑离线不影响其他电脑。
 * 有消息时连接认证，发完空闲 30 秒断开，不常驻连接（省电），与鸿蒙端 ExtForwarder 一致。
 */
class Forwarder(private val backend: PhoneBackend) {
    private val peers = mutableMapOf<String, PeerForwarder>()

    @Synchronized
    private fun sync(): List<PeerForwarder> {
        val list = backend.pairedComputers()
        val ids = list.map { it.macId }.toSet()
        peers.keys.filter { it !in ids }.forEach { peers.remove(it)?.close() }
        return list.map { c -> peers.getOrPut(c.macId) { PeerForwarder(backend, c) } }
    }

    fun isPaired() = backend.pairedComputers().isNotEmpty()

    fun forward(n: OutgoingNotification) {
        sync().forEach { it.enqueue(Pending(notify = n)) }
        PendingUnpair.flush(backend)
    }

    fun forwardOtp(o: OtpMessage) = sync().forEach { it.enqueue(Pending(otp = o)) }

    fun cancel(ids: List<String>) = sync().forEach { it.enqueue(Pending(cancelIds = ids)) }

    @Synchronized
    fun close() {
        peers.values.forEach { it.close() }
        peers.clear()
    }
}

class Pending(val notify: OutgoingNotification? = null, val cancelIds: List<String>? = null, val otp: OtpMessage? = null)

private class PeerForwarder(backend: PhoneBackend, mac: Computer) : LinkListener {
    companion object {
        const val IDLE_CLOSE_MS = 30_000L
        const val MAX_PENDING = 50
        const val STALE_MS = 15_000L
    }

    private val tag = mac.macId.take(8)
    private val log: (Boolean, String) -> Unit = { ok, m -> backend.log(ok, "forwarder[$tag] $m") }
    private val link = ComputerLink(backend, this, foreground = false, target = mac)
    private val pending = ArrayDeque<Pending>()
    private var idle: ScheduledFuture<*>? = null
    private var lastActive = 0L
    private var retryCount = 0

    fun enqueue(p: Pending) = link.post {
        pending.addLast(p)
        while (pending.size > MAX_PENDING) pending.removeFirst()
        var s = link.state
        val idleFor = System.currentTimeMillis() - lastActive
        if (s != LinkState.IDLE && s != LinkState.ERROR && idleFor > STALE_MS) {
            log(false, "连接状态 $s 已 ${idleFor / 1000} 秒无活动，重新连接")
            link.stop()
            s = LinkState.IDLE
        }
        if (s == LinkState.ONLINE) {
            flush()
        } else if (s == LinkState.IDLE || s == LinkState.ERROR) {
            lastActive = System.currentTimeMillis()
            link.connect()
        }
    }

    fun close() {
        idle?.cancel(false)
        link.dispose()
    }

    override fun onState(state: LinkState, detail: String) {
        lastActive = System.currentTimeMillis()
        if (state == LinkState.ONLINE) {
            retryCount = 0
            flush()
        } else if (state == LinkState.ERROR && pending.isNotEmpty() && retryCount < 3) {
            val delay = 2000L shl retryCount
            retryCount++
            link.later(delay) {
                if (link.state == LinkState.ERROR && pending.isNotEmpty()) {
                    lastActive = System.currentTimeMillis()
                    link.connect()
                }
            }
        }
    }

    override fun onLog(ok: Boolean, msg: String) = log(ok, msg)

    override fun onAck(seq: Int, result: String) {
        lastActive = System.currentTimeMillis()
        log(true, "ack seq=$seq result=$result")
    }

    private fun flush() {
        while (pending.isNotEmpty() && link.state == LinkState.ONLINE) {
            val p = pending.removeFirst()
            when {
                p.notify != null -> link.sendNotification(p.notify)
                p.cancelIds != null -> link.sendCancel(p.cancelIds)
                p.otp != null -> link.sendOtp(p.otp)
            }
        }
        lastActive = System.currentTimeMillis()
        idle?.cancel(false)
        idle = link.later(IDLE_CLOSE_MS) {
            if (pending.isEmpty()) link.stop()
        }
    }
}
