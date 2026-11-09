package com.xsh.notibridge.data

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.xsh.notibridge.core.Computer
import com.xsh.notibridge.core.SERVICE_TYPE
import com.xsh.notibridge.core.probeComputer
import java.net.Inet4Address
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

data class FoundComputer(val name: String, val host: String, val port: Int, val id: String, val platform: String) {
    /** 服务名 “NotiBridge-电脑名” → 电脑名 */
    val displayName: String get() = name.removePrefix("NotiBridge-")
    val platformLabel: String get() = if (platform == "windows") "Windows" else "Mac"
}

/**
 * 用系统 NsdManager（mDNS / DNS-SD）发现局域网里的 NotiBridge 电脑。
 * TXT 记录里有电脑 ID 和平台；读不到时用 {"t":"info"} 探测。回调都在主线程。
 */
class Discovery(private val ctx: Context) {
    private val nsd = ctx.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private var listener: NsdManager.DiscoveryListener? = null
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var onFound: ((FoundComputer) -> Unit)? = null
    private var stopRunnable: Runnable? = null

    fun start(onFound: (FoundComputer) -> Unit, onDone: () -> Unit, timeoutMs: Long = 8000) {
        stop()
        this.onFound = onFound
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                LogBuffer.add(false, "局域网发现启动失败 $errorCode")
                main.post { stop(); onDone() }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) = main.post { enqueue(info) }.let {}
            override fun onServiceLost(info: NsdServiceInfo) {}
        }
        listener = l
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Exception) {
            listener = null
            LogBuffer.add(false, "局域网发现不可用：${e.message}")
            main.post(onDone)
            return
        }
        stopRunnable = Runnable { stop(); onDone() }.also { main.postDelayed(it, timeoutMs) }
    }

    fun stop() {
        stopRunnable?.let { main.removeCallbacks(it) }
        stopRunnable = null
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        resolveQueue.clear()
        onFound = null
    }

    // 旧系统一次只能解析一个服务，排队依次解析
    private fun enqueue(info: NsdServiceInfo) {
        if (listener == null) return
        resolveQueue.addLast(info)
        next()
    }

    @Suppress("DEPRECATION")
    private fun next() {
        if (resolving || resolveQueue.isEmpty() || listener == null) return
        resolving = true
        val info = resolveQueue.removeFirst()
        try {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = main.post {
                    resolving = false
                    next()
                }.let {}

                override fun onServiceResolved(r: NsdServiceInfo) {
                    val host = hostOf(r)
                    val attrs = runCatching { r.attributes }.getOrNull() ?: emptyMap()
                    val txt = { k: String -> attrs[k]?.let { String(it, Charsets.UTF_8) } ?: "" }
                    var found = FoundComputer(r.serviceName, host ?: "", r.port, txt("id"), txt("platform"))
                    main.post {
                        resolving = false
                        next()
                    }
                    if (host == null) return
                    io.execute {
                        if (found.id.isEmpty() || found.platform.isEmpty()) {
                            probeComputer(found.host, found.port)?.let { p ->
                                found = found.copy(id = found.id.ifEmpty { p.id }, platform = found.platform.ifEmpty { p.platform })
                            }
                        }
                        main.post { onFound?.invoke(found) }
                    }
                }
            })
        } catch (e: Exception) {
            resolving = false
            next()
        }
    }

    @Suppress("DEPRECATION")
    private fun hostOf(r: NsdServiceInfo): String? {
        if (Build.VERSION.SDK_INT >= 34) {
            val addrs = r.hostAddresses
            (addrs.firstOrNull { it is Inet4Address } ?: addrs.firstOrNull())?.hostAddress?.let { return it }
        }
        return r.host?.hostAddress
    }

    companion object {
        val io = Executors.newCachedThreadPool { r -> Thread(r, "hb-io").apply { isDaemon = true } }
        private const val MIN_INTERVAL_MS = 60_000L
        private val lastRun = ConcurrentHashMap<String, Long>()

        /** 按电脑 ID 重新查找已配对电脑的新地址（设备 ID 绑定，仅限同一局域网）。 */
        fun rediscover(ctx: Context, store: AppStore, c: Computer, done: (Boolean) -> Unit) {
            val now = System.currentTimeMillis()
            val last = lastRun[c.macId]
            if (last != null && now - last < MIN_INTERVAL_MS) {
                done(false)
                return
            }
            lastRun[c.macId] = now
            Handler(Looper.getMainLooper()).post {
                val d = Discovery(ctx.applicationContext)
                var finished = false
                val finish = { v: Boolean ->
                    if (!finished) {
                        finished = true
                        d.stop()
                        done(v)
                    }
                }
                d.start({ m ->
                    val same = if (m.id.isNotEmpty()) m.id == c.macId else m.displayName == c.macName
                    if (same) {
                        if (m.host == c.host && m.port == c.port) finish(false)
                        else finish(store.updateAddress(c.macId, m.host, m.port))
                    }
                }, { finish(false) }, 6000)
            }
        }
    }
}
