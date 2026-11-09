package com.xsh.notibridge.core

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 与 docs/protocol.md “密码学约定”（协议 v2）逐项一致（Mac BridgeCrypto.swift、Windows BridgeCrypto.cs、鸿蒙 Crypto.ets）。
 * SHA-256 / HMAC / AES-GCM 用 JDK；X25519 用 BouncyCastle（见 Cpace.kt）。
 */
object BridgeCrypto {
    const val PROTOCOL_VERSION = 2
    private val rng = SecureRandom()

    /** 消息方向：AAD 不同，把一方的消息反射回去也解不开。 */
    enum class Direction(val aad: String) { TO_COMPUTER("NB2|p2c"), TO_PHONE("NB2|c2p") }

    private val TRANSCRIPT_LABEL = u("NotiBridge-pair-v2")
    private val INFO_PAIR_KEY = u("NotiBridge-v2 pair key")
    private val INFO_CONFIRM_PHONE = u("NotiBridge-v2 confirm phone")
    private val INFO_CONFIRM_COMPUTER = u("NotiBridge-v2 confirm computer")

    fun u(s: String): ByteArray = s.toByteArray(Charsets.UTF_8)

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { rng.nextBytes(it) }

    fun b64(b: ByteArray): String = Base64.getEncoder().encodeToString(b)
    fun fromB64(s: String): ByteArray = Base64.getDecoder().decode(s)

    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    fun fromHex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it.toInt() and 0xff) }

    fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(data)

    /** HKDF-SHA256（RFC 5869） */
    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, len: Int): ByteArray {
        val prk = hmacSha256(if (salt.isEmpty()) ByteArray(32) else salt, ikm)
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(prk, "HmacSHA256")) }
        val out = java.io.ByteArrayOutputStream()
        var t = ByteArray(0)
        var i = 1
        while (out.size() < len) {
            mac.update(t)
            mac.update(info)
            mac.update(i.toByte())
            t = mac.doFinal()
            out.write(t)
            i++
        }
        return out.toByteArray().copyOf(len)
    }

    /** 配对双方都知道的公开信息（字符串按线路上的原样）。 */
    data class PairingContext(
        val deviceId: String, val deviceName: String, val phonePlatform: String,
        val macId: String, val macName: String, val macPlatform: String,
        val phoneNonce: ByteArray, val macNonce: ByteArray,
    ) {
        val sid: ByteArray get() = phoneNonce + macNonce
        val ci: ByteArray get() = Cpace.lvCat(u(deviceId), u(macId))
        fun generator(pin: String): ByteArray = Cpace.generator(u(pin), ci, sid)
        fun transcript(ya: ByteArray, yb: ByteArray): ByteArray = Cpace.lvCat(
            TRANSCRIPT_LABEL, sid, u(deviceId), u(deviceName), u(phonePlatform), u(macId), u(macName), u(macPlatform), ya, yb,
        )
    }

    class PairingKeys(
        val pairKey: ByteArray, val transcriptHash: ByteArray,
        val confirmPhone: ByteArray, val confirmComputer: ByteArray, val sas: String,
    )

    fun pairingKeys(k: ByteArray, ctx: PairingContext, ya: ByteArray, yb: ByteArray): PairingKeys {
        val th = sha256(ctx.transcript(ya, yb))
        val kcP = hkdfSha256(k, th, INFO_CONFIRM_PHONE, 32)
        val kcC = hkdfSha256(k, th, INFO_CONFIRM_COMPUTER, 32)
        return PairingKeys(
            hkdfSha256(k, th, INFO_PAIR_KEY, 32), th,
            hmacSha256(kcP, th + u("phone")), hmacSha256(kcC, th + u("computer")), sas(th),
        )
    }

    /** 8 位数字校验码：th 前 5 字节大端整数 mod 10^8，显示为 "1234 5678"。 */
    fun sas(th: ByteArray): String {
        var n = 0L
        for (i in 0 until 5) n = (n shl 8) or (th[i].toLong() and 0xff)
        val s = "%08d".format(n % 100_000_000L)
        return s.substring(0, 4) + " " + s.substring(4)
    }

    fun constantTimeEqual(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    // ---------- AES-256-GCM ----------

    fun seal(key: ByteArray, plaintext: String, dir: Direction): String {
        val iv = randomBytes(12)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        c.updateAAD(u(dir.aad))
        return b64(iv + c.doFinal(u(plaintext)))
    }

    fun open(key: ByteArray, box: String, dir: Direction): String {
        val all = fromB64(box)
        require(all.size > 28) { "box too short" }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, all, 0, 12))
        c.updateAAD(u(dir.aad))
        return String(c.doFinal(all, 12, all.size - 12), Charsets.UTF_8)
    }
}
