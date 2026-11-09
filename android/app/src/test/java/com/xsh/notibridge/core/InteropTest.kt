package com.xsh.notibridge.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class MemoryBackend : PhoneBackend {
    override val deviceId = "android-test-device"
    override val deviceName = "Pixel 测试机"
    val computers = mutableMapOf<String, Pair<Computer, ByteArray>>()
    var settings = SyncSettings()
    val notices = mutableListOf<String>()
    override fun findComputer(macId: String) = computers[macId]?.first
    override fun keyFor(macId: String) = computers[macId]?.second
    override fun saveComputer(c: Computer, key: ByteArray) { computers[c.macId] = c to key }
    override fun forgetComputer(macId: String) { computers.remove(macId) }
    override fun addUnpairNotice(name: String) { notices.add(name) }
    override fun pairedComputers() = computers.values.map { it.first }
    override fun loadSettings() = settings.copy(blockedBundles = settings.blockedBundles.toMutableSet())
    override fun writeSettings(s: SyncSettings) { settings = s }
    override fun log(ok: Boolean, msg: String) = println("[phone] $msg")
}

/**
 * 与真实电脑端协议实现（Windows NotiBridge.Core 的 BridgeServer）互通。
 * 需要先启动测试服务器：HB_INTEROP_PORT=端口，HB_INTEROP_DIR=服务器工作目录（其中 server.log 含 PIN）。
 */
class InteropTest {
    @Test
    fun pairAuthNotifyOtpCancelSettingsUnpair() {
        val port = System.getenv("HB_INTEROP_PORT")?.toIntOrNull()
        val dir = System.getenv("HB_INTEROP_DIR")
        assumeTrue(port != null && dir != null)
        val pin = File(dir!!, "server.log").readLines().first { it.startsWith("PIN ") }.substring(4).trim()
        val be = MemoryBackend()
        val states = LinkedBlockingQueue<LinkState>()
        val acks = LinkedBlockingQueue<String>()
        var sas = ""
        var unpairedBy: Computer? = null
        val listener = object : LinkListener {
            override fun onState(state: LinkState, detail: String) { states.add(state) }
            override fun onSas(sas0: String) { sas = sas0 }
            override fun onAck(seq: Int, result: String) { acks.add(result) }
            override fun onLog(ok: Boolean, msg: String) = println("[link] $msg")
            override fun onUnpairedByComputer(c: Computer) { unpairedBy = c }
        }
        fun waitFor(s: LinkState) {
            while (true) {
                val x = states.poll(10, TimeUnit.SECONDS) ?: throw AssertionError("timeout waiting $s")
                if (x == s) return
                if (x == LinkState.ERROR) throw AssertionError("error while waiting $s")
            }
        }
        // 配对
        val pairLink = ComputerLink(be, listener)
        pairLink.startPairing("127.0.0.1", port!!, pin)
        waitFor(LinkState.AWAITING_SAS)
        assertEquals(6, sas.length)
        pairLink.confirmSas()
        waitFor(LinkState.IDLE)
        val pc = be.computers["pc-interop"]?.first
        assertEquals("InteropPC", pc?.macName)
        assertEquals("windows", pc?.platform)
        pairLink.dispose()

        // 认证 + 设置交换 + 业务消息
        be.settings = SyncSettings(updatedAt = 1000)
        val link = ComputerLink(be, listener, foreground = false, target = pc)
        link.connect()
        waitFor(LinkState.ONLINE)
        link.sendNotification(OutgoingNotification("0|com.tencent.mm|1|null|10086", "com.tencent.mm", "微信", "张三", "晚上吃什么", 1L, false))
        assertEquals("shown", acks.poll(5, TimeUnit.SECONDS))
        link.sendNotification(OutgoingNotification("0|com.tencent.mm|1|null|10086", "com.tencent.mm", "微信", "张三", "晚上吃什么", 1L, false))
        assertEquals("duplicate", acks.poll(5, TimeUnit.SECONDS))
        link.sendOtp(OtpMessage("otp1", "com.google.android.apps.messaging", "信息", "483920"))
        assertEquals("copied", acks.poll(5, TimeUnit.SECONDS))
        link.sendCancel(listOf("0|com.tencent.mm|1|null|10086"))
        assertEquals("removed", acks.poll(5, TimeUnit.SECONDS))

        // 电脑推送设置
        File(dir, "push-settings").createNewFile()
        val deadline = System.currentTimeMillis() + 5000
        while (!be.settings.paused && System.currentTimeMillis() < deadline) Thread.sleep(100)
        assertTrue(be.settings.paused)
        assertEquals(false, be.settings.copyOtp)

        // 电脑上取消配对 → 手机自动删除
        link.sendNotification(OutgoingNotification("x", "a", "a", "unpair-me", "", 1L, true))
        val deadline2 = System.currentTimeMillis() + 5000
        while (unpairedBy == null && System.currentTimeMillis() < deadline2) Thread.sleep(100)
        assertEquals("pc-interop", unpairedBy?.macId)
        assertNull(be.findComputer("pc-interop"))
        assertEquals(listOf("InteropPC"), be.notices)
        link.dispose()
    }
}
