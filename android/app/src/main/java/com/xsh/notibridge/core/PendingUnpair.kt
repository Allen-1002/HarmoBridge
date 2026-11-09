package com.xsh.notibridge.core

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

enum class UnpairOutcome { DELIVERED, NOT_PAIRED, OLD_VERSION, OFFLINE }

/**
 * 双向取消配对：手机上删除电脑时电脑可能不在线，密钥转存到待通知列表，
 * 之后打开 App、转发通知、局域网发现到这台电脑时用这把密钥认证后发 unpair（与鸿蒙 PendingUnpair.ets 一致）。
 * 只有认证后的 ack(unpaired) 才算送达；未认证的错误回复不会让手机提前丢掉密钥（最多重试 7 天）。
 */
object PendingUnpair {
    private const val MIN_INTERVAL_MS = 30_000L
    private const val ACK_WAIT_MS = 3_000L
    private const val GIVE_UP_MS = 15_000L
    /** v2：电脑回 unknown_device / auth_failed 未经认证（可能是伪造的），不立即放弃，最多重试这么久 */
    const val MAX_PENDING_MS = 7L * 24 * 3600 * 1000
    private val inflight = ConcurrentHashMap.newKeySet<String>()
    private val lastTry = ConcurrentHashMap<String, Long>()

    fun flush(
        backend: PhoneBackend, onlyMacId: String? = null, force: Boolean = false,
        onDone: ((Computer, UnpairOutcome) -> Unit)? = null,
    ) {
        val list = try {
            backend.pendingUnpairs()
        } catch (e: Exception) {
            return
        }
        val now = System.currentTimeMillis()
        for (m in list) {
            if (onlyMacId != null && m.macId != onlyMacId) continue
            if (m.macId in inflight) continue
            val last = lastTry[m.macId]
            if (!force && last != null && now - last < MIN_INTERVAL_MS) continue
            lastTry[m.macId] = now
            runOne(backend, m) { r -> onDone?.invoke(m, r) }
        }
    }

    private fun runOne(backend: PhoneBackend, mac: Computer, onDone: (UnpairOutcome) -> Unit) {
        val key = backend.pendingKey(mac.macId)
        if (key == null) {
            backend.clearPendingUnpair(mac.macId)
            return
        }
        inflight.add(mac.macId)
        val finished = AtomicBoolean(false)
        var link: ComputerLink? = null
        val finish = { r: UnpairOutcome ->
            if (finished.compareAndSet(false, true)) {
                inflight.remove(mac.macId)
                link?.dispose()
                if (r != UnpairOutcome.OFFLINE) backend.clearPendingUnpair(mac.macId)
                backend.log(true, "pending unpair ${mac.macId.take(8)}: $r")
                onDone(r)
            }
        }
        val l = ComputerLink(backend, object : LinkListener {
            override fun onState(state: LinkState, detail: String) {
                if (state == LinkState.ONLINE) {
                    link?.later(ACK_WAIT_MS) { finish(UnpairOutcome.OLD_VERSION) }
                } else if (state == LinkState.ERROR) {
                    // 电脑说不认识这台手机：可能早已删除，也可能是局域网上有人伪造回复。保留密钥继续重试，超过 7 天才放弃。
                    val denied = detail == "unknown_device" || detail == "auth_failed"
                    val since = backend.pendingSince(mac.macId)
                    val expired = since > 0 && System.currentTimeMillis() - since > MAX_PENDING_MS
                    finish(if (denied && expired) UnpairOutcome.NOT_PAIRED else UnpairOutcome.OFFLINE)
                }
            }

            override fun onAck(seq: Int, result: String) {
                if (result == "unpaired") finish(UnpairOutcome.DELIVERED)
            }
        }, foreground = false, target = mac)
        link = l
        l.later(GIVE_UP_MS) { finish(UnpairOutcome.OFFLINE) }
        l.connectForUnpair(mac, key)
    }
}
