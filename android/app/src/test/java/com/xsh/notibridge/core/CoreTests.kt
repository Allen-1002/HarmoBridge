package com.xsh.notibridge.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 与 mac/Tests/CryptoVectorTests.swift、windows CryptoTests.cs 使用同一组测试向量。 */
class CryptoVectorTests {
    private fun range(start: Int) = ByteArray(32) { (start + it).toByte() }
    private val phonePub = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw="
    private val macPub = "VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY="
    private val keyHex = "ae8bedba0583b7bbfa2b0807fd2ddd6b020d39c7fdc62562abb1a936d755dbbd"

    @Test
    fun rfc7748Vector() {
        // RFC 7748 6.1
        val a = BridgeCrypto.fromHex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        assertEquals("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", BridgeCrypto.hex(BridgeCrypto.publicFromPrivate(a)))
        val bPub = BridgeCrypto.fromHex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        assertEquals("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", BridgeCrypto.hex(BridgeCrypto.x25519(a, bPub)))
    }

    @Test
    fun sharedVector() {
        assertEquals(phonePub, BridgeCrypto.b64(BridgeCrypto.publicFromPrivate(range(1))))
        assertEquals(macPub, BridgeCrypto.b64(BridgeCrypto.publicFromPrivate(range(101))))
        val pp = BridgeCrypto.fromB64(phonePub)
        val mp = BridgeCrypto.fromB64(macPub)
        assertEquals("491302", BridgeCrypto.sas(pp, mp))
        val key = BridgeCrypto.derivePairKey(range(1), pp, mp, "123456")
        assertEquals(keyHex, BridgeCrypto.hex(key))
        assertEquals("通知 hello", BridgeCrypto.open(key, "AAAAAAAAAAAAAAAAq0Nf5FBV6VP0KkCm9JQvDAeOprNkTWShWA8qKg=="))
        assertEquals("往返", BridgeCrypto.open(key, BridgeCrypto.seal(key, "往返")))
    }

    @Test
    fun randomKeysAgree() {
        val a = BridgeCrypto.generateX25519()
        val b = BridgeCrypto.generateX25519()
        assertEquals(BridgeCrypto.hex(BridgeCrypto.x25519(a.priv, b.pub)), BridgeCrypto.hex(BridgeCrypto.x25519(b.priv, a.pub)))
    }
}

class FilterTests {
    @Test
    fun otp() {
        assertEquals("483920", Filter.extractOtp("短信", "【某银行】您的验证码是 483920，5 分钟内有效。"))
        assertEquals("", Filter.extractOtp("会议", "今天 1530 开会"))
        assertEquals("7788", Filter.extractOtp("", "Your code: 7788"))
    }

    @Test
    fun block() {
        val s = SyncSettings()
        assertEquals("疑似敏感内容", Filter.blockReason(s, "a", "余额变动", ""))
        assertEquals("", Filter.blockReason(s, "a", "你好", "在吗"))
        s.blockedBundles.add("a")
        assertEquals("应用已屏蔽", Filter.blockReason(s, "a", "你好", ""))
        s.paused = true
        assertEquals("同步已暂停", Filter.blockReason(s, "b", "你好", ""))
    }
}

class UpdateCoreTests {
    @Test
    fun versions() {
        assertTrue(UpdateCore.isNewer("v1.4.0", "1.3.0"))
        assertFalse(UpdateCore.isNewer("1.3", "1.3.0"))
        assertFalse(UpdateCore.isNewer("garbage", "1.0"))
        assertTrue(UpdateCore.isNewer("1.10.0", "1.9.9"))
    }

    @Test
    fun sums() {
        val h = "a".repeat(64)
        val m = UpdateCore.parseSha256Sums("$h  NotiBridge-1.4.0-Android.apk\n# x\n$h *./dist/b.zip\nbad line")
        assertEquals(h, m["NotiBridge-1.4.0-Android.apk"])
        assertEquals(h, m["b.zip"])
        assertEquals(2, m.size)
    }

    @Test
    fun release() {
        val r = UpdateCore.parseRelease("""{"tag_name":"v1.4.0","html_url":"https://x","draft":false,"prerelease":false,
            "body":"## 更新内容\n- **安卓**端\n## 已知","assets":[{"name":"NotiBridge-1.4.0-Android.apk","browser_download_url":"https://d","size":5}]}""")!!
        assertEquals("1.4.0", r.version)
        assertEquals(5L, r.asset(UpdateCore.androidAssetName("1.4.0"))!!.size)
        assertEquals("• 安卓端", UpdateCore.notesSnippet(r.body))
    }
}
