package com.xsh.notibridge.core

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/** docs/test-vectors/pairing-v2.json（四端共用）：CPace 草案官方向量 + NotiBridge v2 派生向量。 */
object Vectors {
    val root: JSONObject by lazy {
        var dir: File? = File(".").absoluteFile
        while (dir != null && !File(dir, "docs/test-vectors/pairing-v2.json").exists()) dir = dir.parentFile
        JSONObject(File(dir ?: error("找不到 docs/test-vectors/pairing-v2.json"), "docs/test-vectors/pairing-v2.json").readText())
    }
}

private fun JSONObject.hex(k: String) = BridgeCrypto.fromHex(getString(k))

class CryptoVectorTests {
    @Test
    fun officialCpaceVectors() {
        val o = Vectors.root.getJSONObject("cpaceOfficial")
        assertEquals("043132333401350003363738",
            BridgeCrypto.hex(Cpace.lvCat("1234".toByteArray(), "5".toByteArray(), ByteArray(0), "678".toByteArray())))
        assertArrayEquals(o.hex("generatorString"), Cpace.generatorString(o.hex("prs"), o.hex("ci"), o.hex("sid")))
        val g = Cpace.generator(o.hex("prs"), o.hex("ci"), o.hex("sid"))
        assertEquals(o.getString("g"), BridgeCrypto.hex(g))
        assertArrayEquals(o.hex("Ya"), Cpace.scalarMultVfy(o.hex("ya"), g))
        assertArrayEquals(o.hex("Yb"), Cpace.scalarMultVfy(o.hex("yb"), g))
        assertArrayEquals(o.hex("K"), Cpace.scalarMultVfy(o.hex("ya"), o.hex("Yb")))
        assertArrayEquals(o.hex("K"), Cpace.scalarMultVfy(o.hex("yb"), o.hex("Ya")))
    }

    @Test
    fun lowOrderPointsAbort() {
        val o = Vectors.root.getJSONObject("cpaceOfficial")
        val s = o.hex("lowOrderScalar")
        val arr = o.getJSONArray("lowOrder")
        for (i in 0 until arr.length()) {
            val item = arr.getJSONObject(i)
            if (item.getBoolean("mustAbort")) {
                try {
                    Cpace.scalarMultVfy(s, item.hex("u"))
                    fail("低阶点必须中止：${item.getString("u")}")
                } catch (e: Cpace.LowOrderPoint) {
                }
            } else {
                assertEquals(item.getString("q"), BridgeCrypto.hex(Cpace.scalarMultVfy(s, item.hex("u"))))
            }
        }
    }

    @Test
    fun pairingVector() {
        val p = Vectors.root.getJSONObject("pairing")
        val i = p.getJSONObject("inputs")
        val o = p.getJSONObject("outputs")
        val ctx = BridgeCrypto.PairingContext(i.getString("deviceId"), i.getString("deviceName"), i.getString("phonePlatform"),
            i.getString("macId"), i.getString("macName"), i.getString("macPlatform"), i.hex("phoneNonce"), i.hex("macNonce"))
        assertEquals(o.getString("ci"), BridgeCrypto.hex(ctx.ci))
        assertEquals(o.getString("sid"), BridgeCrypto.hex(ctx.sid))
        val g = ctx.generator(i.getString("pin"))
        assertEquals(o.getString("g"), BridgeCrypto.hex(g))
        val ya = Cpace.scalarMultVfy(i.hex("ya"), g)
        val yb = Cpace.scalarMultVfy(i.hex("yb"), g)
        assertEquals(o.getString("Ya"), BridgeCrypto.hex(ya))
        assertEquals(o.getString("Yb"), BridgeCrypto.hex(yb))
        val k = Cpace.scalarMultVfy(i.hex("ya"), yb)
        assertEquals(o.getString("K"), BridgeCrypto.hex(k))
        assertEquals(o.getString("transcript"), BridgeCrypto.hex(ctx.transcript(ya, yb)))
        val keys = BridgeCrypto.pairingKeys(k, ctx, ya, yb)
        assertEquals(o.getString("transcriptHash"), BridgeCrypto.hex(keys.transcriptHash))
        assertEquals(o.getString("pairKey"), BridgeCrypto.hex(keys.pairKey))
        assertEquals(o.getString("confirmPhone"), BridgeCrypto.hex(keys.confirmPhone))
        assertEquals(o.getString("confirmComputer"), BridgeCrypto.hex(keys.confirmComputer))
        assertEquals(o.getString("sas"), keys.sas)

        val w = p.getJSONObject("wrongPin")
        assertEquals(w.getString("Ya"), BridgeCrypto.hex(Cpace.scalarMultVfy(i.hex("ya"), ctx.generator(w.getString("pin")))))

        val boxes = p.getJSONObject("boxes")
        val plain = boxes.getString("plaintext")
        assertEquals(plain, BridgeCrypto.open(keys.pairKey, boxes.getString("toComputer"), BridgeCrypto.Direction.TO_COMPUTER))
        assertEquals(plain, BridgeCrypto.open(keys.pairKey, boxes.getString("toPhone"), BridgeCrypto.Direction.TO_PHONE))
        assertTrue(runCatching { BridgeCrypto.open(keys.pairKey, boxes.getString("toComputer"), BridgeCrypto.Direction.TO_PHONE) }.isFailure)
        assertEquals("往返", BridgeCrypto.open(keys.pairKey, BridgeCrypto.seal(keys.pairKey, "往返", BridgeCrypto.Direction.TO_PHONE), BridgeCrypto.Direction.TO_PHONE))
    }

    @Test
    fun sasFormat() {
        assertEquals("0000 0000", BridgeCrypto.sas(ByteArray(32)))
        assertEquals("1162 7775", BridgeCrypto.sas(ByteArray(32) { 0xff.toByte() }))
    }

    @Test
    fun rfc7748Vector() {
        // RFC 7748 6.1：BouncyCastle X25519 与基点 9
        val a = BridgeCrypto.fromHex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        val base = ByteArray(32).also { it[0] = 9 }
        assertEquals("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", BridgeCrypto.hex(Cpace.scalarMultVfy(a, base)))
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

    /** v1.1.0：验证码在按应用屏蔽和敏感过滤之后才提取 */
    @Test
    fun otpRunsAfterBlacklistAndSensitiveFilter() {
        val s = SyncSettings()
        // 普通短信验证码：发验证码，不发全文
        val sms = Filter.decide(s, "com.android.mms", "短信", "您的验证码是 483920")
        assertEquals(Filter.Action.OTP, sms.action)
        assertEquals("483920", sms.otp)
        // 屏蔽的应用：通知和验证码都不发
        s.blockedBundles.add("com.android.mms")
        assertEquals(Filter.Action.DROP, Filter.decide(s, "com.android.mms", "短信", "您的验证码是 483920").action)
        s.blockedBundles.clear()
        // 银行类验证码：默认不发，也不记录
        val bank = Filter.decide(s, "com.android.mms", "短信", "【某银行】您正在转账，验证码 556677")
        assertEquals(Filter.Action.DROP, bank.action)
        assertFalse(bank.record)
        assertEquals(Filter.Action.DROP, Filter.decide(s, "com.icbc.mobile", "工行", "动态码 1234").action)
        // 用户明确允许后才发
        s.allowSensitiveOtp = true
        assertEquals(Filter.Action.OTP, Filter.decide(s, "com.android.mms", "短信", "【某银行】您正在转账，验证码 556677").action)
        // 关闭验证码同步：验证码短信按普通敏感内容拦截，不记录
        s.copyOtp = false
        val off = Filter.decide(s, "com.android.mms", "短信", "您的验证码是 483920")
        assertEquals(Filter.Action.DROP, off.action)
        assertFalse(off.record)
        // 暂停时什么都不发
        s.copyOtp = true
        s.paused = true
        assertEquals(Filter.Action.DROP, Filter.decide(s, "com.android.mms", "短信", "您的验证码是 483920").action)
        // 普通通知照常转发
        s.paused = false
        assertEquals(Filter.Action.FORWARD, Filter.decide(s, "com.tencent.mm", "张三", "晚上吃饭").action)
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
        val security = "**安全更新：所有手机都必须重新配对，电脑和手机都要更新到 1.1.0。**\n\n## 更新内容\n- CPace\n## 已知"
        assertTrue(UpdateCore.notesSnippet(security).startsWith("安全更新：所有手机都必须重新配对"))
    }

    @Test
    fun releaseSignature() {
        val r = Vectors.root.getJSONObject("releaseSignature")
        val pk = BridgeCrypto.b64(BridgeCrypto.fromHex(r.getString("publicKey")))
        val msg = r.getString("message").toByteArray()
        val sig = (r.getString("signature") + "\n").toByteArray()
        assertTrue(UpdateCore.verifySumsSignature(msg, sig, pk))
        val tampered = msg.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertFalse(UpdateCore.verifySumsSignature(tampered, sig, pk))
        assertFalse("内置发布公钥不能验证测试签名", UpdateCore.verifySumsSignature(msg, sig))
        assertFalse(UpdateCore.verifySumsSignature(msg, "garbage".toByteArray(), pk))
        assertEquals(32, BridgeCrypto.fromB64(UpdateCore.RELEASE_PUBLIC_KEY_B64).size)
    }
}
